"""
T-POT Booking Platform - Capacity Poller Lambda Handler.

Triggered by EventBridge on a schedule. Queries DynamoDB for bookings with
status=polling, then attempts to launch spot instances in configured regions.

Reuses the direct-launch pattern from the existing capacity poller (probe-then-launch
is too slow for B300 capacity windows < 20s).
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configuration ──────────────────────────────────────────────────────────

ACCOUNT_ID = os.environ.get("AWS_ACCOUNT_ID", boto3.client("sts").get_caller_identity()["Account"] if not os.environ.get("AWS_LAMBDA_FUNCTION_NAME") else "")
PROJECT_TAG = "tpot-benchmark"
BOOKING_TABLE = os.environ.get("BOOKING_TABLE", "TpotBookingTable")
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")
INSTANCE_PROFILE = os.environ.get("INSTANCE_PROFILE", "tpot-bench-ec2-profile")
SECURITY_GROUP_NAME = os.environ.get("SECURITY_GROUP", "tpot-bench-noingress-sg")
REGIONS = os.environ.get("REGIONS", "us-east-1,us-east-2,us-west-2").split(",")

DLAMI_SSM_PARAM = (
    "/aws/service/deeplearning/ami/x86_64/"
    "base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id"
)
ROOT_VOLUME_GB = 200

# Subnet mapping loaded from environment or SSM at runtime.
# Format: comma-separated "az=subnet-id" pairs in SUBNET_MAP_CONFIG env var.
# Falls back to defaults if not configured.
_SUBNET_MAP_RAW = os.environ.get("SUBNET_MAP_CONFIG", "")


def _load_subnet_map() -> dict:
    """Load subnet mapping from env config or return defaults."""
    if _SUBNET_MAP_RAW:
        result = {}
        for entry in _SUBNET_MAP_RAW.split(","):
            if "=" in entry:
                az, subnet = entry.split("=", 1)
                result[az.strip()] = subnet.strip()
        return result
    # Default mapping (override via SUBNET_MAP_CONFIG env var)
    return {
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


SUBNET_MAP = _load_subnet_map()

# Max spot prices per instance type
MAX_PRICES = {
    "p5en.48xlarge": "35",
    "p6-b300.48xlarge": "60",
    "p6-b200.48xlarge": "60",
}

# AZs to try per region per instance type
INSTANCE_AZS = {
    "p5en.48xlarge": {
        "us-east-1": ["us-east-1a", "us-east-1c"],
        "us-east-2": ["us-east-2a", "us-east-2b", "us-east-2c"],
        "us-west-2": ["us-west-2a", "us-west-2c", "us-west-2d"],
    },
    "p6-b300.48xlarge": {
        "us-east-1": ["us-east-1a"],
        "us-west-2": ["us-west-2a", "us-west-2b"],
    },
    "p6-b200.48xlarge": {
        "us-east-1": ["us-east-1a"],
        "us-west-2": ["us-west-2a", "us-west-2b"],
    },
}


# ─── Helpers ────────────────────────────────────────────────────────────────


def _get_ami(ssm_client) -> str:
    """Resolve the latest Deep Learning AMI via SSM parameter."""
    try:
        resp = ssm_client.get_parameter(Name=DLAMI_SSM_PARAM)
        return resp["Parameter"]["Value"]
    except ClientError as e:
        logger.error("Failed to resolve AMI: %s", e)
        return ""


def _get_security_group(ec2_client) -> str:
    """Look up security group by name."""
    try:
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": [SECURITY_GROUP_NAME]}]
        )
        if resp["SecurityGroups"]:
            return resp["SecurityGroups"][0]["GroupId"]
    except ClientError as e:
        logger.error("Error looking up SG: %s", e)
    return ""


def _generate_run_id() -> str:
    """Generate a unique run ID."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    suffix = uuid.uuid4().hex[:4]
    return f"{ts}-{suffix}"


def _render_userdata(booking_id: str, deployment_plan: str) -> str:
    """Render minimal user-data that tags the instance and signals readiness.

    The actual deployment is handled by the deployer Lambda via SSM
    once the instance reaches 'running' state.
    """
    return f"""#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/log/tpot-bench

# Tag this instance with booking metadata
TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' --max-time 3)"
INSTANCE_ID="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id --max-time 3)"
REGION="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region --max-time 3)"

# Signal instance is ready for deployment
echo "Instance ready for deployment. BookingId={booking_id} Plan={deployment_plan}" \
    > /var/log/tpot-bench/ready.log
"""


