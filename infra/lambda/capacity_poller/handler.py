"""
tpot-bench-capacity-poller Lambda handler.

Probes spot capacity for p5en.48xlarge (H200) and p6-b300.48xlarge (B300)
across multiple regions/AZs every 3 minutes (triggered by EventBridge).

When capacity is found:
  1. Terminate the probe instance immediately.
  2. Render env prelude + recipe + bootstrap script, upload to S3.
  3. Launch the real benchmark instance with a small user-data stub.
  4. Publish SNS notification.
  5. Disable the EventBridge rule for the launched instance type.

SELF_TERMINATE is set to 'false' so instances stay alive for debugging/SSH.
"""

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACCOUNT_ID = "077090643075"
PROJECT_TAG = "tpot-benchmark"
INSTANCE_PROFILE_NAME = "tpot-bench-ec2-profile"
SG_NAME = "tpot-bench-noingress-sg"
DLAMI_SSM_PARAM = (
    "/aws/service/deeplearning/ami/x86_64/"
    "base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
)
ROOT_VOLUME_GB = 200

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
EVENTBRIDGE_RULE_NAME = os.environ.get(
    "EVENTBRIDGE_RULE_NAME", "tpot-bench-poll-capacity"
)

# Subnet mapping (verified)
SUBNET_MAP = {
    "us-east-1a": "subnet-0ae36a5845b616649",
    "us-east-1c": "subnet-0519fb0c779ad92c7",
    "us-east-2a": "subnet-09bfc4e5573173d64",
    "us-east-2b": "subnet-0c900c1611bf34e49",
    "us-east-2c": "subnet-087bce7226890195e",
    "us-west-2a": "subnet-0570e1b3d4cabf650",
    "us-west-2b": "subnet-020aa087d32834a04",
    "us-west-2c": "subnet-08a022641b49f4630",
    "us-west-2d": "subnet-03f3fa89ad241fbbb",
}

