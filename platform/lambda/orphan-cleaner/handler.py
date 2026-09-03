"""
T-POT Booking Platform - Orphan Instance Cleaner Lambda.

Runs every 15 minutes via EventBridge Schedule.
Scans all configured regions for EC2 instances tagged with Project=tpot-benchmark,
checks their associated booking status in DynamoDB, and terminates orphan instances
that no longer have a valid active booking.

Termination criteria:
  - Booking status is 'failed' or 'terminated'
  - Booking does not exist in DynamoDB
  - Instance running > 4 hours with no 'ready' status booking
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── Configuration ──────────────────────────────────────────────────────────

BOOKING_TABLE = os.environ.get("BOOKING_TABLE", "TpotBookingTable")
NOTIFICATION_CONFIG_TABLE = os.environ.get("NOTIFICATION_CONFIG_TABLE", "")
REGIONS = os.environ.get("REGIONS", "us-east-1,us-east-2,us-west-2").split(",")
PROJECT_TAG = "tpot-benchmark"

# Max allowed runtime (in seconds) for an instance without a 'ready' booking
MAX_RUNTIME_WITHOUT_READY = 4 * 3600  # 4 hours


# ─── Helpers ────────────────────────────────────────────────────────────────


def _get_booking(booking_id: str) -> dict:
    """Fetch a booking by ID from DynamoDB."""
    if not booking_id:
        return {}
    try:
        dynamodb = boto3.resource("dynamodb")
        table = dynamodb.Table(BOOKING_TABLE)
        resp = table.get_item(Key={"bookingId": booking_id})
        return resp.get("Item", {})
    except ClientError as e:
        logger.error("Failed to get booking %s: %s", booking_id, e)
        return {}


def _terminate_instance(ec2_client, instance_id: str) -> bool:
    """Terminate an EC2 instance."""
    try:
        ec2_client.terminate_instances(InstanceIds=[instance_id])
        logger.info("Terminated orphan instance %s", instance_id)
        return True
    except ClientError as e:
        logger.error("Failed to terminate instance %s: %s", instance_id, e)
        return False


def _send_notification(title: str, message: str, booking_data: dict = None) -> None:
    """Send notification via Feishu webhook."""
    from notifications import send_notification

    send_notification(
        title=title,
        message=message,
        event_type="orphan_cleanup",
        booking_data=booking_data,
    )


def _get_instance_tags(instance: dict) -> dict:
    """Extract tags from an instance as a dict."""
    tags = {}
    for tag in instance.get("Tags", []):
        tags[tag["Key"]] = tag["Value"]
    return tags


def _get_instance_runtime_seconds(instance: dict) -> float:
    """Calculate how long an instance has been running."""
    launch_time = instance.get("LaunchTime")
    if not launch_time:
        return 0
    now = datetime.now(timezone.utc)
    if hasattr(launch_time, "tzinfo") and launch_time.tzinfo:
        delta = now - launch_time
    else:
        delta = now - launch_time.replace(tzinfo=timezone.utc)
    return delta.total_seconds()


# ─── Main Logic ─────────────────────────────────────────────────────────────


def _scan_and_cleanup_region(region: str) -> list:
    """Scan a single region for orphan instances and terminate them.

    Returns a list of terminated instance summaries.
    """
    terminated = []
    ec2_client = boto3.client("ec2", region_name=region)

    try:
        resp = ec2_client.describe_instances(
            Filters=[
                {"Name": "tag:Project", "Values": [PROJECT_TAG]},
                {"Name": "instance-state-name", "Values": ["running"]},
            ]
        )
    except ClientError as e:
        logger.error("Failed to describe instances in %s: %s", region, e)
        return terminated

    for reservation in resp.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            instance_id = instance["InstanceId"]
            tags = _get_instance_tags(instance)
            booking_id = tags.get("BookingId", "")
            runtime_seconds = _get_instance_runtime_seconds(instance)

            reason = _should_terminate(booking_id, runtime_seconds, instance_id)
            if reason:
                logger.info(
                    "Terminating orphan instance %s in %s (reason: %s, booking: %s)",
                    instance_id,
                    region,
                    reason,
                    booking_id or "none",
                )
                if _terminate_instance(ec2_client, instance_id):
                    terminated.append({
                        "instanceId": instance_id,
                        "region": region,
                        "bookingId": booking_id,
                        "reason": reason,
                        "runtimeHours": round(runtime_seconds / 3600, 2),
                    })
                    _send_notification(
                        "Orphan Instance Cleaned",
                        f"清理了孤儿实例 {instance_id}（原因：{reason}）",
                        booking_data={
                            "instanceId": instance_id,
                            "region": region,
                            "bookingId": booking_id or "N/A",
                            "runtimeHours": round(runtime_seconds / 3600, 2),
                        },
                    )

    return terminated


def _has_active_booking_for_instance(instance_id: str) -> bool:
    """Check if any active booking references this instance (reverse lookup)."""
    if not instance_id:
        return False
    try:
        dynamodb = boto3.resource("dynamodb")
        table = dynamodb.Table(BOOKING_TABLE)
        resp = table.scan(
            FilterExpression=(
                boto3.dynamodb.conditions.Attr("instanceId").eq(instance_id)
                & boto3.dynamodb.conditions.Attr("status").is_in(
                    ["deploying", "launching", "ready", "polling"]
                )
            )
        )
        return len(resp.get("Items", [])) > 0
    except ClientError as e:
        logger.error("Failed reverse lookup for instance %s: %s", instance_id, e)
        return True  # Fail-safe: don't terminate if we can't confirm


def _should_terminate(booking_id: str, runtime_seconds: float, instance_id: str = "") -> str:
    """Determine if an instance should be terminated.

    Returns the reason string if it should be terminated, empty string otherwise.
    """
    # Grace period: never terminate instances running less than 10 minutes
    if runtime_seconds < 600:
        return ""

    if not booking_id:
        # No booking tag at all - if running over 4 hours, terminate
        if runtime_seconds > MAX_RUNTIME_WITHOUT_READY:
            return "no BookingId tag and running over 4 hours"
        return ""

    booking = _get_booking(booking_id)

    if not booking:
        reason = f"关联 booking {booking_id} 不存在"
        if _has_active_booking_for_instance(instance_id):
            logger.info("Instance %s has active booking via reverse lookup, skipping termination", instance_id)
            return ""
        return reason

    status = booking.get("status", "")

    if status == "failed":
        reason = f"关联 booking 已失败"
        if _has_active_booking_for_instance(instance_id):
            logger.info("Instance %s has active booking via reverse lookup, skipping termination", instance_id)
            return ""
        return reason

    if status == "terminated":
        reason = f"关联 booking 已终止"
        if _has_active_booking_for_instance(instance_id):
            logger.info("Instance %s has active booking via reverse lookup, skipping termination", instance_id)
            return ""
        return reason

    if status == "ready":
        # Active booking in ready state - do not terminate
        return ""

    if status == "deploying":
        # Still deploying - do not terminate
        return ""

    if status in ("pending", "launching"):
        # In early stages - check runtime
        if runtime_seconds > MAX_RUNTIME_WITHOUT_READY:
            return f"booking 状态为 {status} 且运行超过 4 小时未就绪"
        return ""

    # Unknown status - if running over 4 hours, terminate
    if runtime_seconds > MAX_RUNTIME_WITHOUT_READY:
        return f"booking 状态为 {status} 且运行超过 4 小时"
    return ""


# ─── Lambda Handler ─────────────────────────────────────────────────────────


def handler(event, context):
    """Main entry point. Scans all regions and terminates orphan instances."""
    logger.info("Orphan cleaner invoked. Regions: %s", REGIONS)

    all_terminated = []

    for region in REGIONS:
        region = region.strip()
        if not region:
            continue
        terminated = _scan_and_cleanup_region(region)
        all_terminated.extend(terminated)

    logger.info(
        "Orphan cleanup complete. Terminated %d instances.", len(all_terminated)
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "terminated_count": len(all_terminated),
            "terminated": all_terminated,
        }),
    }
