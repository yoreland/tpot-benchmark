"""
EC2 instance management utilities for the booking platform.

Handles:
  - Querying running instances by type and project tag
  - Terminating instances
  - Managing per-instance security groups for IP whitelisting
  - Getting instance endpoint information
"""

import logging
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PROJECT_TAG = "tpot-benchmark"
SGLANG_PORT = 30080


def _get_ec2_client(region: str = None):
    """Create EC2 client for the given region."""
    if region:
        return boto3.client("ec2", region_name=region)
    return boto3.client("ec2")


def check_running_instances(instance_type: str, regions: list = None) -> list:
    """Query EC2 for running instances of the same type with Project tag.

    Args:
        instance_type: EC2 instance type to filter on.
        regions: List of regions to check. Defaults to standard regions.

    Returns:
        List of instance info dicts with id, type, state, region, az, publicIp.
    """
    if regions is None:
        regions = ["us-east-1", "us-east-2", "us-west-2"]

    instances = []
    for region in regions:
        ec2 = _get_ec2_client(region)
        try:
            resp = ec2.describe_instances(
                Filters=[
                    {"Name": "tag:Project", "Values": [PROJECT_TAG]},
                    {"Name": "instance-type", "Values": [instance_type]},
                    {
                        "Name": "instance-state-name",
                        "Values": ["pending", "running"],
                    },
                ]
            )
            for reservation in resp.get("Reservations", []):
                for inst in reservation.get("Instances", []):
                    name_tag = ""
                    for tag in inst.get("Tags", []):
                        if tag["Key"] == "Name":
                            name_tag = tag["Value"]
                            break
                    instances.append(
                        {
                            "instanceId": inst["InstanceId"],
                            "instanceType": inst["InstanceType"],
                            "state": inst["State"]["Name"],
                            "region": region,
                            "az": inst.get("Placement", {}).get(
                                "AvailabilityZone", ""
                            ),
                            "publicIp": inst.get("PublicIpAddress", ""),
                            "name": name_tag,
                            "launchTime": inst.get("LaunchTime", "").isoformat()
                            if inst.get("LaunchTime")
                            else "",
                        }
                    )
        except ClientError as e:
            logger.error(
                "Error describing instances in %s: %s", region, e
            )

    return instances


def terminate_instance(instance_id: str, region: str) -> bool:
    """Terminate an EC2 instance.

    Args:
        instance_id: The instance ID to terminate.
        region: The AWS region where the instance is running.

    Returns:
        True if termination was initiated successfully, False otherwise.
    """
    ec2 = _get_ec2_client(region)
    try:
        ec2.terminate_instances(InstanceIds=[instance_id])
        logger.info("Initiated termination of instance: %s", instance_id)
        return True
    except ClientError as e:
        logger.error("Failed to terminate instance %s: %s", instance_id, e)
        return False