# Target definitions
TARGETS = [
    # H200 targets (p5en.48xlarge)
    {
        "instance_type": "p5en.48xlarge",
        "max_price": "35",
        "region": "us-east-1",
        "azs": ["us-east-1a", "us-east-1c"],
        "recipe_file": "recipes/h200-tp4-fp4-eagle.env",
    },
    {
        "instance_type": "p5en.48xlarge",
        "max_price": "35",
        "region": "us-east-2",
        "azs": ["us-east-2a", "us-east-2b", "us-east-2c"],
        "recipe_file": "recipes/h200-tp4-fp4-eagle.env",
    },
    {
        "instance_type": "p5en.48xlarge",
        "max_price": "35",
        "region": "us-west-2",
        "azs": ["us-west-2a", "us-west-2c", "us-west-2d"],
        "recipe_file": "recipes/h200-tp4-fp4-eagle.env",
    },
    # B300 targets (p6-b300.48xlarge)
    {
        "instance_type": "p6-b300.48xlarge",
        "max_price": "60",
        "region": "us-east-1",
        "azs": ["us-east-1a"],
        "recipe_file": "recipes/b300-pd-hold.env",
    },
    {
        "instance_type": "p6-b300.48xlarge",
        "max_price": "60",
        "region": "us-west-2",
        "azs": ["us-west-2a", "us-west-2b"],
        "recipe_file": "recipes/b300-pd-hold.env",
    },
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Path to co-packaged files (included in Lambda zip)
LAMBDA_DIR = Path(__file__).parent


def _read_packaged_file(relative_path: str) -> str:
    """Read a file co-packaged in the Lambda zip."""
    full_path = LAMBDA_DIR / relative_path
    return full_path.read_text()


def _generate_run_id() -> str:
    """Generate a unique run ID matching the bash script pattern."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    suffix = uuid.uuid4().hex[:4]
    return f"{ts}-{suffix}"


def _get_ami(ssm_client, region: str) -> str:
    """Resolve the latest Deep Learning AMI via SSM parameter."""
    try:
        resp = ssm_client.get_parameter(Name=DLAMI_SSM_PARAM)
        return resp["Parameter"]["Value"]
    except ClientError as e:
        logger.error("Failed to resolve AMI in %s: %s", region, e)
        return ""


def _get_security_group(ec2_client, region: str) -> str:
    """Look up security group by name. Returns empty string if not found (fail-closed)."""
    try:
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": [SG_NAME]}]
        )
        if resp["SecurityGroups"]:
            return resp["SecurityGroups"][0]["GroupId"]
    except ClientError as e:
        logger.error("Error looking up SG %s in %s: %s", SG_NAME, region, e)

    logger.warning(
        "Security group %s not found in %s, skipping region (fail-closed)",
        SG_NAME, region,
    )
    return ""


def _emit_export(name: str, value: str) -> str:
    """Produce a single-quote-safe export line."""
    escaped = value.replace("'", "'\\''")
    return f"export {name}='{escaped}'\n"


def _render_env_prelude(
    run_id: str,
    region: str,
    bucket: str,
    recipe_content: str,
) -> str:
    """Render the env prelude matching launch-bench-ec2.sh logic."""
    lines = [
        "#!/usr/bin/env bash\n",
        "# Rendered by tpot-bench-capacity-poller Lambda. Do not edit.\n",
        "set -euo pipefail\n",
        "mkdir -p /var/log/tpot-bench\n",
    ]

    # All env variables matching the launch script
    env_vars = {
        "RUN_ID": run_id,
        "STAGE": "full",
        "REGION": region,
        "AWS_DEFAULT_REGION": region,
        "RESULTS_BUCKET": bucket,
        "PROJECT_TAG": PROJECT_TAG,
        "NVME_MOUNT": "/mnt/nvme",
        "REQUIRE_INSTANCE_STORE": "true",
        "CHECKPOINT_GB": "160",
        "STORAGE_MARGIN_GB": "80",
        "MODEL_NAME": "deepseek-ai/DeepSeek-V4-Flash",
        "CHECKPOINT_S3_URI": "",
        "FETCH_CHECKPOINT": "true",
        "RUN_SERVER": "true",
        "SGLANG_IMAGE": "lmsysorg/sglang:latest",
        "SGLANG_LAUNCH_CMD": "python3 -m sglang.launch_server",
        "SGLANG_EXTRA_ARGS": "",
        "SGLANG_SERVE_ARGS": "",
        "TP_SIZE": "8",
        "MEM_FRACTION_STATIC": "0.85",
        "SERVER_PORT": "30000",
        "SERVER_READY_TIMEOUT": "2400",
        "SHM_SIZE": "64g",
        "INPUT_TOKENS": "40000",
        "OUTPUT_TOKENS": "1500",
        "OFFICIAL_INPUT_TOKENS": "30000",
        "OFFICIAL_OUTPUT_TOKENS": "4096",
        "NUM_PROMPTS": "50",
        "MAX_CONCURRENCY": "1",
        "STREAM_INTERVAL_SECONDS": "30",
        "GPU_SAMPLE_INTERVAL_SECONDS": "30",
        "SPOT_POLL_INTERVAL_SECONDS": "5",
        "MAX_RUNTIME_MINUTES": "240",
        "SELF_TERMINATE": "false",
    }

    for name, value in env_vars.items():
        lines.append(_emit_export(name, value))

    # Append recipe content (recipe exports will override prelude defaults)
    lines.append("# --- recipe content ---\n")
    lines.append(recipe_content)
    lines.append("\n")

    return "".join(lines)


def _render_full_bootstrap(env_prelude: str, bootstrap_content: str) -> str:
    """Combine env prelude with the bench-bootstrap.sh script.

    Strips the leading shebang from bootstrap_content to avoid a double
    shebang in the concatenated output.
    """
    # Remove leading shebang line from bootstrap if present
    if bootstrap_content.startswith("#!"):
        # Skip the first line (shebang)
        bootstrap_content = bootstrap_content.split("\n", 1)[1]

    return (
        env_prelude
        + "# --- bench-bootstrap.sh ---\n"
        + bootstrap_content
    )


def _render_userdata_stub(region: str, bucket: str, run_id: str) -> str:
    """Render the small S3-fetching user-data stub (under 16KB)."""
    bootstrap_s3_key = f"bootstrap/{run_id}/bench-bootstrap.sh"
    stub = f"""#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/log/tpot-bench /opt/tpot-bench
exec > >(tee -a /var/log/tpot-bench/user-data.log) 2>&1
BOOTSTRAP_URI="s3://{bucket}/{bootstrap_s3_key}"
BOOTSTRAP_LOCAL="/opt/tpot-bench/bench-bootstrap.sh"
echo "[user-data] Fetching $BOOTSTRAP_URI"
for attempt in $(seq 1 30); do
    if aws s3 cp "$BOOTSTRAP_URI" "$BOOTSTRAP_LOCAL" --region {region}; then
        break
    fi
    echo "[user-data] Attempt $attempt failed (instance profile may not be ready), retrying in 10s"
    sleep 10
done
if [[ ! -s "$BOOTSTRAP_LOCAL" ]]; then
    echo "[user-data] FATAL: cannot fetch bootstrap script, shutting down" >&2
    TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \\
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' --max-time 3 || true)"
    IID="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \\
        http://169.254.169.254/latest/meta-data/instance-id --max-time 3 || true)"
    if [[ -n "$IID" ]]; then
        aws ec2 terminate-instances --region {region} --instance-ids "$IID" || shutdown -h now
    else
        shutdown -h now
    fi
    exit 1
fi
chmod +x "$BOOTSTRAP_LOCAL"
exec "$BOOTSTRAP_LOCAL"
"""
    return stub


def _probe_capacity(
    ec2_client, instance_type: str, ami: str, az: str, subnet: str,
    sg: str, max_price: str
) -> str:
    """
    Attempt to launch a probe instance. Returns instance ID on success, empty
    string on failure (InsufficientInstanceCapacity or other error).
    """
    try:
        resp = ec2_client.run_instances(
            ImageId=ami,
            InstanceType=instance_type,
            MinCount=1,
            MaxCount=1,
            SubnetId=subnet,
            SecurityGroupIds=[sg],
            InstanceInitiatedShutdownBehavior="terminate",
            InstanceMarketOptions={
                "MarketType": "spot",
                "SpotOptions": {
                    "MaxPrice": max_price,
                    "SpotInstanceType": "one-time",
                    "InstanceInterruptionBehavior": "terminate",
                },
            },
            TagSpecifications=[
                {
                    "ResourceType": "instance",
                    "Tags": [
                        {"Key": "Name", "Value": "capacity-probe-lambda"},
                        {"Key": "Project", "Value": PROJECT_TAG},
                    ],
                }
            ],
        )
        instance_id = resp["Instances"][0]["InstanceId"]
        logger.info(
            "PROBE SUCCESS: %s @ %s -> %s", instance_type, az, instance_id
        )
        return instance_id
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code in (
            "InsufficientInstanceCapacity",
            "SpotMaxPriceTooLow",
            "MaxSpotInstanceCountExceeded",
            "InstanceLimitExceeded",
        ):
            logger.info(
                "No capacity for %s @ %s: %s", instance_type, az, error_code
            )
        else:
            logger.warning(
                "Probe error for %s @ %s: %s - %s",
                instance_type, az, error_code,
                e.response["Error"].get("Message", ""),
            )
        return ""


def _terminate_instance(ec2_client, instance_id: str) -> None:
    """Terminate an instance, ignoring errors."""
    try:
        ec2_client.terminate_instances(InstanceIds=[instance_id])
        logger.info("Terminated probe instance: %s", instance_id)
    except ClientError as e:
        logger.warning("Failed to terminate %s: %s", instance_id, e)


def _launch_benchmark(
    ec2_client, s3_client, instance_type: str, ami: str, az: str,
    subnet: str, sg: str, max_price: str, region: str,
    recipe_content: str, bootstrap_content: str, run_id: str,
) -> str:
    """
    Launch the real benchmark instance with S3-stub user-data pattern.
    Returns the instance ID on success, empty string on failure.
    """
    bucket = f"tpot-bench-results-{ACCOUNT_ID}-{region}"
    bootstrap_s3_key = f"bootstrap/{run_id}/bench-bootstrap.sh"

    # Render full bootstrap = env prelude + recipe + bench-bootstrap.sh
    env_prelude = _render_env_prelude(run_id, region, bucket, recipe_content)
    full_bootstrap = _render_full_bootstrap(env_prelude, bootstrap_content)

    # Upload full bootstrap to S3
    try:
        s3_client.put_object(
            Bucket=bucket,
            Key=bootstrap_s3_key,
            Body=full_bootstrap.encode("utf-8"),
        )
        logger.info("Uploaded bootstrap to s3://%s/%s", bucket, bootstrap_s3_key)
    except ClientError as e:
        logger.error("Failed to upload bootstrap to S3: %s", e)
        return ""

    # Render user-data stub
    userdata_stub = _render_userdata_stub(region, bucket, run_id)

    # Name tag
    name_tag = f"tpot-bench-{instance_type.replace('.', '-')}"

    try:
        resp = ec2_client.run_instances(
            ImageId=ami,
            InstanceType=instance_type,
            MinCount=1,
            MaxCount=1,
            SubnetId=subnet,
            SecurityGroupIds=[sg],
            IamInstanceProfile={"Name": INSTANCE_PROFILE_NAME},
            InstanceInitiatedShutdownBehavior="terminate",
            MetadataOptions={
                "HttpTokens": "required",
                "HttpEndpoint": "enabled",
                "HttpPutResponseHopLimit": 2,
            },
            BlockDeviceMappings=[
                {
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "VolumeSize": ROOT_VOLUME_GB,
                        "VolumeType": "gp3",
                        "DeleteOnTermination": True,
                    },
                }
            ],
            InstanceMarketOptions={
                "MarketType": "spot",
                "SpotOptions": {
                    "MaxPrice": max_price,
                    "SpotInstanceType": "one-time",
                    "InstanceInterruptionBehavior": "terminate",
                },
            },
            TagSpecifications=[
                {
                    "ResourceType": "instance",
                    "Tags": [
                        {"Key": "Project", "Value": PROJECT_TAG},
                        {"Key": "Name", "Value": name_tag},
                        {"Key": "RunId", "Value": run_id},
                        {"Key": "Stage", "Value": "full"},
                    ],
                },
                {
                    "ResourceType": "volume",
                    "Tags": [
                        {"Key": "Project", "Value": PROJECT_TAG},
                        {"Key": "Name", "Value": name_tag},
                        {"Key": "RunId", "Value": run_id},
                        {"Key": "Stage", "Value": "full"},
                    ],
                },
            ],
            UserData=userdata_stub,
        )
        instance_id = resp["Instances"][0]["InstanceId"]
        logger.info(
            "BENCHMARK LAUNCHED: %s @ %s -> %s (run_id=%s)",
            instance_type, az, instance_id, run_id,
        )
        return instance_id
    except ClientError as e:
        logger.error(
            "Failed to launch benchmark instance %s @ %s: %s",
            instance_type, az, e,
        )
        return ""


def _publish_sns(
    sns_client, instance_type: str, region: str, az: str,
    run_id: str, instance_id: str, max_price: str,
) -> None:
    """Publish SNS notification about successful launch."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set, skipping notification")
        return

    subject = f"[tpot-bench] Capacity found: {instance_type} @ {az}"
    message = json.dumps(
        {
            "event": "capacity_found",
            "instance_type": instance_type,
            "region": region,
            "az": az,
            "run_id": run_id,
            "instance_id": instance_id,
            "max_price_per_hour": max_price,
            "estimated_max_cost": f"${float(max_price) * 4:.2f} (4hr max runtime)",
            "self_terminate": "false",
            "note": "Instance will NOT self-terminate. SSH/SSM in to monitor.",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
        indent=2,
    )

    try:
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject[:100],  # SNS subject max 100 chars
            Message=message,
        )
        logger.info("Published SNS notification for %s @ %s", instance_type, az)
    except ClientError as e:
        logger.warning("Failed to publish SNS: %s", e)


