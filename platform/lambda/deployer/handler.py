"""
T-POT Booking Platform - Deployer Lambda Handler (Two-Phase Async).

Phase 1 (deploy): Invoked by the capacity poller after a spot instance is launched.
  1. Waits for instance to be reachable via SSM
  2. Sends a long-running SSM command (timeout 3600s) that performs:
     NVMe RAID setup, model download, docker compose pull + up
  3. Stores the SSM command_id in the booking record
  4. Updates booking status to 'deploying'
  5. Returns immediately (does NOT wait for command completion)

Phase 2 (check_progress): Invoked every 2 minutes by EventBridge schedule.
  - Scans all bookings with status=deploying
  - For each, checks SSM command status via get_command_invocation
  - If command succeeded: checks health endpoint, updates to ready + notifies
  - If command failed: updates to failed + notifies
  - If command still in progress: skips, waits for next invocation
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configuration ──────────────────────────────────────────────────────────

BOOKING_TABLE = os.environ.get("BOOKING_TABLE", "TpotBookingTable")
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")
PROJECT_TAG = "tpot-benchmark"
SGLANG_PORT = 30080

# Timeouts
SSM_WAIT_TIMEOUT = 120  # seconds to wait for SSM readiness
SSM_COMMAND_TIMEOUT = 3600  # seconds for the long-running deploy command (1 hour)
MAX_HEALTH_WAIT = 1200  # seconds max to wait for service health after command completes (20 min)
HEALTH_CHECK_INTERVAL = 15  # seconds between health checks within a single poll cycle

# Model settings
DEFAULT_MODEL_NAME = os.environ.get("MODEL_NAME", "deepseek-ai/DeepSeek-V4-Flash")

# Per-plan model mapping
PLAN_MODEL_MAP = {
    "h200-tp8-eagle": "deepseek-ai/DeepSeek-V4-Flash",
    "h200-tp8-eagle-0731": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "b300-tp8-eagle": "deepseek-ai/DeepSeek-V4-Flash",
    "b300-tp8-eagle-0731": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "b300-pd-2p2d": "deepseek-ai/DeepSeek-V4-Flash",
    "b300-pd-3p1d": "deepseek-ai/DeepSeek-V4-Flash",
}

# Path to bundled compose files (packaged with the Lambda)
COMPOSE_FILES_DIR = Path(__file__).parent / "compose-files"

# S3 bucket for compose files (runtime override without cdk deploy)
COMPOSE_BUCKET = os.environ.get("COMPOSE_BUCKET", "")


# ─── Helpers ────────────────────────────────────────────────────────────────


def _terminate_instance(instance_id: str, region: str) -> None:
    """Terminate an EC2 instance to stop billing."""
    if not instance_id or not region:
        return
    try:
        ec2 = boto3.client("ec2", region_name=region)
        ec2.terminate_instances(InstanceIds=[instance_id])
        logger.info("Terminated instance %s in %s", instance_id, region)
    except ClientError as e:
        logger.error("Failed to terminate instance %s: %s", instance_id, e)


def _get_booking_by_id(booking_id: str) -> dict:
    """Fetch a booking directly by its ID."""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(BOOKING_TABLE)

    try:
        resp = table.get_item(Key={"bookingId": booking_id})
        return resp.get("Item", {})
    except ClientError as e:
        logger.error("Failed to get booking %s: %s", booking_id, e)
    return {}


def _get_booking_by_instance(instance_id: str) -> dict:
    """Find the booking associated with an instance ID (fallback for legacy events)."""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(BOOKING_TABLE)

    try:
        resp = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr("instanceId").eq(
                instance_id
            )
        )
        items = resp.get("Items", [])
        if items:
            return items[0]
    except ClientError as e:
        logger.error("Failed to query booking for instance %s: %s", instance_id, e)
    return {}


def _get_deploying_bookings() -> list:
    """Get all bookings with status=deploying."""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(BOOKING_TABLE)

    try:
        resp = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr("status").eq("deploying")
        )
        return resp.get("Items", [])
    except ClientError as e:
        logger.error("Failed to scan deploying bookings: %s", e)
    return []


def _update_booking_status(
    booking_id: str,
    status: str,
    endpoint: str = "",
    ssm_command_id: str = "",
    command_completed_at: str = "",
) -> None:
    """Update booking status in DynamoDB."""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(BOOKING_TABLE)

    update_expr = "SET #s = :s, updatedAt = :u"
    expr_values = {
        ":s": status,
        ":u": datetime.now(timezone.utc).isoformat(),
    }
    expr_names = {"#s": "status"}

    if endpoint:
        update_expr += ", endpoint = :e"
        expr_values[":e"] = endpoint

    if ssm_command_id:
        update_expr += ", ssmCommandId = :cmd"
        expr_values[":cmd"] = ssm_command_id

    if command_completed_at:
        update_expr += ", commandCompletedAt = :cca"
        expr_values[":cca"] = command_completed_at

    try:
        table.update_item(
            Key={"bookingId": booking_id},
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values,
        )
    except ClientError as e:
        logger.error("Failed to update booking %s: %s", booking_id, e)


def _send_notification(
    title: str, message: str, booking: dict, event_type: str = "failed"
) -> None:
    """Send notification via Feishu webhook (and SNS as fallback)."""
    from notifications import send_notification

    send_notification(
        title=title,
        message=message,
        event_type=event_type,
        booking_data=booking,
    )

    # Also publish to SNS as fallback
    if not NOTIFICATION_TOPIC_ARN:
        return
    try:
        sns = boto3.client("sns")
        full_message = f"{message}\n\nBooking: {json.dumps(booking, default=str)}"
        sns.publish(
            TopicArn=NOTIFICATION_TOPIC_ARN,
            Subject=f"[T-POT] {title}"[:100],
            Message=full_message,
        )
    except ClientError as e:
        logger.warning("Failed to send SNS notification: %s", e)


def _wait_for_ssm(ssm_client, instance_id: str, timeout: int = SSM_WAIT_TIMEOUT) -> bool:
    """Wait for instance to be registered with SSM."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            resp = ssm_client.describe_instance_information(
                Filters=[
                    {"Key": "InstanceIds", "Values": [instance_id]}
                ]
            )
            instances = resp.get("InstanceInformationList", [])
            if instances and instances[0].get("PingStatus") == "Online":
                logger.info("Instance %s is SSM-reachable", instance_id)
                return True
        except ClientError as e:
            logger.debug("SSM check failed: %s", e)

        time.sleep(15)

    logger.error("Timeout waiting for SSM readiness on %s", instance_id)
    return False


