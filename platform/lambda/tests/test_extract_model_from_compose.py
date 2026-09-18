"""Unit tests for the PyYAML-free ``extract_model_from_compose`` helper.

The helper is duplicated (by design) in both the deployer and api Lambda
handlers because they are separate asset packages with no shared import path.
These tests exercise both copies and assert they behave identically so the
duplicated logic cannot drift silently.
"""

import os

import pytest

from conftest import deployer_handler, api_handler

# The two copies of the function under test.
DEPLOYER_FN = deployer_handler.extract_model_from_compose
API_FN = api_handler.extract_model_from_compose

# Run every case against both copies.
BOTH = pytest.mark.parametrize("extract", [DEPLOYER_FN, API_FN], ids=["deployer", "api"])

_COMPOSE_FILES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "deployer",
    "compose-files",
)


def _read_compose(name: str) -> str:
    with open(os.path.join(_COMPOSE_FILES_DIR, name), "r", encoding="utf-8") as fh:
        return fh.read()


# ─── (a) SGLang --model-path form ────────────────────────────────────────────


@BOTH
def test_sglang_model_path_form(extract):
    content = (
        "command: >\n"
        "  python3 -m sglang.launch_server\n"
        "  --model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash\n"
        "  --tp 8\n"
    )
    assert extract(content) == "deepseek-ai/DeepSeek-V4-Flash"


# ─── (b) vLLM --model form ───────────────────────────────────────────────────


@BOTH
def test_vllm_model_form(extract):
    content = (
        "command: >\n"
        "  python3 -m vllm.entrypoints.openai.api_server\n"
        "  --model /opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark\n"
    )
    assert extract(content) == "nvidia/DeepSeek-V4-Flash-nvfp4-DSpark"


# ─── (c) shell MODEL= form ───────────────────────────────────────────────────


@BOTH
def test_shell_model_env_form(extract):
    content = (
        "    environment:\n"
        "      MODEL=/opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark\n"
    )
    assert extract(content) == "nvidia/DeepSeek-V4-Flash-nvfp4-DSpark"


# ─── (d) no model path -> None (fallback case) ───────────────────────────────


@BOTH
def test_no_model_path_returns_none(extract):
    content = (
        "services:\n"
        "  slime:\n"
        "    image: slime:latest\n"
        "    command: python3 train.py --data /opt/data\n"
    )
    assert extract(content) is None


@BOTH
def test_empty_content_returns_none(extract):
    assert extract("") is None
    assert extract(None) is None


# ─── (e) same slug repeated -> single consistent repo id ─────────────────────


@BOTH
def test_repeated_same_slug_resolves_to_one(extract):
    # Real compose file repeats the same path 4x (PD 2p2d).
    content = _read_compose("docker-compose-pd-2p2d.yaml")
    assert content.count("/opt/dlami/nvme/models/") == 4
    assert extract(content) == "deepseek-ai/DeepSeek-V4-Flash"


@BOTH
def test_synthetic_repeat_slug(extract):
    slug = "/opt/dlami/nvme/models/org__name"
    content = "\n".join([f"  --model-path {slug}"] * 4)
    assert extract(content) == "org/name"


# ─── (f) slug -> repo id inversion, only first __ becomes / ──────────────────


@BOTH
def test_only_first_double_underscore_becomes_slash(extract):
    # Name part itself contains '__' and must stay intact.
    content = "--model-path /opt/dlami/nvme/models/org__name__with__extra"
    assert extract(content) == "org/name__with__extra"


# ─── (g) multiple DIFFERENT slugs -> first, no raise ─────────────────────────


@BOTH
def test_multiple_different_slugs_returns_first(extract):
    content = (
        "  --model-path /opt/dlami/nvme/models/alpha__ModelA\n"
        "  --model-path /opt/dlami/nvme/models/beta__ModelB\n"
    )
    # Must not raise and must pick the first encountered slug.
    assert extract(content) == "alpha/ModelA"


# ─── trailing path segments / quotes are stripped ────────────────────────────


@BOTH
def test_trailing_path_segment_stripped(extract):
    content = "--model-path /opt/dlami/nvme/models/org__name/subdir/config.json"
    assert extract(content) == "org/name"


@BOTH
def test_quoted_path(extract):
    content = 'MODEL="/opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark"'
    assert extract(content) == "nvidia/DeepSeek-V4-Flash-nvfp4-DSpark"


# ─── built-in plan compose files parse back to PLAN_MODEL_MAP values ─────────

# The 7 built-in compose files must parse back to exactly the model ids the
# deployer's PLAN_MODEL_MAP already used, proving no behavior change.
BUILTIN_COMPOSE_TO_MODEL = {
    "docker-compose-tp8-h200.yaml": "deepseek-ai/DeepSeek-V4-Flash",
    "docker-compose-tp8-h200-0731.yaml": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "docker-compose-tp8-b300.yaml": "deepseek-ai/DeepSeek-V4-Flash",
    "docker-compose-tp8-b300-0731.yaml": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "docker-compose-tp8-b300-0731-nodspark.yaml": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "docker-compose-pd-2p2d.yaml": "deepseek-ai/DeepSeek-V4-Flash",
    "docker-compose-pd-v4flash-b300.yaml": "deepseek-ai/DeepSeek-V4-Flash",
}


@pytest.mark.parametrize(
    "compose_file,expected_model", sorted(BUILTIN_COMPOSE_TO_MODEL.items())
)
def test_builtin_compose_files_parse_back_to_plan_model_map(compose_file, expected_model):
    content = _read_compose(compose_file)
    assert DEPLOYER_FN(content) == expected_model
    # Both copies must agree.
    assert API_FN(content) == expected_model


def test_builtin_derived_models_match_plan_model_map():
    """Every value the deployer's PLAN_MODEL_MAP produces for a plan whose
    compose file pins a model must equal the compose-derived model id."""
    plan_compose_map = {
        "h200-tp8-eagle": "docker-compose-tp8-h200.yaml",
        "h200-tp8-eagle-0731": "docker-compose-tp8-h200-0731.yaml",
        "b300-tp8-eagle": "docker-compose-tp8-b300.yaml",
        "b300-tp8-eagle-0731": "docker-compose-tp8-b300-0731.yaml",
        "b300-tp8-eagle-0731-nodspark": "docker-compose-tp8-b300-0731-nodspark.yaml",
        "b300-pd-2p2d": "docker-compose-pd-2p2d.yaml",
        "b300-pd-3p1d": "docker-compose-pd-v4flash-b300.yaml",
    }
    for plan_id, compose_file in plan_compose_map.items():
        expected = deployer_handler.PLAN_MODEL_MAP[plan_id]
        derived = DEPLOYER_FN(_read_compose(compose_file))
        assert derived == expected, (
            f"plan {plan_id}: compose-derived {derived!r} != PLAN_MODEL_MAP {expected!r}"
        )


# ─── deployer and api copies stay in lock-step ───────────────────────────────


@pytest.mark.parametrize(
    "content",
    [
        "--model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash",
        "--model /opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark",
        "MODEL=/opt/dlami/nvme/models/org__name__extra",
        "services:\n  x:\n    image: y\n",
        "",
        "  --model-path /opt/dlami/nvme/models/a__A\n  --model-path /opt/dlami/nvme/models/b__B\n",
    ],
)
def test_deployer_and_api_copies_are_identical(content):
    assert DEPLOYER_FN(content) == API_FN(content)
