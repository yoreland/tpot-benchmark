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
import re
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
    delete_security_group,
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
DEPLOYER_FUNCTION_NAME = os.environ.get("DEPLOYER_FUNCTION_NAME", "tpot-booking-deployer")
COMPOSE_BUCKET = os.environ.get("COMPOSE_BUCKET", "")
DEPLOYMENT_PLAN_TABLE = os.environ.get(
    "DEPLOYMENT_PLAN_TABLE", "TpotDeploymentPlanTable"
)

# Instance types allowed for user-uploaded deployment plans. This mirrors the
# instance types used by the built-in plans today; extend as new GPU families
# are supported.
ALLOWED_INSTANCE_TYPES = {
    "p5en.48xlarge",
    "p6-b300.48xlarge",
}

# Default recipe/model reused from the built-in plans for user uploads that do
# not override them.
DEFAULT_PLAN_RECIPE = "recipes/b300-pd-hold.env"
DEFAULT_PLAN_MODEL = "deepseek-ai/DeepSeek-V4-Flash"

# Maximum accepted compose content size (512 KB).
MAX_COMPOSE_BYTES = 512 * 1024

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


def _get_plan_table():
    return dynamodb.Table(DEPLOYMENT_PLAN_TABLE)


def _invoke_deployer(instance_id: str, booking_id: str) -> None:
    """Asynchronously invoke the deployer Lambda to (re)deploy on an instance."""
    try:
        lambda_client = boto3.client("lambda")
        payload = {
            "detail": {
                "instance-id": instance_id,
                "state": "running",
            },
            "booking_id": booking_id,
        }
        lambda_client.invoke(
            FunctionName=DEPLOYER_FUNCTION_NAME,
            InvocationType="Event",
            Payload=json.dumps(payload),
        )
        logger.info(
            "Invoked deployer for instance %s, booking %s",
            instance_id,
            booking_id,
        )
    except ClientError as e:
        logger.error(
            "Failed to invoke deployer for instance %s: %s", instance_id, e
        )


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
        )
        # Filter active statuses in application code since `status` is the
        # sort key of the GSI and cannot appear in FilterExpression.
        active_statuses = {
            BookingStatus.POLLING.value,
            BookingStatus.LAUNCHING.value,
            BookingStatus.DEPLOYING.value,
            BookingStatus.READY.value,
        }
        conflicting = [
            item for item in conflict_resp.get("Items", [])
            if item.get("status") in active_statuses
        ]
    except ClientError as e:
        logger.error("Error querying conflicts: %s", e)
        return _response(500, {
            "error": "Failed to check for conflicts. Please retry.",
            "detail": str(e),
        })

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

    # If override confirmed, handle conflicting instances
    reuse_instance_id = ""
    reuse_region = ""
    reuse_az = ""

    if conflicting and confirm_override:
        for conflict in conflicting:
            conflict_id = conflict.get("instanceId", "")
            conflict_region = conflict.get("region", "")
            conflict_az = conflict.get("az", "")
            conflict_booking_id = conflict.get("bookingId", "")
            conflict_status = conflict.get("status", "")

            # Check if instance can be reused (has a running instance)
            can_reuse = (
                conflict_id
                and conflict_region
                and conflict_status in (BookingStatus.READY.value, BookingStatus.DEPLOYING.value)
            )

            if can_reuse:
                # Reuse the existing instance - do NOT terminate
                reuse_instance_id = conflict_id
                reuse_region = conflict_region
                reuse_az = conflict_az
            elif conflict_id and conflict_region:
                # Instance exists but not in a reusable state - terminate
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

    # Create new booking - reuse instance if available
    if reuse_instance_id:
        booking = Booking(
            instanceType=instance_type,
            deploymentPlan=deployment_plan_id,
            status=BookingStatus.DEPLOYING.value,
            whitelistIps=body.get("whitelistIps", []),
            instanceId=reuse_instance_id,
            region=reuse_region,
            az=reuse_az,
        )
    else:
        booking = Booking(
            instanceType=instance_type,
            deploymentPlan=deployment_plan_id,
            status=BookingStatus.POLLING.value,
            whitelistIps=body.get("whitelistIps", []),
        )

    table.put_item(Item=booking.to_dict())

    # If reusing instance, update EC2 tags to point to new booking
    if reuse_instance_id:
        try:
            ec2 = boto3.client("ec2", region_name=reuse_region)
            ec2.create_tags(
                Resources=[reuse_instance_id],
                Tags=[
                    {"Key": "BookingId", "Value": booking.bookingId},
                    {"Key": "DeploymentPlan", "Value": deployment_plan_id},
                ],
            )
        except ClientError as e:
            logger.warning("Failed to update instance tags: %s", e)

    # If reusing instance, invoke deployer to switch deployment
    if reuse_instance_id:
        _invoke_deployer(reuse_instance_id, booking.bookingId)
        send_notification(
            title=f"Reusing instance for: {deployment_plan_id}",
            message=(
                f"Booking {booking.bookingId} created. "
                f"Reusing existing instance {reuse_instance_id}, switching deployment plan."
            ),
            event_type="booking_created",
            booking_data=booking.to_dict(),
        )
    else:
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
        # Delete the per-instance security group before termination
        delete_security_group(instance_id, region)
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
    """Update notification configuration (Feishu webhook)."""
    table = _get_notification_table()

    config = NotificationConfig(
        feishuWebhook=body.get("feishuWebhook", ""),
        enabled=body.get("enabled", True),
    )

    try:
        table.put_item(Item=config.to_dict())
        return _response(200, config.to_dict())
    except ClientError as e:
        logger.error("Error updating notification config: %s", e)
        return _response(500, {"error": "Failed to update notification config"})