def _send_deploy_command(
    ssm_client, instance_id: str, commands: list, timeout: int = SSM_COMMAND_TIMEOUT
) -> str:
    """Send a long-running SSM command and return the command_id immediately.

    Does NOT wait for command completion. Returns empty string on failure.
    """
    try:
        resp = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
            TimeoutSeconds=timeout,
        )
        command_id = resp["Command"]["CommandId"]
        logger.info("Sent SSM command %s to %s (timeout=%ds)", command_id, instance_id, timeout)
        return command_id
    except ClientError as e:
        logger.error("Failed to send SSM command: %s", e)
        return ""


def _check_command_status(ssm_client, command_id: str, instance_id: str) -> str:
    """Check the status of an SSM command invocation.

    Returns one of: 'Success', 'Failed', 'InProgress', 'Error'
    """
    try:
        result = ssm_client.get_command_invocation(
            CommandId=command_id,
            InstanceId=instance_id,
        )
        status = result.get("Status", "")
        if status == "Success":
            return "Success"
        elif status in ("Failed", "Cancelled", "TimedOut"):
            logger.error(
                "SSM command %s failed with status %s: %s",
                command_id, status, result.get("StandardErrorContent", "")[:500]
            )
            return "Failed"
        elif status in ("InProgress", "Pending", "Delayed"):
            return "InProgress"
        else:
            logger.warning("Unexpected SSM command status: %s", status)
            return "InProgress"
    except ClientError as e:
        if "InvocationDoesNotExist" in str(e):
            # Command may not have propagated yet
            return "InProgress"
        logger.error("Error checking command %s: %s", command_id, e)
        return "Error"


