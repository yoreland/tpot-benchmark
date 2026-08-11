"""
T-POT Booking Platform - API Gateway Lambda Handler.

Routes:
  POST   /bookings             - Create a new booking
  GET    /bookings             - List bookings (optional status filter)
  GET    /bookings/{bookingId} - Get booking details
  DELETE /bookings/{bookingId} - Cancel/terminate booking
  PUT    /bookings/{bookingId} - Update booking (whitelist IPs)
  GET    /notifications        - Get notification config
  PUT    /notifications        - Update notification config
  POST   /notifications        - Same as PUT (for convenience)
  GET    /status               - System status overview
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

# Add lambda directory to path for local imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import boto3
from botocore.exceptions import ClientError

from models import Booking, BookingStatus, NotificationConfig
from deployment_plans import get_all_plans, get_plan
from ec2_manager import (
    check_running_instances,
    terminate_instance,
    update_security_group,
    get_instance_endpoint,
    list_all_instances,
)
from notifications import send_notification

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BOOKING_TABLE = os.environ.get("BOOKING_TABLE", "TpotBookingTable")
NOTIFICATION_CONFIG_TABLE = os.environ.get(
    "NOTIFICATION_CONFIG_TABLE", "TpotNotificationConfigTable"
)
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")

dynamodb = boto3.resource("dynamodb")


def _response(status_code: int, body: dict) -> dict:
    """Build API Gateway proxy response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
        },
        "body": json.dumps(body, default=str),
    }


def _get_booking_table():
    return dynamodb.Table(BOOKING_TABLE)


def _get_notification_table():
    return dynamodb.Table(NOTIFICATION_CONFIG_TABLE)


# ─── Booking Handlers ───────────────────────────────────────────────────────


def create_booking(body: dict) -> dict:
    """Create a new booking request.

    Validates the deployment plan, checks for conflicts, and creates
    the booking in DynamoDB with status=polling.
    """
    deployment_plan_id = body.get("deploymentPlan", "")
    confirm_override = body.get("confirmOverride", False)

    # Validate deployment plan
    plan = get_plan(deployment_plan_id)
    if not plan:
        return _response(400, {
            "error": "Invalid deployment plan",
            "availablePlans": [p["id"] for p in get_all_plans()],
        })

    instance_type = plan.instanceType

    # Check for conflicts (same instance type with active booking)
    table = _get_booking_table()
    try:
        conflict_resp = table.query(
            IndexName="instanceType-status-index",
            KeyConditionExpression=(
                boto3.dynamodb.conditions.Key("instanceType").eq(instance_type)
            ),
            FilterExpression=boto3.dynamodb.conditions.Attr("status").is_in(
                [
                    BookingStatus.POLLING.value,
                    BookingStatus.LAUNCHING.value,
                    BookingStatus.DEPLOYING.value,
                    BookingStatus.READY.value,
                ]
            ),
        )
        conflicting = conflict_resp.get("Items", [])
    except ClientError as e:
        logger.error("Error querying conflicts: %s", e)
        conflicting = []

    if conflicting and not confirm_override:
        # Return 409 with conflict details
        return _response(409, {
            "error": "Conflicting booking exists for this instance type",
            "conflicting": conflicting,
            "message": (
                "An active booking exists for the same instance type. "
                "Set confirmOverride=true to terminate the existing instance "
                "and proceed with the new deployment plan."
            ),
        })

    # If override confirmed, terminate conflicting instances
    if conflicting and confirm_override:
        for conflict in conflicting:
            conflict_id = conflict.get("instanceId", "")
            conflict_region = conflict.get("region", "")
            conflict_booking_id = conflict.get("bookingId", "")

            if conflict_id and conflict_region:
                terminate_instance(conflict_id, conflict_region)

            # Update old booking status to terminated
            if conflict_booking_id:
                table.update_item(
                    Key={"bookingId": conflict_booking_id},
                    UpdateExpression="SET #s = :s, updatedAt = :u",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={
                        ":s": BookingStatus.TERMINATED.value,
                        ":u": datetime.now(timezone.utc).isoformat(),
                    },
                )

    # Create new booking
    booking = Booking(
        instanceType=instance_type,
        deploymentPlan=deployment_plan_id,
        status=BookingStatus.POLLING.value,
        whitelistIps=body.get("whitelistIps", []),
    )

    table.put_item(Item=booking.to_dict())

    # Send notification
    send_notification(
        title=f"New booking created: {deployment_plan_id}",
        message=f"Booking {booking.bookingId} created. Polling for {instance_type} capacity.",
        event_type="booking_created",
        booking_data=booking.to_dict(),
    )

    return _response(201, booking.to_dict())