def _launch_instance(
    ec2_client,
    instance_type: str,
    ami: str,
    az: str,
    subnet: str,
    sg: str,
    booking_id: str,
    deployment_plan: str,
) -> str:
    """Launch a spot instance directly (no probe step).

    Returns the instance ID on success, empty string on failure.
    """
    max_price = MAX_PRICES.get(instance_type, "60")
    name_tag = f"tpot-booking-{instance_type.replace('.', '-')}"
    run_id = _generate_run_id()
    userdata = _render_userdata(booking_id, deployment_plan)

    try:
        resp = ec2_client.run_instances(
            ImageId=ami,
            InstanceType=instance_type,
            MinCount=1,
            MaxCount=1,
            SubnetId=subnet,
            SecurityGroupIds=[sg],
            IamInstanceProfile={"Name": INSTANCE_PROFILE},
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
                        {"Key": "BookingId", "Value": booking_id},
                        {"Key": "DeploymentPlan", "Value": deployment_plan},
                        {"Key": "RunId", "Value": run_id},
                    ],
                },
                {
                    "ResourceType": "volume",
                    "Tags": [
                        {"Key": "Project", "Value": PROJECT_TAG},
                        {"Key": "Name", "Value": name_tag},
                        {"Key": "BookingId", "Value": booking_id},
                    ],
                },
            ],
            UserData=userdata,
        )
        instance_id = resp["Instances"][0]["InstanceId"]
        logger.info(
            "LAUNCHED: %s @ %s -> %s (booking=%s)",
            instance_type,
            az,
            instance_id,
            booking_id,
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
            logger.info("No capacity for %s @ %s: %s", instance_type, az, error_code)
        else:
            logger.warning(
                "Launch error for %s @ %s: %s - %s",
                instance_type,
                az,
                error_code,
                e.response["Error"].get("Message", ""),
            )
        return ""


def _send_notification(title: str, message: str, booking: dict) -> None:
    """Send notification via Feishu webhook (and SNS as fallback)."""
    from notifications import send_notification

    send_notification(
        title=title,
        message=message,
        event_type="capacity_found",
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


# ─── Lambda Handler ─────────────────────────────────────────────────────────


def handler(event, context):
    """Main entry point. Polls for bookings in 'polling' state and tries to launch."""
    logger.info("Capacity poller invoked. Event: %s", json.dumps(event, default=str))

    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(BOOKING_TABLE)

    # Query bookings with status=polling
    try:
        resp = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr("status").eq("polling")
        )
        pending_bookings = resp.get("Items", [])
    except ClientError as e:
        logger.error("Failed to query pending bookings: %s", e)
        return {"statusCode": 500, "body": "Failed to query bookings"}

    if not pending_bookings:
        logger.info("No bookings in polling state")
        return {"statusCode": 200, "body": json.dumps({"message": "No pending bookings"})}

    logger.info("Found %d booking(s) in polling state", len(pending_bookings))
    results = []

    for booking in pending_bookings:
        booking_id = booking["bookingId"]
        instance_type = booking["instanceType"]
        deployment_plan = booking["deploymentPlan"]

        logger.info(
            "Processing booking %s: %s / %s",
            booking_id,
            instance_type,
            deployment_plan,
        )

        # Get AZs to try for this instance type
        az_map = INSTANCE_AZS.get(instance_type, {})
        launched = False

        for region in REGIONS:
            azs = az_map.get(region, [])
            if not azs:
                continue

            ec2_client = boto3.client("ec2", region_name=region)
            ssm_client = boto3.client("ssm", region_name=region)

            # Resolve AMI
            ami = _get_ami(ssm_client)
            if not ami:
                logger.warning("Cannot resolve AMI in %s, skipping", region)
                continue

            # Resolve security group
            sg = _get_security_group(ec2_client)
            if not sg:
                logger.warning("Cannot resolve SG in %s, skipping", region)
                continue

            for az in azs:
                subnet = SUBNET_MAP.get(az)
                if not subnet:
                    continue

                instance_id = _launch_instance(
                    ec2_client,
                    instance_type,
                    ami,
                    az,
                    subnet,
                    sg,
                    booking_id,
                    deployment_plan,
                )

                if instance_id:
                    # Update booking status to launching with condition
                    # to prevent duplicate launches from concurrent invocations
                    now = datetime.now(timezone.utc).isoformat()
                    try:
                        table.update_item(
                            Key={"bookingId": booking_id},
                            UpdateExpression=(
                                "SET #s = :s, instanceId = :i, "
                                "#r = :r, az = :az, updatedAt = :u"
                            ),
                            ConditionExpression="#s = :expected_status",
                            ExpressionAttributeNames={
                                "#s": "status",
                                "#r": "region",
                            },
                            ExpressionAttributeValues={
                                ":s": "launching",
                                ":i": instance_id,
                                ":r": region,
                                ":az": az,
                                ":u": now,
                                ":expected_status": "polling",
                            },
                        )
                    except ClientError as e:
                        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                            # Another invocation already claimed this booking;
                            # terminate the instance we just launched
                            logger.warning(
                                "Booking %s already claimed, terminating duplicate instance %s",
                                booking_id,
                                instance_id,
                            )
                            ec2_client.terminate_instances(InstanceIds=[instance_id])
                            break
                        raise

                    _send_notification(
                        f"Capacity found: {instance_type} @ {az}",
                        f"Instance {instance_id} launched for booking {booking_id}",
                        booking,
                    )

                    results.append({
                        "bookingId": booking_id,
                        "instanceId": instance_id,
                        "region": region,
                        "az": az,
                    })
                    launched = True
                    break

            if launched:
                break

        if not launched:
            logger.info(
                "No capacity found for booking %s (%s)", booking_id, instance_type
            )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": f"Processed {len(pending_bookings)} booking(s), launched {len(results)}",
            "launched": results,
        }),
    }