def _load_compose_content(compose_file: str) -> str:
    """Load compose file content. Tries S3 first, falls back to local bundle."""
    # Try S3 first
    if COMPOSE_BUCKET:
        try:
            s3 = boto3.client("s3")
            resp = s3.get_object(Bucket=COMPOSE_BUCKET, Key=f"compose-files/{compose_file}")
            content = resp["Body"].read().decode("utf-8")
            logger.info("Loaded compose file from S3: s3://%s/compose-files/%s", COMPOSE_BUCKET, compose_file)
            return content
        except ClientError as e:
            logger.warning("Failed to load from S3, falling back to bundle: %s", e)

    # Fallback to local bundle
    compose_path = COMPOSE_FILES_DIR / compose_file
    if compose_path.exists():
        logger.info("Loaded compose file from local bundle: %s", compose_path)
        return compose_path.read_text()

    logger.error("Compose file not found in S3 or bundle: %s", compose_file)
    return ""


def _get_compose_commands(deployment_plan: str, compose_file: str, model_name: str = "") -> list:
    """Generate the full deployment commands including model download.

    The command sequence is:
      1. NVMe RAID setup
      2. Model directory creation + HuggingFace download
      3. docker compose pull (47GB image, ~5-15 min)
      4. docker compose up -d
      5. Done marker

    The compose file content is inlined via heredoc so no external S3 bucket
    is required.
    """
    if not model_name:
        model_name = DEFAULT_MODEL_NAME
    model_local_path = f"/opt/dlami/nvme/models/{model_name.replace('/', '__')}"

    compose_content = _load_compose_content(compose_file)
    if not compose_content:
        return [
            "#!/bin/bash",
            f"echo 'ERROR: compose file {compose_file} not found in Lambda bundle' >&2",
            "exit 1",
        ]

    commands = [
        "#!/bin/bash",
        "set -euo pipefail",
        "mkdir -p /var/log/tpot-bench",
        "exec 1>/var/log/tpot-bench/deploy.log 2>&1",
        "echo 'Starting deployment...'",
        # Create scripts directory
        "mkdir -p /opt/tpot-bench/scripts",
        # Write compose file via heredoc
        f"cat << 'COMPOSE_EOF' > /opt/tpot-bench/scripts/{compose_file}",
        compose_content,
        "COMPOSE_EOF",
        # ─── Step 1: NVMe RAID setup ───────────────────────────────────
        "echo '=== Step 1: NVMe RAID setup ==='",
        "if [ -b /dev/nvme1n1 ]; then",
        "  echo 'Setting up NVMe RAID...'",
        "  NVME_DEVICES=$(ls /dev/nvme[1-9]n1 2>/dev/null || true)",
        "  if [ -n \"$NVME_DEVICES\" ]; then",
        "    DEVICE_COUNT=$(echo \"$NVME_DEVICES\" | wc -l)",
        "    mdadm --create /dev/md0 --level=0 --raid-devices=$DEVICE_COUNT $NVME_DEVICES --force || true",
        "    mkfs.xfs /dev/md0 || true",
        "    mkdir -p /mnt/nvme",
        "    mount /dev/md0 /mnt/nvme || true",
        "    echo 'NVMe RAID mounted at /mnt/nvme'",
        "  fi",
        "fi",
        # ─── Step 2: Model directory + HuggingFace download ────────────
        "echo '=== Step 2: Model weight download ==='",
        "mkdir -p /opt/dlami/nvme/models",
        "# If NVMe is mounted, use it for model storage and symlink",
        "if mountpoint -q /mnt/nvme 2>/dev/null; then",
        "  mkdir -p /mnt/nvme/models",
        "  rm -rf /opt/dlami/nvme/models",
        "  ln -sf /mnt/nvme/models /opt/dlami/nvme/models",
        "  echo 'Using NVMe storage for models via symlink'",
        "fi",
        f"echo 'Downloading model weights from HuggingFace: {model_name}'",
        "pip3 install -q huggingface_hub",
        f"python3 -c \"from huggingface_hub import snapshot_download; snapshot_download('{model_name}', local_dir='{model_local_path}')\"",
        "echo 'Model download from HuggingFace completed'",
        # ─── Step 3a: Force stop ALL existing containers (GPU memory release) ───
        "echo '=== Step 3a: Stopping all existing containers ==='",
        "cd /opt/tpot-bench/scripts",
        "# Stop all containers from any previous compose project",
        "for f in /opt/tpot-bench/scripts/docker-compose-*.yaml; do",
        "  if [ -f \"$f\" ]; then",
        "    echo \"Stopping compose stack: $f\"",
        "    docker compose -f \"$f\" down --remove-orphans --timeout 30 2>/dev/null || true",
        "  fi",
        "done",
        "# Force kill any remaining sglang/gpu containers that might hold VRAM",
        'docker ps -q --filter "ancestor=lmsysorg/sglang:v0.5.17-cu130" | xargs -r docker rm -f 2>/dev/null || true',
        'docker ps -q --filter "name=sglang" | xargs -r docker rm -f 2>/dev/null || true',
        'docker ps -q --filter "name=prefill" | xargs -r docker rm -f 2>/dev/null || true',
        'docker ps -q --filter "name=decode" | xargs -r docker rm -f 2>/dev/null || true',
        'docker ps -q --filter "name=router" | xargs -r docker rm -f 2>/dev/null || true',
        "# Wait for GPU memory to be released",
        "echo 'Waiting 10s for GPU memory release...'",
        "sleep 10",
        "# Verify GPU is free",
        "nvidia-smi --query-gpu=memory.used --format=csv,noheader || true",
        "echo '=== All previous containers cleared ==='",
        # ─── Step 3b: Docker compose pull ──────────────────────────────
        "echo '=== Step 3b: Docker compose pull ==='",
        f"docker compose -f {compose_file} pull",
        # ─── Step 4: Docker compose up ─────────────────────────────────
        "echo '=== Step 4: Docker compose up ==='",
        f"docker compose -f {compose_file} up -d",
        # ─── Step 5: Done marker ───────────────────────────────────────
        f"echo '=== Deployment completed for plan: {deployment_plan} ==='",
    ]
    return commands