def list_bookings(params: dict) -> dict:
    """List all bookings, optionally filtered by status."""
    table = _get_booking_table()
    status_filter = params.get("status", "")

    try:
        if status_filter:
            # Scan with filter (acceptable for small table)
            resp = table.scan(
                FilterExpression=boto3.dynamodb.conditions.Attr("status").eq(
                    status_filter
                )
            )
        else:
            resp = table.scan()

        items = resp.get("Items", [])
        # Sort by createdAt descending
        items.sort(key=lambda x: x.get("createdAt", ""), reverse=True)
        return _response(200, {"bookings": items, "count": len(items)})
    except ClientError as e:
        logger.error("Error listing bookings: %s", e)
        return _response(500, {"error": "Failed to list bookings"})


def get_booking(booking_id: str) -> dict:
    """Get a single booking by ID."""
    table = _get_booking_table()
    try:
        resp = table.get_item(Key={"bookingId": booking_id})
        item = resp.get("Item")
        if not item:
            return _response(404, {"error": "Booking not found"})
        return _response(200, item)
    except ClientError as e:
        logger.error("Error getting booking %s: %s", booking_id, e)
        return _response(500, {"error": "Failed to get booking"})


def update_booking(booking_id: str, body: dict) -> dict:
    """Update a booking (primarily for IP whitelist updates)."""
    table = _get_booking_table()

    # Get current booking
    try:
        resp = table.get_item(Key={"bookingId": booking_id})
        item = resp.get("Item")
        if not item:
            return _response(404, {"error": "Booking not found"})
    except ClientError as e:
        logger.error("Error getting booking %s: %s", booking_id, e)
        return _response(500, {"error": "Failed to get booking"})

    # Update whitelist IPs
    whitelist_ips = body.get("whitelistIps")
    if whitelist_ips is not None:
        now = datetime.now(timezone.utc).isoformat()
        table.update_item(
            Key={"bookingId": booking_id},
            UpdateExpression="SET whitelistIps = :w, updatedAt = :u",
            ExpressionAttributeValues={
                ":w": whitelist_ips,
                ":u": now,
            },
        )

        # If instance is running, update the security group
        instance_id = item.get("instanceId", "")
        region = item.get("region", "")
        if instance_id and region and item.get("status") == BookingStatus.READY.value:
            update_security_group(instance_id, region, whitelist_ips)

        item["whitelistIps"] = whitelist_ips
        item["updatedAt"] = now

    return _response(200, item)


def delete_booking(booking_id: str) -> dict:
    """Cancel or terminate a booking."""
    table = _get_booking_table()

    try:
        resp = table.get_item(Key={"bookingId": booking_id})
        item = resp.get("Item")
        if not item:
            return _response(404, {"error": "Booking not found"})
    except ClientError as e:
        logger.error("Error getting booking %s: %s", booking_id, e)
        return _response(500, {"error": "Failed to get booking"})

    # Terminate the instance if running
    instance_id = item.get("instanceId", "")
    region = item.get("region", "")
    if instance_id and region:
        terminate_instance(instance_id, region)

    # Update status
    now = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"bookingId": booking_id},
        UpdateExpression="SET #s = :s, updatedAt = :u",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": BookingStatus.TERMINATED.value,
            ":u": now,
        },
    )

    send_notification(
        title=f"Booking terminated: {booking_id}",
        message=f"Booking {booking_id} has been terminated.",
        event_type="booking_terminated",
        booking_data=item,
    )

    return _response(200, {"message": "Booking terminated", "bookingId": booking_id})


