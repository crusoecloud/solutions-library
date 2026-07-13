#!/usr/bin/env python3
"""Launch run.py in JupyterLab.

Regenerates run.ipynb from run.py via jupytext, opens it in JupyterLab, and
removes run.ipynb on exit (even on Ctrl-C).

Dependencies are split across two files:
  - requirements.txt         — runtime deps used by run.py
  - requirements-jupyter.txt — dev-only deps used by this script / runtime.py

The script checks for missing dependencies and offers to install them
automatically. To install manually, run:
  python3 -m pip install -r requirements.txt -r requirements-jupyter.txt

This script launches an INTERACTIVE session — it does NOT headless-execute
the notebook. runtime.py uses Jupyter's input() box / numbered menus, which
require a live frontend to answer; headless execution
(jupyter nbconvert --execute, jupyter run) would hang forever with no user
to type. Open the notebook, answer each prompt, close JupyterLab when done.
"""
from __future__ import annotations

import atexit
import importlib
import importlib.util
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)

RUNTIME_REQS = "requirements.txt"
JUPYTER_REQS = "requirements-jupyter.txt"

# (import name, pip name) — kept in sync with requirements*.txt.
RUNTIME_MODULES = [
    ("openai", "openai"),
    ("httpx", "httpx"),
    ("questionary", "questionary"),
    ("dotenv", "python-dotenv"),
]
JUPYTER_MODULES = [
    ("jupytext", "jupytext"),
    ("jupyterlab", "jupyterlab"),
]


def _read_env_file_key(path: Path, key: str) -> str:
    # Minimal .env parser so this launcher does not depend on python-dotenv
    # before the dep check has run.
    if not path.exists():
        return ""
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")
    for line in path.read_text().splitlines():
        m = pattern.match(line)
        if not m:
            continue
        val = m.group(1)
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        return val
    return ""


def _get_api_key() -> str:
    env = os.environ.get("CRUSOE_API_KEY", "")
    if env:
        return env
    return _read_env_file_key(ROOT / ".env", "CRUSOE_API_KEY")


def _check_api_key() -> None:
    key = _get_api_key()
    if not key or key == "your-api-key-here":
        print("error: CRUSOE_API_KEY is not set.", file=sys.stderr)
        print("  export CRUSOE_API_KEY=...  or  cp .env.example .env and fill it in.",
              file=sys.stderr)
        sys.exit(1)


def _missing_modules(modules):
    return [pip_name for import_name, pip_name in modules
            if importlib.util.find_spec(import_name) is None]


def _check_and_install_deps() -> None:
    modules = RUNTIME_MODULES + JUPYTER_MODULES
    missing = _missing_modules(modules)
    if not missing:
        return

    install_cmd = (
        f"python3 -m pip install -r {RUNTIME_REQS} -r {JUPYTER_REQS}"
    )
    print(f"Missing dependencies: {' '.join(missing)}", file=sys.stderr)
    print(f"Install with: {install_cmd}", file=sys.stderr)

    if not sys.stdin.isatty():
        print("Non-interactive shell detected. Please run the command above manually.",
              file=sys.stderr)
        sys.exit(1)

    try:
        reply = input("Install now? [Y/n] ").strip() or "Y"
    except EOFError:
        print(f"Aborting. Install manually with: {install_cmd}", file=sys.stderr)
        sys.exit(1)

    if not re.match(r"^[Yy](es)?$", reply):
        print(f"Aborting. Install manually with: {install_cmd}", file=sys.stderr)
        sys.exit(1)

    subprocess.check_call([sys.executable, "-m", "pip", "install",
                           "-r", RUNTIME_REQS, "-r", JUPYTER_REQS])

    importlib.invalidate_caches()
    still_missing = _missing_modules(modules)
    if still_missing:
        print(f"Install verification failed: {' '.join(still_missing)} still missing.",
              file=sys.stderr)
        sys.exit(1)


def _cleanup_notebook() -> None:
    try:
        (ROOT / "run.ipynb").unlink()
    except FileNotFoundError:
        pass


def main() -> None:
    _check_api_key()
    _check_and_install_deps()

    atexit.register(_cleanup_notebook)

    subprocess.check_call([
        sys.executable, "-m", "jupytext",
        "--to", "ipynb", "--update", "--set-kernel", "python3", "run.py",
    ])

    # Run JupyterLab in its own process group so terminal Ctrl-C is delivered
    # only to us. We then SIGTERM the whole group (Jupyter + kernel children),
    # ignore further Ctrl-C during shutdown, and SIGKILL the group if it does
    # not exit within a short grace period.
    proc = subprocess.Popen(
        [sys.executable, "-m", "jupyterlab", "run.ipynb"],
        start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)

    def _kill_group(sig):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            pass

    def _handle_sigint(signum, frame):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        _kill_group(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _kill_group(signal.SIGKILL)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        sys.exit(0)

    signal.signal(signal.SIGINT, _handle_sigint)
    sys.exit(proc.wait())


if __name__ == "__main__":
    main()
