"""
Static registry of available deployment plans.

Maps deployment plan IDs to their configuration including instance type,
docker-compose file, and recipe file.
"""

from models import DeploymentPlan

DEPLOYMENT_PLANS = {
    "h200-tp4-eagle": DeploymentPlan(
        id="h200-tp4-eagle",
        name="H200 TP4 Eagle",
        instanceType="p5en.48xlarge",
        composeFile="docker-compose-tp4-h200.yaml",
        recipe="recipes/h200-tp4-fp4-eagle.env",
        description="H200 4-way tensor parallel with DeepSeek-V3 (Eagle speculative decoding)",
    ),
    "h200-tp8-eagle": DeploymentPlan(
        id="h200-tp8-eagle",
        name="H200 TP8 Eagle",
        instanceType="p5en.48xlarge",
        composeFile="docker-compose-tp8-h200.yaml",
        recipe="recipes/h200-hold.env",
        description="H200 8-way tensor parallel full precision",
    ),
    "b300-tp8-eagle": DeploymentPlan(
        id="b300-tp8-eagle",
        name="B300 TP8 Eagle",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-tp8-b300.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 8-way tensor parallel with Eagle speculative decoding",
    ),
    "b300-pd-2p2d": DeploymentPlan(
        id="b300-pd-2p2d",
        name="B300 PD 2P2D",
        instanceType="p6-b300.48xlarge",
        composeFile="docker-compose-pd-2p2d.yaml",
        recipe="recipes/b300-pd-hold.env",
        description="B300 disaggregated prefill-decode (2 prefill + 2 decode workers)",
    ),
    "b200-tp8-unified": DeploymentPlan(
        id="b200-tp8-unified",
        name="B200 TP8 Unified",
        instanceType="p6-b200.48xlarge",
        composeFile="docker-compose-tp8-b200.yaml",
        recipe="recipes/b200-tp8-fp4-unified.env",
        description="B200 8-way tensor parallel FP4 unified inference",
    ),
}


def get_all_plans() -> list:
    """Return all deployment plans as dictionaries."""
    return [plan.to_dict() for plan in DEPLOYMENT_PLANS.values()]


def get_plan(plan_id: str):
    """Return a specific deployment plan or None."""
    return DEPLOYMENT_PLANS.get(plan_id)


def get_plans_for_instance_type(instance_type: str) -> list:
    """Return all deployment plans for a given instance type."""
    return [
        plan.to_dict()
        for plan in DEPLOYMENT_PLANS.values()
        if plan.instanceType == instance_type
    ]