# ─── Notification Handlers ──────────────────────────────────────────────────


def get_notification_config() -> dict:
    """Get the current notification configuration."""
    table = _get_notification_table()
    try:
        resp = table.get_item(Key={"configId": "global"})
        item = resp.get("Item", NotificationConfig().to_dict())
        return _response(200, item)
    except ClientError as e:
        logger.error("Error getting notification config: %s", e)
        return _response(500, {"error": "Failed to get notification config"})


def update_notification_config(body: dict) -> dict:
    """Update notification configuration (email, Feishu webhook)."""
    table = _get_notification_table()

    config = NotificationConfig(
        email=body.get("email", ""),
        feishuWebhook=body.get("feishuWebhook", ""),
        enabled=body.get("enabled", True),
    )

    try:
        table.put_item(Item=config.to_dict())
        return _response(200, config.to_dict())
    except ClientError as e:
        logger.error("Error updating notification config: %s", e)
        return _response(500, {"error": "Failed to update notification config"})


# ─── Status Handler ─────────────────────────────────────────────────────────


def get_status() -> dict:
    """Get system status overview including running instances and active bookings."""
    table = _get_booking_table()

    try:
        # Get active bookings count
        resp = table.scan(
            FilterExpression=boto3.dynamodb.conditions.Attr("status").is_in(
                [
                    BookingStatus.POLLING.value,
                    BookingStatus.LAUNCHING.value,
                    BookingStatus.DEPLOYING.value,
                    BookingStatus.READY.value,
                ]
            )
        )
        active_bookings = resp.get("Items", [])
    except ClientError:
        active_bookings = []

    # Get deployment plans
    plans = get_all_plans()

    return _response(200, {
        "activeBookings": len(active_bookings),
        "bookings": active_bookings,
        "deploymentPlans": plans,
        "regions": ["us-east-1", "us-east-2", "us-west-2"],
    })


# ─── Router ─────────────────────────────────────────────────────────────────


def handler(event, context):
    """Main Lambda entry point - routes API Gateway requests."""
    logger.info("Event: %s", json.dumps(event, default=str))

    http_method = event.get("httpMethod", "GET")
    resource = event.get("resource", "")
    path = event.get("path", "")
    path_params = event.get("pathParameters") or {}
    query_params = event.get("queryStringParameters") or {}
    body = {}

    if event.get("body"):
        try:
            body = json.loads(event["body"])
        except (json.JSONDecodeError, TypeError):
            return _response(400, {"error": "Invalid JSON body"})

    # Route requests
    try:
        # /bookings
        if resource == "/bookings" and http_method == "POST":
            return create_booking(body)
        elif resource == "/bookings" and http_method == "GET":
            return list_bookings(query_params)

        # /bookings/{bookingId}
        elif resource == "/bookings/{bookingId}" and http_method == "GET":
            return get_booking(path_params.get("bookingId", ""))
        elif resource == "/bookings/{bookingId}" and http_method == "PUT":
            return update_booking(path_params.get("bookingId", ""), body)
        elif resource == "/bookings/{bookingId}" and http_method == "DELETE":
            return delete_booking(path_params.get("bookingId", ""))

        # /notifications
        elif resource == "/notifications" and http_method == "GET":
            return get_notification_config()
        elif resource == "/notifications" and http_method in ("PUT", "POST"):
            return update_notification_config(body)

        # /status
        elif resource == "/status" and http_method == "GET":
            return get_status()

        else:
            return _response(404, {
                "error": "Not found",
                "resource": resource,
                "method": http_method,
            })

    except Exception as e:
        logger.exception("Unhandled error: %s", e)
        return _response(500, {"error": "Internal server error"})