def _check_health(ssm_client, instance_id: str) -> bool:
    """Check if the SGLang service is healthy on port 30080."""
    try:
        resp = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={
                "commands": [
                    f"curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{SGLANG_PORT}/health || echo 'fail'"
                ]
            },
            TimeoutSeconds=30,
        )
        command_id = resp["Command"]["CommandId"]

        # Wait for this short command
        time.sleep(5)
        for _ in range(5):
            try:
                result = ssm_client.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=instance_id,
                )
                status = result.get("Status", "")
                if status == "Success":
                    output = result.get("StandardOutputContent", "").strip()
                    return output == "200"
                elif status in ("Failed", "Cancelled", "TimedOut"):
                    return False
            except ClientError:
                pass
            time.sleep(3)
    except ClientError as e:
        logger.debug("Health check command failed: %s", e)
    return False


def _get_public_ip(ec2_client, instance_id: str) -> str:
    """Get the public IP of an instance."""
    try:
        resp = ec2_client.describe_instances(InstanceIds=[instance_id])
        if resp["Reservations"] and resp["Reservations"][0]["Instances"]:
            return resp["Reservations"][0]["Instances"][0].get("PublicIpAddress", "")
    except ClientError as e:
        logger.error("Failed to get public IP for %s: %s", instance_id, e)
    return ""


# ─── Phase 1: Deploy ────────────────────────────────────────────────────────


