"""
Registry of available deployment plans.

Built-in plans are defined statically below (source='builtin'). User-uploaded
plans are stored in a DynamoDB table (source='user') and merged in at read
time. Built-in plans always win on an id collision.

The table name is read from env DEPLOYMENT_PLAN_TABLE (default
'TpotDeploymentPlanTable'). Missing table / access errors degrade gracefully
so the built-in plans always remain available.
"""

import os

import boto3
from botocore.exceptions import ClientError

from models import DeploymentPlan

DEPLOYMENT_PLAN_TABLE = os.environ.get(
    "DEPLOYMENT_PLAN_TABLE", "TpotDeploymentPlanTable"
)

# User plan records carry these fields; anything else is ignored on load.
_USER_PLAN_FIELDS = (
    "id",
    "name",
    "instanceType",
    "composeFile",
    "recipe",
    "description",
    "modelName",
)

DEPLOYMENT_PLANS = {
    "h200-tp8-eagle": DeploymentPlan(
        id="h200-tp8-eagle",
        name="H200 TP8 Eagle",
        instanceType="p5en.48xlarge",
        composeFile="docker-compose-tp8-h200.yaml",
        recipe="recipes/h200-hold.env",
        description="H200 8-way tensor parallel full precision",
        modelName="deepseek-ai/DeepSeek-V4-Flash",
    ),
    "h200-tp8-eagle-0731": DeploymentPlan(
        id="h200-tp8-eagle-0731",
        name="H200 TP8 Eagle (0731)",
        instanceType="p5en.48xlarge",
        composeFile="docker-compose-tp8-h200-0731.yaml",
        recipe="recipes/h200-hold.env",
        description="H200 TP8 + DSpark speculative decoding with DeepSeek-V4-Flash-0731",
        modelName="deepseek-ai/DeepSeek-V4-Flash-0731",
    ),
    "b300-tp8-eagle": DeploymentPlan(
        id="b300-tp8-eagle",
        name="B300 TP8 Eagle",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-tp8-b300.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 8-way tensor parallel with Eagle speculative decoding",
        modelName="deepseek-ai/DeepSeek-V4-Flash",
    ),
    "b300-tp8-eagle-0731": DeploymentPlan(
        id="b300-tp8-eagle-0731",
        name="B300 TP8 Eagle (0731)",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-tp8-b300-0731.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 TP8 + DSpark speculative decoding with DeepSeek-V4-Flash-0731",
        modelName="deepseek-ai/DeepSeek-V4-Flash-0731",
    ),
    "b300-tp8-eagle-0731-nodspark": DeploymentPlan(
        id="b300-tp8-eagle-0731-nodspark",
        name="B300 TP8 (0731, no DSpark)",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-tp8-b300-0731-nodspark.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 TP8 standard decode (no DSpark) baseline for DeepSeek-V4-Flash-0731",
        modelName="deepseek-ai/DeepSeek-V4-Flash-0731",
    ),
    "b300-pd-2p2d": DeploymentPlan(
        id="b300-pd-2p2d",
        name="B300 PD 2P2D",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-pd-2p2d.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 disaggregated prefill-decode (2 prefill + 2 decode workers)",
        modelName="deepseek-ai/DeepSeek-V4-Flash",
    ),

    "b300-pd-3p1d": DeploymentPlan(
        id="b300-pd-3p1d",
        name="B300 PD 3P1D",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-pd-v4flash-b300.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 PD disaggregation 3 prefill + 1 decode with EAGLE (validated TPOT 3.60ms)",
        modelName="deepseek-ai/DeepSeek-V4-Flash",
    ),

}


def _get_plan_table():
    """Return the DynamoDB table resource for user plans."""
    dynamodb = boto3.resource("dynamodb")
    return dynamodb.Table(DEPLOYMENT_PLAN_TABLE)


def _user_item_to_plan(item: dict) -> DeploymentPlan:
    """Build a DeploymentPlan (source='user') from a DynamoDB item.

    The stored primary key is 'planId'; map it back to the plan 'id'. Missing
    fields fall back to the DeploymentPlan defaults.
    """
    return DeploymentPlan(
        id=item.get("id") or item.get("planId", ""),
        name=item.get("name", ""),
        instanceType=item.get("instanceType", ""),
        composeFile=item.get("composeFile", ""),
        recipe=item.get("recipe", ""),
        description=item.get("description", ""),
        modelName=item.get("modelName", "deepseek-ai/DeepSeek-V4-Flash"),
        source="user",
    )


def _get_user_plans() -> list:
    """Scan the user-plan table and return a list of plan dicts.

    Each returned dict carries source='user'. Tolerates a missing table or
    access errors by returning an empty list so built-in plans still work.
    """
    try:
        table = _get_plan_table()
        resp = table.scan()
        items = resp.get("Items", [])
        while resp.get("LastEvaluatedKey"):
            resp = table.scan(ExclusiveStartKey=resp["LastEvaluatedKey"])
            items.extend(resp.get("Items", []))
        return [_user_item_to_plan(item).to_dict() for item in items]
    except ClientError:
        return []


def get_all_plans() -> list:
    """Return all deployment plans (built-in + user) as dictionaries.

    Built-in plans carry source='builtin' and win on id collision: a user
    plan with the same id as a built-in is skipped.
    """
    plans = [plan.to_dict() for plan in DEPLOYMENT_PLANS.values()]
    builtin_ids = set(DEPLOYMENT_PLANS.keys())
    for user_plan in _get_user_plans():
        if user_plan.get("id") in builtin_ids:
            continue
        plans.append(user_plan)
    return plans


def get_plan(plan_id: str):
    """Return a deployment plan for a built-in or user id, or None.

    Checks built-ins first, then looks up the user plan by planId. The
    returned object exposes .instanceType and .to_dict().
    """
    builtin = DEPLOYMENT_PLANS.get(plan_id)
    if builtin is not None:
        return builtin

    if not plan_id:
        return None

    try:
        table = _get_plan_table()
        resp = table.get_item(Key={"planId": plan_id})
        item = resp.get("Item")
        if not item:
            return None
        return _user_item_to_plan(item)
    except ClientError:
        return None


def get_plans_for_instance_type(instance_type: str) -> list:
    """Return all deployment plans for a given instance type."""
    return [
        plan.to_dict()
        for plan in DEPLOYMENT_PLANS.values()
        if plan.instanceType == instance_type
    ]
