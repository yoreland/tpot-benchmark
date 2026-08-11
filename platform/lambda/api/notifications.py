"""
Notification dispatch module.

Supports:
  - Email via SNS topic
  - Feishu (Lark) webhook via HTTP POST
"""

import json
import logging
import os
from urllib import request as urllib_request
from urllib.error import URLError

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")
NOTIFICATION_CONFIG_TABLE = os.environ.get("NOTIFICATION_CONFIG_TABLE", "")


def _get_notification_config() -> dict:
    """Load notification config from DynamoDB."""
    if not NOTIFICATION_CONFIG_TABLE:
        return {}
    try:
        dynamodb = boto3.resource("dynamodb")
        table = dynamodb.Table(NOTIFICATION_CONFIG_TABLE)
        resp = table.get_item(Key={"configId": "global"})
        return resp.get("Item", {})
    except ClientError as e:
        logger.error("Failed to load notification config: %s", e)
        return {}


def _send_email(subject: str, message: str) -> bool:
    """Send notification via SNS (email subscribers)."""
    if not NOTIFICATION_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not configured, skipping email notification")
        return False

    try:
        sns = boto3.client("sns")
        sns.publish(
            TopicArn=NOTIFICATION_TOPIC_ARN,
            Subject=subject[:100],
            Message=message,
        )
        logger.info("Published email notification: %s", subject)
        return True
    except ClientError as e:
        logger.error("Failed to publish SNS notification: %s", e)
        return False


def _send_feishu(webhook_url: str, title: str, content: str) -> bool:
    """Send notification to Feishu (Lark) group via webhook.

    Uses interactive message card format for better readability.
    """
    if not webhook_url:
        logger.warning("Feishu webhook URL not configured, skipping")
        return False

    payload = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {
                    "tag": "plain_text",
                    "content": title,
                },
                "template": "blue",
            },
            "elements": [
                {
                    "tag": "markdown",
                    "content": content,
                }
            ],
        },
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib_request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib_request.urlopen(req, timeout=10) as resp:
            resp_body = resp.read().decode("utf-8")
            logger.info("Feishu webhook response: %s", resp_body)
            return True
    except URLError as e:
        logger.error("Failed to send Feishu notification: %s", e)
        return False


def send_notification(
    title: str,
    message: str,
    event_type: str = "info",
    booking_data: dict = None,
) -> dict:
    """Dispatch notification to all configured channels.

    Args:
        title: Short title/subject for the notification.
        message: Full message body.
        event_type: Type of event (capacity_found, deployment_ready, failed, etc.)
        booking_data: Optional booking dict to include in the message.

    Returns:
        Dict with send results per channel.
    """
    results = {"email": False, "feishu": False}

    config = _get_notification_config()
    if not config.get("enabled", True):
        logger.info("Notifications are disabled globally")
        return results

    # Build rich message content
    full_message = message
    if booking_data:
        full_message += "\n\n--- Booking Details ---\n"
        for k, v in booking_data.items():
            if v:
                full_message += f"  {k}: {v}\n"

    # Build Feishu markdown content
    feishu_content = f"**{event_type.upper()}**\n\n{message}"
    if booking_data:
        feishu_content += "\n\n---\n"
        for k, v in booking_data.items():
            if v:
                feishu_content += f"**{k}**: {v}\n"

    # Send email
    results["email"] = _send_email(f"[T-POT] {title}", full_message)

    # Send Feishu
    feishu_webhook = config.get("feishuWebhook", "")
    if feishu_webhook:
        results["feishu"] = _send_feishu(feishu_webhook, title, feishu_content)

    return results
