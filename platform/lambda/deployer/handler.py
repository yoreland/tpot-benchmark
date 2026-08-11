"""
T-POT Booking Platform - Deployer Lambda Handler.

Triggered by EventBridge rule monitoring EC2 instance state changes.
When a tpot-benchmark instance reaches 'running' state:
  1. Waits for instance to be reachable via SSM
  2. Executes docker-compose deployment via SSM RunCommand
  3. Monitors health endpoint on port 30080
  4. Updates booking status and sends notifications
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configuration ──────────────────────────────────────────────────────────

BOOKING_TABLE = os.environ.get("BOOKING_TABLE", "TpotBookingTable")
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")
PROJECT_TAG = "tpot-benchmark"
SGLANG_PORT = 30080

# Timeouts - must fit within Lambda's 10-minute (600s) timeout.
# Budget: SSM wait (120s) + deploy command (240s) + health check (180s) = 540s max
SSM_WAIT_TIMEOUT = 120  # seconds to wait for SSM readiness
HEALTH_CHECK_TIMEOUT = 180  # seconds to wait for service health
HEALTH_CHECK_INTERVAL = 15  # seconds between health checks
DEPLOY_COMMAND_TIMEOUT = 240  # seconds for docker-compose deployment command

# Compose file paths relative to the scripts directory on instance
SCRIPTS_S3_PREFIX = "scripts"


# ─── Helpers ────────────────────────────────────────────────────────────────


def _get_booking_by_instance(instance_id: str) -> dict:
    """Find the booking associated with an instance ID."""
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


def _update_booking_status(
    booking_id: str, status: str, endpoint: str = ""
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


def _run_command(
    ssm_client, instance_id: str, commands: list, timeout: int = 600
) -> dict:
    """Execute commands on instance via SSM RunCommand.

    Returns dict with 'success' bool, 'output' string, and 'error' string.
    """
    try:
        resp = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
            TimeoutSeconds=timeout,
        )
        command_id = resp["Command"]["CommandId"]
        logger.info("Sent SSM command %s to %s", command_id, instance_id)

        # Wait for command completion
        waiter_start = time.time()
        while time.time() - waiter_start < timeout:
            time.sleep(10)
            try:
                result = ssm_client.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=instance_id,
                )
                status = result.get("Status", "")
                if status in ("Success",):
                    return {
                        "success": True,
                        "output": result.get("StandardOutputContent", ""),
                        "error": "",
                    }
                elif status in ("Failed", "Cancelled", "TimedOut"):
                    return {
                        "success": False,
                        "output": result.get("StandardOutputContent", ""),
                        "error": result.get("StandardErrorContent", ""),
                    }
            except ClientError as e:
                if "InvocationDoesNotExist" in str(e):
                    continue
                logger.warning("Error checking command status: %s", e)

        return {"success": False, "output": "", "error": "Command timed out"}
    except ClientError as e:
        logger.error("Failed to send SSM command: %s", e)
        return {"success": False, "output": "", "error": str(e)}


def _get_compose_commands(deployment_plan: str, compose_file: str) -> list:
    """Generate the docker-compose deployment commands.

    These commands pull and start the docker-compose stack on the instance.
    The compose files are expected to be available at /opt/tpot-bench/scripts/.
    """
    commands = [
        "set -euo pipefail",
        "exec > >(tee -a /var/log/tpot-bench/deploy.log) 2>&1",
        "echo 'Starting deployment...'",
        # Setup NVMe RAID if available
        "if [ -b /dev/nvme1n1 ]; then",
        "  echo 'Setting up NVMe RAID...'",
        "  mdadm --create /dev/md0 --level=0 --raid-devices=$(ls /dev/nvme[1-9]n1 | wc -l) $(ls /dev/nvme[1-9]n1) --force || true",
        "  mkfs.xfs /dev/md0 || true",
        "  mkdir -p /mnt/nvme",
        "  mount /dev/md0 /mnt/nvme || true",
        "fi",
        # Pull docker images and start services
        f"echo 'Deploying with compose file: {compose_file}'",
        "cd /opt/tpot-bench/scripts",
        # Fetch compose files from S3 if not present
        "if [ ! -f docker-compose.yaml ]; then",
        f"  echo 'Fetching {compose_file}...'",
        f"  aws s3 cp s3://tpot-bench-scripts/{compose_file} docker-compose.yaml || true",
        "fi",
        # Stop any existing services
        "docker compose down --remove-orphans 2>/dev/null || true",
        # Pull and start
        f"if [ -f {compose_file} ]; then",
        f"  docker compose -f {compose_file} pull",
        f"  docker compose -f {compose_file} up -d",
        "else",
        "  docker compose pull",
        "  docker compose up -d",
        "fi",
        f"echo 'Deployment started for plan: {deployment_plan}'",
    ]
    return commands


def _check_health(ssm_client, instance_id: str) -> bool:
    """Check if the SGLang service is healthy on port 30080."""
    result = _run_command(
        ssm_client,
        instance_id,
        [
            f"curl -s -o /dev/null -w '%{{http_code}}' http://localhost:{SGLANG_PORT}/health || echo 'fail'"
        ],
        timeout=30,
    )
    if result["success"]:
        output = result["output"].strip()
        return output == "200"
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


# ─── Lambda Handler ─────────────────────────────────────────────────────────


def handler(event, context):
    """Main entry point. Triggered by EC2 state change events.

    Expected event format (from EventBridge):
    {
      "detail": {
        "instance-id": "i-xxx",
        "state": "running"
      }
    }
    """
    logger.info("Deployer invoked. Event: %s", json.dumps(event, default=str))

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

    # Look up booking for this instance
    booking = _get_booking_by_instance(instance_id)
    if not booking:
        logger.info("No booking found for instance %s, skipping", instance_id)
        return {"statusCode": 200, "body": "No booking for this instance"}

    booking_id = booking["bookingId"]
    deployment_plan = booking.get("deploymentPlan", "")
    region = booking.get("region", "us-east-1")

    logger.info(
        "Processing deployment for booking %s, instance %s, plan %s",
        booking_id,
        instance_id,
        deployment_plan,
    )

    # Update status to deploying
    _update_booking_status(booking_id, "deploying")

    # Determine compose file from deployment plan
    plan_compose_map = {
        "h200-tp4-eagle": "docker-compose-tp4-h200.yaml",
        "h200-tp8-eagle": "docker-compose-tp8-h200.yaml",
        "b300-tp8-eagle": "docker-compose-tp8-b300.yaml",
        "b300-pd-2p2d": "docker-compose-pd-2p2d.yaml",
        "b200-tp8-unified": "docker-compose-tp8-b200.yaml",
    }
    compose_file = plan_compose_map.get(deployment_plan, "docker-compose.yaml")

    ssm_client = boto3.client("ssm", region_name=region)
    ec2_client = boto3.client("ec2", region_name=region)

    # Wait for SSM readiness
    if not _wait_for_ssm(ssm_client, instance_id):
        _update_booking_status(booking_id, "failed")
        _send_notification(
            f"Deployment failed: {deployment_plan}",
            f"Instance {instance_id} did not become SSM-reachable",
            booking,
            event_type="ssm_not_reachable",
        )
        return {"statusCode": 500, "body": "SSM timeout"}

    # Run deployment commands
    commands = _get_compose_commands(deployment_plan, compose_file)
    result = _run_command(ssm_client, instance_id, commands, timeout=DEPLOY_COMMAND_TIMEOUT)

    if not result["success"]:
        logger.error("Deployment command failed: %s", result["error"])
        _update_booking_status(booking_id, "failed")
        _send_notification(
            f"Deployment failed: {deployment_plan}",
            f"Docker compose deployment failed on {instance_id}: {result['error'][:200]}",
            booking,
            event_type="docker_compose_failed",
        )
        return {"statusCode": 500, "body": "Deployment failed"}

    # Wait for health check
    logger.info("Deployment initiated, waiting for health check...")
    healthy = False
    start = time.time()
    while time.time() - start < HEALTH_CHECK_TIMEOUT:
        time.sleep(HEALTH_CHECK_INTERVAL)
        if _check_health(ssm_client, instance_id):
            healthy = True
            break

    if not healthy:
        logger.error("Health check timeout for instance %s", instance_id)
        _update_booking_status(booking_id, "failed")
        _send_notification(
            f"Deployment failed: {deployment_plan}",
            f"Service on {instance_id} did not become healthy within timeout",
            booking,
            event_type="health_check_timeout",
        )
        return {"statusCode": 500, "body": "Health check timeout"}

    # Get endpoint
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

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Deployment successful",
            "bookingId": booking_id,
            "endpoint": endpoint,
        }),
    }
