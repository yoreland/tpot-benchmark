"""Tests for the modelName resolution used by the api upload path and the
deployer download-path decision.

``create_deployment_plan`` itself needs boto3/S3/DynamoDB and is not exercised
here (no moto, not worth it). Instead we unit-test the pure decision it
delegates to via a small replica: ``extract_model_from_compose`` result takes
precedence, otherwise the request modelName / DEFAULT_PLAN_MODEL fallback
applies. That replica mirrors the branch in ``create_deployment_plan``.

The deployer download-path decision, by contrast, is the actual bug-fix
surface, so it is exercised against the REAL
``deployer_handler._get_compose_commands`` (with ``_load_compose_content``
monkeypatched to avoid S3). These assert on the generated
``snapshot_download(...)`` model id and ``local_dir=`` path, so they would fail
if the real compose-precedence wiring were reverted.
"""

import pytest

from conftest import deployer_handler, api_handler


def _resolve_upload_model_name(compose_content, body, default):
    """Replica of the api create_deployment_plan modelName decision."""
    derived = api_handler.extract_model_from_compose(compose_content)
    if derived:
        return derived
    return (body.get("modelName") or default).strip() or default


def test_upload_prefers_compose_derived_model():
    compose = "--model /opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark"
    # Even with a (wrong) explicit modelName, the compose-derived value wins.
    body = {"modelName": "someone/wrong-model"}
    assert _resolve_upload_model_name(compose, body, api_handler.DEFAULT_PLAN_MODEL) == (
        "nvidia/DeepSeek-V4-Flash-nvfp4-DSpark"
    )


def test_upload_falls_back_to_body_model_when_no_path():
    compose = "services:\n  slime:\n    image: slime:latest\n"
    body = {"modelName": "custom/Model-X"}
    assert (
        _resolve_upload_model_name(compose, body, api_handler.DEFAULT_PLAN_MODEL)
        == "custom/Model-X"
    )


def test_upload_falls_back_to_default_when_no_path_and_no_body_model():
    compose = "services:\n  slime:\n    image: slime:latest\n"
    body = {}
    assert (
        _resolve_upload_model_name(compose, body, api_handler.DEFAULT_PLAN_MODEL)
        == api_handler.DEFAULT_PLAN_MODEL
    )


def test_default_plan_model_constant_unchanged():
    assert api_handler.DEFAULT_PLAN_MODEL == "deepseek-ai/DeepSeek-V4-Flash"


# ─── deployer download-path priority: compose > model_name arg > default ─────
#
# These exercise the REAL ``deployer_handler._get_compose_commands`` so the
# generated download path is genuinely guarded. The only AWS/S3 touch in that
# function is the module-level ``_load_compose_content(compose_file)``; we
# monkeypatch it to return a chosen compose string so no AWS is required. We
# then join the returned command list and assert on the ``snapshot_download``
# invocation and the ``local_dir=`` it downloads into (the exact bug surface).


def _generated_commands(monkeypatch, compose_content, model_name):
    """Run the real _get_compose_commands with a stubbed compose loader."""
    monkeypatch.setattr(
        deployer_handler, "_load_compose_content", lambda cf: compose_content
    )
    commands = deployer_handler._get_compose_commands(
        "some-plan", "user-x.yaml", model_name=model_name
    )
    return "\n".join(commands)


def test_deployer_compose_wins_over_passed_model_name(monkeypatch):
    # The exact bug scenario: compose pins an nvfp4 slug while the plan record
    # carries a different (wrong) modelName. The compose pin must win so the
    # container reads the directory it actually references.
    compose = "--model-path /opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark"
    generated = _generated_commands(
        monkeypatch, compose, "deepseek-ai/DeepSeek-V4-Flash"
    )
    assert "snapshot_download('nvidia/DeepSeek-V4-Flash-nvfp4-DSpark'" in generated
    assert (
        "local_dir='/opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark'"
        in generated
    )


def test_deployer_uses_passed_model_name_when_no_compose_path(monkeypatch):
    # slime-style compose with no model path -> fall back to passed model_name.
    compose = "services:\n  slime:\n    image: slime:latest\n"
    generated = _generated_commands(monkeypatch, compose, "custom/Model-Y")
    assert "snapshot_download('custom/Model-Y'" in generated
    assert "local_dir='/opt/dlami/nvme/models/custom__Model-Y'" in generated


def test_deployer_uses_default_when_no_compose_path_and_no_model_name(monkeypatch):
    # No compose path and empty model_name -> fall back to DEFAULT_MODEL_NAME.
    compose = "services:\n  slime:\n    image: slime:latest\n"
    generated = _generated_commands(monkeypatch, compose, "")
    assert (
        "snapshot_download('deepseek-ai/DeepSeek-V4-Flash'" in generated
    )
    assert (
        "local_dir='/opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash'"
        in generated
    )
    # Sanity-check the fallback matches the module default rather than a literal.
    assert deployer_handler.DEFAULT_MODEL_NAME == "deepseek-ai/DeepSeek-V4-Flash"
