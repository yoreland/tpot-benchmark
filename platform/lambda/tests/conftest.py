"""Shared pytest fixtures for the platform Lambda unit tests.

The api and deployer Lambdas are packaged as separate asset directories with
no shared import path (each does ``sys.path.insert`` for its own dir and imports
sibling modules by bare name). To unit-test the duplicated
``extract_model_from_compose`` helper in each package without their module names
(both are ``handler``) colliding in ``sys.modules``, we load each handler file
under a distinct module name via importlib, with its package directory placed on
``sys.path`` first so its sibling imports resolve.
"""

import importlib.util
import os
import sys

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_LAMBDA_DIR = os.path.dirname(_TESTS_DIR)
_DEPLOYER_DIR = os.path.join(_LAMBDA_DIR, "deployer")
_API_DIR = os.path.join(_LAMBDA_DIR, "api")


def _load_handler(module_name: str, package_dir: str):
    """Import a handler.py from ``package_dir`` under a unique module name."""
    # Ensure the package dir is importable so sibling bare-name imports (e.g.
    # ``models``, ``notifications``) resolve when the module is executed.
    if package_dir not in sys.path:
        sys.path.insert(0, package_dir)
    handler_path = os.path.join(package_dir, "handler.py")
    spec = importlib.util.spec_from_file_location(module_name, handler_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


# Load both copies once at collection time.
deployer_handler = _load_handler("deployer_handler", _DEPLOYER_DIR)
api_handler = _load_handler("api_handler", _API_DIR)
