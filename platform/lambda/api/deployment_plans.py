"""
Static registry of available deployment plans.

Maps deployment plan IDs to their configuration including instance type,
docker-compose file, and recipe file.
"""

from models import DeploymentPlan

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
