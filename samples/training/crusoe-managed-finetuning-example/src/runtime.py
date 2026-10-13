"""Dual-mode runtime helper — works in CLI and Jupyter.

In a TTY, questionary renders arrow-key menus and Y/n prompts. In a notebook,
Jupyter's `input()` box, or a piped/non-TTY shell, a zero-dependency fallback
prints numbered menus and reads from `input()`.

All four functions block until the user answers:

    pick(options, prompt="Pick", default=None) -> str
    confirm(prompt, default=True) -> bool
    text(prompt, default="") -> str
    multi_pick(options, prompt="Pick") -> list[str]

Dependencies are soft: questionary is used on a TTY if available. If questionary
is missing or stdin is not a TTY (notebooks, pipes), the `input()` fallback takes
over. No hard dependency beyond the standard library.
"""

from __future__ import annotations

import sys


class WorkflowError(Exception):
    """Raised inside an IPython/Jupyter kernel to stop a notebook cell cleanly.

    In a plain Python process this exception is not used; abort() calls
    sys.exit() directly.
    """


def is_ipython_kernel() -> bool:
    """Return True if this code is running inside an IPython/Jupyter kernel."""
    try:
        shell = get_ipython()  # type: ignore[name-defined]
    except NameError:
        return False
    # Terminal IPython exposes get_ipython() too, but only kernels have a
    # .kernel attribute. This covers JupyterLab, VS Code notebooks, Colab, etc.
    return getattr(shell, "kernel", None) is not None


def abort(message: str, status: int = 1) -> None:
    """Stop the run in an environment-appropriate way.

    - CLI / script: print the message to stderr and call sys.exit(status).
    - Jupyter kernel: raise WorkflowError(message) so the cell stops cleanly
      without IPython's sys.exit() warning.
    """
    if is_ipython_kernel():
        raise WorkflowError(message)
    print(message, file=sys.stderr)
    sys.exit(status)


def _ask(options, prompt, default, multiple=False, kind="pick"):
    """questionary on a TTY, else a zero-dep input() fallback."""
    if not sys.stdin.isatty():
        return _input(options, prompt, default, multiple, kind)

    try:
        import questionary
    except ImportError:
        return _input(options, prompt, default, multiple, kind)

    try:
        if kind == "pick":
            return questionary.select(prompt, choices=options, default=default or options[0]).unsafe_ask()
        if kind == "multi":
            return questionary.checkbox(prompt, choices=options).unsafe_ask()
        if kind == "confirm":
            return bool(questionary.confirm(prompt, default=bool(default)).unsafe_ask())
        if kind == "text":
            return questionary.text(prompt, default=str(default or "")).unsafe_ask()
        raise ValueError(kind)  # pragma: no cover
    except (KeyboardInterrupt, EOFError):
        abort("cancelled by user")
    except WorkflowError:
        raise
    except Exception:
        # Defensive: any other questionary runtime failure (rare) -> input().
        return _input(options, prompt, default, multiple, kind)


def _input(options, prompt, default, multiple, kind):
    """Zero-dependency fallback. Handles piped stdin and Jupyter input boxes."""
    try:
        if kind == "pick":
            for i, opt in enumerate(options, 1):
                print(f"  {i}. {opt}")
            while True:
                raw = input(f"{prompt} [1-{len(options)}]: ").strip()
                try:
                    idx = int(raw)
                    if 1 <= idx <= len(options):
                        return options[idx - 1]
                except ValueError:
                    pass
                print(f"  enter a number 1-{len(options)}")
        if kind == "multi":
            for i, opt in enumerate(options, 1):
                print(f"  {i}. {opt}")
            while True:
                raw = input(f"{prompt} [comma-separated, e.g. 1,3]: ").strip()
                if raw == "":
                    return []  # leave all unset for server defaults
                try:
                    picks = [options[int(x) - 1] for x in raw.split(",") if x.strip()]
                    if picks:
                        return picks
                except (ValueError, IndexError):
                    pass
                print(f"  enter comma-separated numbers from 1-{len(options)}")
        if kind == "confirm":
            d = "Y/n" if default else "y/N"
            while True:
                raw = input(f"{prompt} [{d}]: ").strip().lower()
                if not raw:
                    return bool(default)
                if raw in ("y", "yes"):
                    return True
                if raw in ("n", "no"):
                    return False
        if kind == "text":
            return input(f"{prompt} [{default or ''}]: ").strip() or str(default or "")
        raise ValueError(kind)  # pragma: no cover
    except (KeyboardInterrupt, EOFError):
        abort("cancelled by user")


def pick(options: list[str], prompt: str = "Pick", default: str | None = None) -> str:
    if not options:
        raise ValueError("pick() requires a non-empty options list")
    return _ask(options, prompt, default, kind="pick")


def confirm(prompt: str, default: bool = True) -> bool:
    return _ask(None, prompt, default, kind="confirm")


def text(prompt: str, default: str = "") -> str:
    return _ask(None, prompt, default, kind="text")


def multi_pick(options: list[str], prompt: str = "Pick") -> list[str]:
    if not options:
        raise ValueError("multi_pick() requires a non-empty options list")
    return _ask(options, prompt, None, multiple=True, kind="multi")