def _handle_deploy(event):
    """Phase 1: Send long-running SSM deploy command and return immediately.

    Expected event format (from poller direct invocation):
    {
      "detail": {
        "instance-id": "i-xxx",
        "state": "running"
      },
      "booking_id": "booking-xxx"
    }
    """
    # Extract instance ID from event
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "")
    state = detail.get("state", "")

    if not instance_id:
        logger.warning("No instance-id in event")
        return {"statusCode": 400, "body": "Missing instance-id"}

    if state != "running":
        logger.info("Instance %s state is %s, not running. Skipping.", instance_id, state)
        return {"statusCode": 200, "body": "Not a running state event"}

    # Look up booking: prefer booking_id from event, fall back to scan
    booking_id = event.get("booking_id", "")
    if booking_id:
        booking = _get_booking_by_id(booking_id)
    else:
        booking = _get_booking_by_instance(instance_id)
    if not booking:
        logger.info("No booking found for instance %s, skipping", instance_id)
        return {"statusCode": 200, "body": "No booking for this instance"}

    booking_id = booking["bookingId"]
    deployment_plan = booking.get("deploymentPlan", "")
    region = booking.get("region", "us-east-1")

    logger.info(
        "Phase 1: Starting deployment for booking %s, instance %s, plan %s",
        booking_id,
        instance_id,
        deployment_plan,
    )

    # Determine compose file from deployment plan
    plan_compose_map = {
        "h200-tp8-eagle": "docker-compose-tp8-h200.yaml",
        "h200-tp8-eagle-0731": "docker-compose-tp8-h200-0731.yaml",
        "b300-tp8-eagle": "docker-compose-tp8-b300.yaml",
        "b300-tp8-eagle-0731": "docker-compose-tp8-b300-0731.yaml",
        "b300-pd-2p2d": "docker-compose-pd-2p2d.yaml",
        "b300-pd-3p1d": "docker-compose-pd-v4flash-b300.yaml",
    }
    compose_file = plan_compose_map.get(deployment_plan, "docker-compose.yaml")

    # Determine model name for this plan
    model_name = PLAN_MODEL_MAP.get(deployment_plan, DEFAULT_MODEL_NAME)

    ssm_client = boto3.client("ssm", region_name=region)

    # Wait for SSM readiness
    if not _wait_for_ssm(ssm_client, instance_id):
        _update_booking_status(booking_id, "failed")
        _send_notification(
            f"Deployment failed: {deployment_plan}",
            f"Instance {instance_id} did not become SSM-reachable. 实例已自动终止，避免继续计费",
            booking,
            event_type="ssm_not_reachable",
        )
        _terminate_instance(instance_id, region)
        return {"statusCode": 500, "body": "SSM timeout"}

    # Generate deployment commands (now includes model download)
    commands = _get_compose_commands(deployment_plan, compose_file, model_name)

    # Send the long-running command (does NOT wait for completion)
    command_id = _send_deploy_command(ssm_client, instance_id, commands, timeout=SSM_COMMAND_TIMEOUT)

    if not command_id:
        _update_booking_status(booking_id, "failed")
        _send_notification(
            f"Deployment failed: {deployment_plan}",
            f"Failed to send SSM deploy command to {instance_id}. 实例已自动终止，避免继续计费",
            booking,
            event_type="ssm_command_send_failed",
        )
        _terminate_instance(instance_id, region)
        return {"statusCode": 500, "body": "Failed to send SSM command"}

    # Store command_id and update status to deploying
    _update_booking_status(booking_id, "deploying", ssm_command_id=command_id)

    logger.info(
        "Phase 1 complete: booking %s, command %s sent. Returning immediately.",
        booking_id,
        command_id,
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Deploy command sent, awaiting completion",
            "bookingId": booking_id,
            "ssmCommandId": command_id,
        }),
    }


# ─── Phase 2: Check Progress ────────────────────────────────────────────────