def update_security_group(
    instance_id: str, region: str, whitelist_ips: list
) -> bool:
    """Create or update a per-instance security group for IP whitelisting.

    Creates a security group named 'tpot-booking-<instance_id>' with ingress
    rules for port 30080 from each whitelisted IP.

    Args:
        instance_id: The EC2 instance ID.
        region: The AWS region.
        whitelist_ips: List of IPs (CIDR format, e.g., '1.2.3.4/32').

    Returns:
        True if the security group was successfully updated, False otherwise.
    """
    ec2 = _get_ec2_client(region)
    sg_name = f"tpot-booking-{instance_id}"

    try:
        # Get instance VPC
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        if not resp["Reservations"] or not resp["Reservations"][0]["Instances"]:
            logger.error("Instance %s not found", instance_id)
            return False

        instance = resp["Reservations"][0]["Instances"][0]
        vpc_id = instance.get("VpcId", "")
        if not vpc_id:
            logger.error("Instance %s has no VPC", instance_id)
            return False

        # Find or create the security group
        sg_id = None
        try:
            sg_resp = ec2.describe_security_groups(
                Filters=[
                    {"Name": "group-name", "Values": [sg_name]},
                    {"Name": "vpc-id", "Values": [vpc_id]},
                ]
            )
            if sg_resp["SecurityGroups"]:
                sg_id = sg_resp["SecurityGroups"][0]["GroupId"]
        except ClientError:
            pass

        if not sg_id:
            # Create new security group
            create_resp = ec2.create_security_group(
                GroupName=sg_name,
                Description=f"IP whitelist for T-POT booking instance {instance_id}",
                VpcId=vpc_id,
                TagSpecifications=[
                    {
                        "ResourceType": "security-group",
                        "Tags": [
                            {"Key": "Project", "Value": PROJECT_TAG},
                            {"Key": "ManagedBy", "Value": "tpot-booking"},
                            {"Key": "InstanceId", "Value": instance_id},
                        ],
                    }
                ],
            )
            sg_id = create_resp["GroupId"]
            logger.info("Created security group %s (%s)", sg_name, sg_id)
        else:
            # Revoke all existing ingress rules
            sg_detail = ec2.describe_security_groups(GroupIds=[sg_id])
            existing_rules = sg_detail["SecurityGroups"][0].get(
                "IpPermissions", []
            )
            if existing_rules:
                ec2.revoke_security_group_ingress(
                    GroupId=sg_id, IpPermissions=existing_rules
                )
                logger.info("Revoked existing ingress rules for %s", sg_id)

        # Add ingress rules for each whitelisted IP
        if whitelist_ips:
            ip_permissions = [
                {
                    "IpProtocol": "tcp",
                    "FromPort": SGLANG_PORT,
                    "ToPort": SGLANG_PORT,
                    "IpRanges": [
                        {
                            "CidrIp": ip if "/" in ip else f"{ip}/32",
                            "Description": "T-POT booking whitelist",
                        }
                        for ip in whitelist_ips
                    ],
                }
            ]
            ec2.authorize_security_group_ingress(
                GroupId=sg_id, IpPermissions=ip_permissions
            )
            logger.info(
                "Added %d IP(s) to security group %s",
                len(whitelist_ips),
                sg_id,
            )

        # Attach the security group to the instance if not already attached
        current_sgs = [
            sg["GroupId"] for sg in instance.get("SecurityGroups", [])
        ]
        if sg_id not in current_sgs:
            current_sgs.append(sg_id)
            ec2.modify_instance_attribute(
                InstanceId=instance_id, Groups=current_sgs
            )
            logger.info(
                "Attached security group %s to instance %s", sg_id, instance_id
            )

        return True
    except ClientError as e:
        logger.error(
            "Failed to update security group for %s: %s", instance_id, e
        )
        return False


def get_instance_endpoint(instance_id: str, region: str) -> str:
    """Get the OpenAI-compatible endpoint for an instance.

    Args:
        instance_id: The EC2 instance ID.
        region: The AWS region.

    Returns:
        The endpoint URL (http://<public_ip>:30080/v1) or empty string.
    """
    ec2 = _get_ec2_client(region)
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        if resp["Reservations"] and resp["Reservations"][0]["Instances"]:
            instance = resp["Reservations"][0]["Instances"][0]
            public_ip = instance.get("PublicIpAddress", "")
            if public_ip:
                return f"http://{public_ip}:{SGLANG_PORT}/v1"
    except ClientError as e:
        logger.error(
            "Failed to get endpoint for %s: %s", instance_id, e
        )
    return ""


def list_all_instances(regions: list = None) -> list:
    """List all running T-POT project instances across regions.

    Args:
        regions: List of regions to check.

    Returns:
        List of instance info dicts.
    """
    if regions is None:
        regions = ["us-east-1", "us-east-2", "us-west-2"]

    instances = []
    for region in regions:
        ec2 = _get_ec2_client(region)
        try:
            resp = ec2.describe_instances(
                Filters=[
                    {"Name": "tag:Project", "Values": [PROJECT_TAG]},
                    {
                        "Name": "instance-state-name",
                        "Values": ["pending", "running", "stopping", "stopped"],
                    },
                ]
            )
            for reservation in resp.get("Reservations", []):
                for inst in reservation.get("Instances", []):
                    name_tag = ""
                    booking_id = ""
                    for tag in inst.get("Tags", []):
                        if tag["Key"] == "Name":
                            name_tag = tag["Value"]
                        elif tag["Key"] == "BookingId":
                            booking_id = tag["Value"]
                    instances.append(
                        {
                            "instanceId": inst["InstanceId"],
                            "instanceType": inst["InstanceType"],
                            "state": inst["State"]["Name"],
                            "region": region,
                            "az": inst.get("Placement", {}).get(
                                "AvailabilityZone", ""
                            ),
                            "publicIp": inst.get("PublicIpAddress", ""),
                            "name": name_tag,
                            "bookingId": booking_id,
                            "launchTime": inst.get("LaunchTime", "").isoformat()
                            if inst.get("LaunchTime")
                            else "",
                        }
                    )
        except ClientError as e:
            logger.error(
                "Error listing instances in %s: %s", region, e
            )

    return instances