def test_feishu_webhook(body: dict) -> dict:
    """Test a Feishu webhook by sending a test message from the backend.

    This avoids CORS issues that occur when the browser calls Feishu directly.
    """
    import urllib.request
    import urllib.error

    webhook_url = body.get("webhook", "")
    if not webhook_url:
        return _response(400, {"error": "Missing webhook URL"})

    payload = json.dumps({
        "msg_type": "text",
        "content": {
            "text": "[T-POT Booking] Test notification - Webhook configured successfully!",
        },
    }).encode("utf-8")

    try:
        req = urllib.request.Request(
            webhook_url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp_body = resp.read().decode("utf-8")
            return _response(200, {"message": "Test message sent", "response": resp_body})
    except urllib.error.HTTPError as e:
        return _response(502, {"error": f"Webhook returned HTTP {e.code}"})
    except Exception as e:
        return _response(502, {"error": f"Failed to send test message: {str(e)}"})


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


# ─── Deployment Plan Handlers ───────────────────────────────────────────────


def _slugify_plan_id(name: str) -> str:
    """Derive a safe plan id from a name.

    Lowercases, replaces any run of non [a-z0-9] characters with a single
    hyphen, and strips leading/trailing hyphens. Returns '' when nothing
    usable remains.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower())
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug


def _fallback_has_services_mapping(content: str) -> bool:
    """Structural check for a top-level `services:` mapping without PyYAML.

    The AWS Lambda Python runtime does not bundle PyYAML, and the API Lambda is
    packaged as a plain asset with no pip/vendoring step, so this fallback must
    itself be a meaningful check rather than a loose substring match. The
    compose content is later executed on a GPU host via SSM, so we require the
    document to actually declare a top-level `services:` block with at least one
    indented child entry, which is the minimum shape of a real compose file.

    Recognizes a line of the form `services:` (an empty mapping opener followed
    by indented children) or an inline `services: {...}` mapping. Ignores blank
    and comment lines.
    """
    lines = content.splitlines()
    for idx, line in enumerate(lines):
        # A top-level key has no leading whitespace.
        if line != line.lstrip():
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not stripped.startswith("services:"):
            continue

        remainder = stripped[len("services:"):].strip()
        if remainder:
            # Inline form, e.g. `services: {web: {...}}`. Require a non-empty,
            # non-comment value that opens a mapping.
            if remainder.startswith("#"):
                return False
            return remainder.startswith("{") and remainder != "{}"

        # Block form: require at least one indented, non-blank child line before
        # the next top-level key.
        for child in lines[idx + 1:]:
            child_stripped = child.strip()
            if not child_stripped or child_stripped.startswith("#"):
                continue
            if child != child.lstrip():
                return True
            # Reached another top-level key with no children in between.
            return False
        return False
    return False


def _validate_compose_content(content: str) -> bool:
    """Best-effort validation that compose content is a plausible compose file.

    Prefer PyYAML when importable: parse and require a non-empty mapping that
    declares a `services` section. When PyYAML is not available (the default on
    the AWS Lambda runtime, and this Lambda has no pip/vendoring step), fall
    back to a structural check for a top-level `services:` mapping. Both paths
    require an actual services section so validation stays meaningful before the
    content is executed on a host.
    """
    if not content or not content.strip():
        return False
    try:
        import yaml  # type: ignore
    except ImportError:
        return _fallback_has_services_mapping(content)

    try:
        parsed = yaml.safe_load(content)
    except yaml.YAMLError:
        return False
    if not isinstance(parsed, dict) or not parsed:
        return False
    services = parsed.get("services")
    return isinstance(services, dict) and bool(services)


def create_deployment_plan(body: dict) -> dict:
    """Create a user-uploaded deployment plan.

    Stores the compose content in the S3 compose bucket and the plan metadata
    in the deployment-plan table. Returns 201 with the stored plan, 400 on
    validation failure, 409 on id collision without overwrite.
    """
    name = (body.get("name") or "").strip()
    instance_type = (body.get("instanceType") or "").strip()
    compose_content = body.get("composeContent") or ""
    overwrite = bool(body.get("overwrite", False))

    # Validate name
    if not name or len(name) > 100:
        return _response(400, {"error": "name is required (1-100 chars)"})

    # Validate instance type against allowlist
    if instance_type not in ALLOWED_INSTANCE_TYPES:
        return _response(400, {
            "error": "Invalid instanceType",
            "allowedInstanceTypes": sorted(ALLOWED_INSTANCE_TYPES),
        })

    # Validate compose content
    if not isinstance(compose_content, str) or not compose_content.strip():
        return _response(400, {"error": "composeContent is required"})

    if len(compose_content.encode("utf-8")) > MAX_COMPOSE_BYTES:
        return _response(400, {
            "error": "composeContent exceeds 512 KB limit",
        })

    if not _validate_compose_content(compose_content):
        return _response(400, {"error": "composeContent is not valid YAML"})

    # Derive and sanitize the plan id
    plan_id = _slugify_plan_id(name)
    if not plan_id:
        return _response(400, {
            "error": "name must contain alphanumeric characters",
        })

    # Reject collision with a built-in plan id
    builtin_ids = {p["id"] for p in get_all_plans() if p.get("source") == "builtin"}
    if plan_id in builtin_ids:
        return _response(409, {
            "error": "Plan id collides with a built-in plan",
            "planId": plan_id,
        })

    # Reject collision with an existing user plan unless overwrite requested
    table = _get_plan_table()
    if not overwrite:
        try:
            existing = table.get_item(Key={"planId": plan_id}).get("Item")
            if existing:
                return _response(409, {
                    "error": "Plan id already exists; set overwrite=true to replace",
                    "planId": plan_id,
                })
        except ClientError as e:
            logger.error("Error checking existing plan %s: %s", plan_id, e)
            return _response(500, {"error": "Failed to check existing plans"})

    # Sanitize the compose file name (no path separators, no ..)
    compose_file = f"user-{plan_id}.yaml"
    if "/" in compose_file or "\\" in compose_file or ".." in compose_file:
        return _response(400, {"error": "Invalid derived compose file name"})

    # `recipe` is reserved for future use. The deployer resolves user plans by
    # composeFile + modelName only and does not consume recipe today; it is
    # persisted so the record shape matches the built-in plans (which carry a
    # recipe field) and so a future deployer change can wire it in without a
    # data migration.
    recipe = (body.get("recipe") or DEFAULT_PLAN_RECIPE).strip() or DEFAULT_PLAN_RECIPE
    description = (body.get("description") or "").strip()
    model_name = (body.get("modelName") or DEFAULT_PLAN_MODEL).strip() or DEFAULT_PLAN_MODEL

    # Write compose content to S3
    if not COMPOSE_BUCKET:
        return _response(500, {"error": "Compose bucket is not configured"})
    try:
        s3 = boto3.client("s3")
        s3.put_object(
            Bucket=COMPOSE_BUCKET,
            Key=f"compose-files/{compose_file}",
            Body=compose_content.encode("utf-8"),
            ContentType="text/yaml",
        )
    except ClientError as e:
        logger.error("Failed to write compose file %s: %s", compose_file, e)
        return _response(500, {"error": "Failed to store compose file"})

    # Persist plan metadata to the table
    now = datetime.now(timezone.utc).isoformat()
    item = {
        "planId": plan_id,
        "id": plan_id,
        "name": name,
        "instanceType": instance_type,
        "composeFile": compose_file,
        "recipe": recipe,
        "description": description,
        "modelName": model_name,
        "source": "user",
        "createdAt": now,
    }
    try:
        table.put_item(Item=item)
    except ClientError as e:
        logger.error("Failed to persist plan %s: %s", plan_id, e)
        # The compose object was written before the metadata row. On a table
        # write failure, best-effort delete the S3 object so it is not left
        # orphaned with no plan record pointing at it.
        try:
            s3.delete_object(
                Bucket=COMPOSE_BUCKET,
                Key=f"compose-files/{compose_file}",
            )
        except ClientError as cleanup_err:
            logger.warning(
                "Failed to clean up orphaned compose file %s: %s",
                compose_file,
                cleanup_err,
            )
        return _response(500, {"error": "Failed to store deployment plan"})

    return _response(201, item)


def list_deployment_plans() -> dict:
    """List all deployment plans (built-in + user)."""
    return _response(200, {"plans": get_all_plans()})


def delete_deployment_plan(plan_id: str) -> dict:
    """Delete a user deployment plan. Refuses to delete built-in plans."""
    plan_id = (plan_id or "").strip()
    if not plan_id:
        return _response(400, {"error": "planId is required"})

    # Refuse to delete built-in plans
    builtin_ids = {p["id"] for p in get_all_plans() if p.get("source") == "builtin"}
    if plan_id in builtin_ids:
        return _response(400, {"error": "Cannot delete a built-in deployment plan"})

    table = _get_plan_table()
    try:
        item = table.get_item(Key={"planId": plan_id}).get("Item")
    except ClientError as e:
        logger.error("Error getting plan %s: %s", plan_id, e)
        return _response(500, {"error": "Failed to look up deployment plan"})

    if not item:
        return _response(404, {"error": "Deployment plan not found"})

    # Best-effort delete of the S3 compose object
    compose_file = item.get("composeFile", "")
    if compose_file and COMPOSE_BUCKET:
        try:
            s3 = boto3.client("s3")
            s3.delete_object(
                Bucket=COMPOSE_BUCKET,
                Key=f"compose-files/{compose_file}",
            )
        except ClientError as e:
            logger.warning("Failed to delete compose file %s: %s", compose_file, e)

    try:
        table.delete_item(Key={"planId": plan_id})
    except ClientError as e:
        logger.error("Failed to delete plan %s: %s", plan_id, e)
        return _response(500, {"error": "Failed to delete deployment plan"})

    return _response(200, {"message": "Deployment plan deleted", "planId": plan_id})


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
        elif resource == "/notifications/test-webhook" and http_method == "POST":
            return test_feishu_webhook(body)

        # /deployment-plans
        elif resource == "/deployment-plans" and http_method == "POST":
            return create_deployment_plan(body)
        elif resource == "/deployment-plans" and http_method == "GET":
            return list_deployment_plans()

        # /deployment-plans/{planId}
        elif resource == "/deployment-plans/{planId}" and http_method == "DELETE":
            return delete_deployment_plan(path_params.get("planId", ""))

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