def _handle_check_progress():
    """Phase 2: Check status of all deploying bookings.

    Scans for bookings with status=deploying, checks their SSM command status,
    and updates accordingly.
    """
    deploying_bookings = _get_deploying_bookings()

    if not deploying_bookings:
        logger.info("No deploying bookings to check")
        return {"statusCode": 200, "body": "No deploying bookings"}

    logger.info("Checking progress for %d deploying bookings", len(deploying_bookings))
    results = []

    for booking in deploying_bookings:
        booking_id = booking["bookingId"]
        instance_id = booking.get("instanceId", "")
        command_id = booking.get("ssmCommandId", "")
        region = booking.get("region", "us-east-1")
        deployment_plan = booking.get("deploymentPlan", "")

        if not command_id or not instance_id:
            logger.warning(
                "Booking %s missing ssmCommandId or instanceId, marking failed",
                booking_id,
            )
            _update_booking_status(booking_id, "failed")
            _send_notification(
                f"Deployment failed: {deployment_plan}",
                f"Booking {booking_id} missing command tracking data. 实例已自动终止，避免继续计费",
                booking,
                event_type="missing_command_data",
            )
            _terminate_instance(instance_id, region)
            results.append({"bookingId": booking_id, "result": "failed_no_data"})
            continue

        ssm_client = boto3.client("ssm", region_name=region)
        ec2_client = boto3.client("ec2", region_name=region)

        # Check SSM command status
        cmd_status = _check_command_status(ssm_client, command_id, instance_id)

        if cmd_status == "InProgress":
            logger.info("Booking %s: command %s still in progress", booking_id, command_id)
            results.append({"bookingId": booking_id, "result": "in_progress"})
            continue

        elif cmd_status == "Failed" or cmd_status == "Error":
            logger.error("Booking %s: command %s failed", booking_id, command_id)
            _update_booking_status(booking_id, "failed")
            _send_notification(
                f"Deployment failed: {deployment_plan}",
                f"SSM deploy command failed on {instance_id} (command: {command_id}). 实例已自动终止，避免继续计费",
                booking,
                event_type="deploy_command_failed",
            )
            _terminate_instance(instance_id, region)
            results.append({"bookingId": booking_id, "result": "failed"})
            continue

        elif cmd_status == "Success":
            logger.info("Booking %s: command %s succeeded, checking health", booking_id, command_id)

            # Record commandCompletedAt if this is the first time we see Success
            command_completed_at = booking.get("commandCompletedAt", "")
            if not command_completed_at:
                command_completed_at = datetime.now(timezone.utc).isoformat()
                _update_booking_status(
                    booking_id, "deploying", command_completed_at=command_completed_at
                )
                logger.info(
                    "Booking %s: first time seeing command complete, recorded commandCompletedAt=%s",
                    booking_id,
                    command_completed_at,
                )

            # Attempt a single short health check (up to 30 seconds)
            healthy = False
            start = time.time()
            while time.time() - start < 30:
                if _check_health(ssm_client, instance_id):
                    healthy = True
                    break
                time.sleep(HEALTH_CHECK_INTERVAL)

            if not healthy:
                # Calculate elapsed time since command completed
                completed_time = datetime.fromisoformat(command_completed_at)
                elapsed = (datetime.now(timezone.utc) - completed_time).total_seconds()

                if elapsed < MAX_HEALTH_WAIT:
                    logger.info(
                        "Booking %s: health not ready yet, elapsed %.0fs, will retry on next poll",
                        booking_id,
                        elapsed,
                    )
                    results.append({"bookingId": booking_id, "result": "waiting_health"})
                    continue
                else:
                    # Exceeded MAX_HEALTH_WAIT - truly failed
                    logger.error(
                        "Booking %s: health check failed after %.0fs (max %ds), marking failed",
                        booking_id,
                        elapsed,
                        MAX_HEALTH_WAIT,
                    )
                    _update_booking_status(booking_id, "failed")
                    _send_notification(
                        f"Deployment failed: {deployment_plan}",
                        f"Service on {instance_id} did not become healthy after {int(elapsed)}s (max {MAX_HEALTH_WAIT}s). 实例已自动终止，避免继续计费",
                        booking,
                        event_type="health_check_timeout",
                    )
                    _terminate_instance(instance_id, region)
                    results.append({"bookingId": booking_id, "result": "failed_health"})
                    continue

            # Service is healthy - get endpoint
            public_ip = _get_public_ip(ec2_client, instance_id)
            endpoint = f"http://{public_ip}:{SGLANG_PORT}/v1" if public_ip else ""

            # Update booking to ready
            _update_booking_status(booking_id, "ready", endpoint=endpoint)

            # Apply IP whitelist if configured
            whitelist_ips = booking.get("whitelistIps", [])
            if whitelist_ips:
                try:
                    from ec2_manager import update_security_group
                    update_security_group(instance_id, region, whitelist_ips)
                except ImportError:
                    logger.warning("ec2_manager not available in deployer context")

            _send_notification(
                f"Deployment ready: {deployment_plan}",
                f"Service is healthy and ready.\nEndpoint: {endpoint}",
                {**booking, "endpoint": endpoint, "status": "ready"},
                event_type="deployment_ready",
            )
            results.append({"bookingId": booking_id, "result": "ready", "endpoint": endpoint})

    return {
        "statusCode": 200,
        "body": json.dumps({"results": results}),
    }


# ─── Lambda Handler ─────────────────────────────────────────────────────────


def handler(event, context):
    """Main entry point. Routes to Phase 1 or Phase 2 based on event content.

    Phase 2 (check_progress): triggered by EventBridge schedule with
      {"action": "check_progress"} payload.

    Phase 1 (deploy): triggered by capacity poller direct invocation with
      {"detail": {"instance-id": "...", "state": "running"}, "booking_id": "..."}
    """
    logger.info("Deployer invoked. Event: %s", json.dumps(event, default=str))

    action = event.get("action", "")

    if action == "check_progress":
        return _handle_check_progress()
    else:
        # Default: Phase 1 deploy (invoked by poller)
        return _handle_deploy(event)