def _disable_eventbridge_rule(events_client) -> None:
    """Disable the EventBridge polling rule."""
    try:
        events_client.disable_rule(Name=EVENTBRIDGE_RULE_NAME)
        logger.info("Disabled EventBridge rule: %s", EVENTBRIDGE_RULE_NAME)
    except ClientError as e:
        logger.warning("Failed to disable EventBridge rule: %s", e)


# ---------------------------------------------------------------------------
# Lambda Handler
# ---------------------------------------------------------------------------


def lambda_handler(event, context):
    """
    Main entry point. Probes spot capacity for all targets. On success,
    terminates probe, launches benchmark, notifies, and disables rule.
    """
    logger.info("Capacity poller invoked. Event: %s", json.dumps(event))

    # Load co-packaged files
    try:
        bootstrap_content = _read_packaged_file("bench-bootstrap.sh")
    except FileNotFoundError:
        logger.error("bench-bootstrap.sh not found in Lambda package")
        return {"statusCode": 500, "body": "Missing bench-bootstrap.sh"}

    # Track launched types in this invocation
    launched_types = {}

    # Support SKIP_INSTANCE_TYPES env var (comma-separated) to skip types already benchmarked
    skip_types = set(
        t.strip() for t in os.environ.get("SKIP_INSTANCE_TYPES", "").split(",") if t.strip()
    )
    if skip_types:
        logger.info("Skipping instance types (already benchmarked): %s", skip_types)

    for target in TARGETS:
        instance_type = target["instance_type"]
        region = target["region"]
        max_price = target["max_price"]
        recipe_file = target["recipe_file"]

        # Skip types the user marked as done
        if instance_type in skip_types:
            continue

        # Skip if already launched this type in this invocation
        if instance_type in launched_types:
            continue

        # Load recipe content
        try:
            recipe_content = _read_packaged_file(recipe_file)
        except FileNotFoundError:
            logger.error("Recipe file not found: %s", recipe_file)
            continue

        # Create regional clients
        ec2_client = boto3.client("ec2", region_name=region)
        ssm_client = boto3.client("ssm", region_name=region)
        s3_client = boto3.client("s3", region_name=region)

        # Resolve AMI for this region
        ami = _get_ami(ssm_client, region)
        if not ami:
            logger.warning("Cannot resolve AMI in %s, skipping", region)
            continue

        # Resolve security group
        sg = _get_security_group(ec2_client, region)
        if not sg:
            logger.warning("Cannot resolve SG in %s, skipping", region)
            continue

        # Probe each AZ
        for az in target["azs"]:
            subnet = SUBNET_MAP.get(az)
            if not subnet:
                logger.warning("No subnet for %s, skipping", az)
                continue

            # Direct launch: skip probe-then-relaunch pattern.
            # B300 capacity windows are <20s; probe+terminate+relaunch loses
            # the race every time. Instead, launch the full benchmark instance
            # directly. If no capacity, RunInstances simply returns an error.
            run_id = _generate_run_id()

            instance_id = _launch_benchmark(
                ec2_client, s3_client, instance_type, ami, az, subnet, sg,
                max_price, region, recipe_content, bootstrap_content, run_id,
            )

            if not instance_id:
                continue
                continue

            # Success! Record, notify, and potentially disable rule
            launched_types[instance_type] = {
                "az": az,
                "region": region,
                "instance_id": instance_id,
                "run_id": run_id,
            }

            # Publish SNS
            sns_client = boto3.client("sns", region_name="us-east-1")
            _publish_sns(
                sns_client, instance_type, region, az,
                run_id, instance_id, max_price,
            )

            # If both types launched, disable the rule entirely
            if len(launched_types) >= 2:
                events_client = boto3.client("events", region_name="us-east-1")
                _disable_eventbridge_rule(events_client)

            # Move to next instance type
            break

    # If at least one type launched but not both, check if we should disable
    # We only disable when BOTH types are launched (user wants both benchmarks)
    if len(launched_types) >= 2:
        logger.info(
            "Both instance types launched successfully. Rule disabled."
        )
    elif launched_types:
        # One type launched - disable rule since we got capacity
        # (User can re-enable if they want the other type too)
        events_client = boto3.client("events", region_name="us-east-1")
        _disable_eventbridge_rule(events_client)
        logger.info(
            "One instance type launched (%s). Rule disabled.",
            list(launched_types.keys())[0],
        )

    result = {
        "statusCode": 200,
        "body": json.dumps(
            {
                "launched": {
                    k: v for k, v in launched_types.items()
                },
                "message": (
                    f"Launched {len(launched_types)} instance type(s)"
                    if launched_types
                    else "No capacity found this round"
                ),
            }
        ),
    }
    logger.info("Result: %s", result["body"])
    return result
