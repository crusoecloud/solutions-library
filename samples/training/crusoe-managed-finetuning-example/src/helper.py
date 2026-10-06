"""Formatting, selection, and builder helpers for the fine-tuning flow.

These functions do not make API calls. They take API outputs (or Config) as
input, handle user-facing formatting and selection, and return values that
`run.py` can pass back to the API.
"""

from __future__ import annotations

import time
import zipfile
from collections.abc import Callable
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Any, TYPE_CHECKING

from openai.types import FileObject, Model

from . import constants
from . import runtime    # pick, confirm, text, multi_pick, abort
from . import schema

if TYPE_CHECKING:
    from .config import Config


class FileAction(str, Enum):
    REUSE = "reuse"
    UPLOAD = "upload"
    SKIP = "skip"


def human_size(bytes_val: int) -> str:
    if bytes_val < 1024:
        return f"{bytes_val} B"
    for unit in ("KB", "MB", "GB", "TB"):
        bytes_val /= 1024
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
    return f"{bytes_val:.1f} PB"


def format_file(f) -> str:
    ts = datetime.fromtimestamp(f.created_at).strftime("%Y-%m-%d %H:%M:%S")
    return f"{f.filename}  ({human_size(f.bytes)}, created {ts}, purpose {f.purpose})"


def describe_saved_file(f) -> str:
    return format_file(f)


def get_console_uri(job_id: str) -> str:
    return f"{constants.CONSOLE_BASE_URL}/foundry/fine-tuning/jobs/{job_id}/overview"


def pick_model(config: "Config", models: list[Model]) -> None:
    if not models:
        runtime.abort("error: no models visible to this API key. Register a model first or check permissions.")
    displays = [f"{m.model_name}  (id={m.id})" for m in models]
    print(f"  {len(models)} model(s) visible to this API key:")
    chosen = runtime.pick(displays, "Pick a model to fine-tune")
    for m in models:
        if f"{m.model_name}  (id={m.id})" == chosen:
            print(f"  picked: {m.model_name} (id={m.id})")
            config.model_id = m.id
            config.save()
            return
    runtime.abort(f"error: could not resolve picked model {chosen!r}")


def pick_uploaded_file(files: list[FileObject], label: str) -> str:
    if not files:
        runtime.abort(f"error: no uploaded files with purpose='fine-tune' found for {label}.")
    displays = [format_file(f) for f in files]
    chosen = runtime.pick(displays, f"Pick an uploaded {label} file")
    for f in files:
        if format_file(f) == chosen:
            print(f"  picked uploaded {label} file: {f.id}")
            return f.id
    runtime.abort(f"error: could not resolve picked {label} file {chosen!r}")


def choose_file_action(label: str, default_path: str, allow_skip: bool = False) -> tuple[FileAction, str | None]:
    options = ["Use an already-uploaded file", "Upload a local file"]
    if allow_skip:
        options.append("Skip validation file")
    choice = runtime.pick(options, f"{label} file")

    if choice == "Use an already-uploaded file":
        return FileAction.REUSE, None
    if choice == "Upload a local file":
        path = runtime.text(f"Path to {label.lower()} file", default=default_path)
        return FileAction.UPLOAD, path
    # Only reachable when allow_skip is True.
    print(f"  skipped {label.lower()} file")
    return FileAction.SKIP, None


def _select_file(
    config: "Config",
    label: str,
    kind: str,
    default_path: str,
    allow_skip: bool,
    resolve_fn: Callable[[], tuple[str | None, bool]],
    uploaded_files: list[FileObject],
    upload_file: Callable[[str], str],
    retrieve_file: Callable[[str], FileObject],
    attr: str,
) -> None:
    file_id, resolved = resolve_fn()
    if resolved:
        if file_id:
            try:
                f = retrieve_file(file_id)
            except Exception as e:
                runtime.abort(
                    f"error: saved {kind} file {file_id!r} could not be retrieved: {e}\n"
                    f"  it may have been deleted. To start fresh, remove {config.state_file_path} and re-run."
                )
            print(f"  using saved {kind} file: {describe_saved_file(f)}")
        elif allow_skip:
            print(f"  using saved choice: no {kind} file")
        else:
            print("  skipped (resuming from saved job)")
        return

    action, path = choose_file_action(label, default_path, allow_skip=allow_skip)
    if action == FileAction.REUSE:
        files = uploaded_files
        file_id = pick_uploaded_file(files, kind)
    elif action == FileAction.UPLOAD:
        file_id = upload_file(path or "")
    else:
        file_id = None

    setattr(config, attr, file_id)
    config.save()


def select_training_file(
    config: "Config",
    uploaded_files: list[FileObject],
    upload_file: Callable[[str], str],
    retrieve_file: Callable[[str], FileObject],
) -> None:
    _select_file(
        config,
        label="Training",
        kind="training",
        default_path=config.train_file,
        allow_skip=False,
        resolve_fn=config.resolve_train_id,
        uploaded_files=uploaded_files,
        upload_file=upload_file,
        retrieve_file=retrieve_file,
        attr="train_id",
    )


def select_validation_file(
    config: "Config",
    uploaded_files: list[FileObject],
    upload_file: Callable[[str], str],
    retrieve_file: Callable[[str], FileObject],
) -> None:
    _select_file(
        config,
        label="Validation",
        kind="validation",
        default_path=config.val_file,
        allow_skip=True,
        resolve_fn=config.resolve_val_id,
        uploaded_files=uploaded_files,
        upload_file=upload_file,
        retrieve_file=retrieve_file,
        attr="val_id",
    )


def poll_until_terminated(
    config: "Config",
    job_id: str,
    get_job: Callable[[], Any],
    cancel_job: Callable[[], None] | None = None,
) -> Any:
    """Poll a job until it reaches a terminal state."""
    print(f"  polling {job_id} every {config.poll_interval}s.")
    print(f"  you can exit and resume later; state is saved in {config.state_file_path}")
    print("  press Ctrl-C to pause.")
    last_status = None
    while True:
        try:
            job = get_job()
            status = job.status
            if status != last_status:
                if last_status is not None:
                    print()
                print(f"  {datetime.now().strftime('%H:%M:%S')}  status: {status}", end="")
                last_status = status
            else:
                print(".", end="", flush=True)
            if status in constants.TERMINAL_STATUSES:
                print()
                config.job_status = status
                config.save()
                return job
            time.sleep(config.poll_interval)
        except KeyboardInterrupt:
            if runtime.confirm("Job is still running. Keep it running and exit? (no = cancel job)", default=True):
                config.job_status = last_status or "unknown"
                config.save()
                print(f"  state saved to {config.state_file_path}")
                print("  to resume, run: python3 run.py")
                runtime.abort("state saved; job keeps running", status=0)
            else:
                if cancel_job:
                    try:
                        cancel_job()
                        print(f"  cancelled job {job_id}")
                    except Exception:
                        pass
                config.clear()
                runtime.abort("  job cancelled, state cleared.")


def poll_until_value(
    label: str,
    poll_fn: Callable[[], Any],
    timeout: int = constants.ADAPTER_REGISTRATION_TIMEOUT_SECONDS,
    interval: int = constants.ADAPTER_REGISTRATION_INTERVAL_SECONDS,
) -> Any:
    print(f"  awaiting {label} (up to {timeout}s)...")
    elapsed = 0
    while elapsed < timeout:
        value = poll_fn()
        if value:
            print(f"  {label}: {value}")
            return value
        time.sleep(interval)
        elapsed += interval
    runtime.abort(f"error: {label} not populated within {timeout}s")


def display_default(value) -> str:
    return "auto" if value == "auto" else (str(value) if value is not None else "server default")


def _prompt_for_hyperparam(spec: dict):
    name = spec["name"]
    default = spec["default"]
    kind = spec["kind"]
    choices = spec.get("choices", [])

    if kind == "enum" or kind == "enum_or_null":
        # For nullable enums, prepend a "(server default)" option that means omit the key.
        display_choices = [f"(server default)  current: {display_default(default)}"] + [str(c) for c in choices]
        chosen = runtime.pick(display_choices, f"Set {name}")
        if chosen.startswith("(server default)"):
            return None
        # Convert numeric-looking choice back to int when applicable.
        for c in choices:
            if str(c) == chosen:
                return c
        return chosen

    if kind == "int_or_auto":
        question = f"Set {name} (integer 1-{spec['max']}, or 'auto')"
        raw = runtime.text(question, default=str(default))
        if raw.lower() == "auto":
            return "auto"
        try:
            v = int(raw)
            if spec["min"] <= v <= spec["max"]:
                return v
        except ValueError:
            pass
        runtime.abort(f"error: {name} must be an integer between {spec['min']} and {spec['max']} or 'auto'")

    if kind == "float_or_auto":
        question = f"Set {name} (positive number, or 'auto')"
        raw = runtime.text(question, default=str(default))
        if raw.lower() == "auto":
            return "auto"
        try:
            v = float(raw)
            if v > 0:
                return v
        except ValueError:
            pass
        runtime.abort(f"error: {name} must be a positive number or 'auto'")

    if kind == "int_or_null":
        question = f"Set {name} (integer >= {spec['min']}, or leave blank for server default)"
        raw = runtime.text(question, default="")
        if raw.strip() == "":
            return None
        try:
            v = int(raw)
            if v >= spec["min"]:
                return v
        except ValueError:
            pass
        runtime.abort(f"error: {name} must be an integer >= {spec['min']}")

    if kind == "float_or_null":
        lo = spec.get("min")
        hi = spec.get("max")
        range_str = f"{lo}-{hi}" if hi is not None else f">= {lo}"
        question = f"Set {name} (number {range_str}, or leave blank for server default)"
        raw = runtime.text(question, default="")
        if raw.strip() == "":
            return None
        try:
            v = float(raw)
            if (lo is None or v >= lo) and (hi is None or v <= hi):
                return v
        except ValueError:
            pass
        runtime.abort(f"error: {name} must be a number in {range_str}")

    # Fallback — should never happen.
    runtime.abort(f"error: unknown hyperparameter kind {kind!r}")


def gather_hyperparameter_overrides(config: "Config") -> dict:
    if not config.should_gather_hyperparameter_overrides():
        return config.hyperparameters

    if not runtime.confirm("Override any hyperparameters? (No = use server defaults for all)", default=False):
        config.hyperparameters = {}
        config.save()
        return {}

    hyperparams = schema.load_supervised_hyperparams(config)
    options = [f"{spec['name']}  (default: {display_default(spec['default'])})  — {spec['help']}" for spec in hyperparams]
    selected = runtime.multi_pick(options, "Select hyperparameters to override")

    overrides = {}
    for item in selected:
        name = item.split("  ", 1)[0]
        spec = next(s for s in hyperparams if s["name"] == name)
        value = _prompt_for_hyperparam(spec)
        if value is not None:
            overrides[name] = value

    config.hyperparameters = overrides
    config.save()
    return overrides


def print_job_params(config: "Config", hyperparameters: dict) -> None:
    print("\n  Job parameters:")
    print(f"    model:        {config.model_id}")
    print(f"    training:     {config.train_id}")
    print(f"    validation:   {config.val_id or '(none)'}")
    print(f"    suffix:       {config.suffix}")
    print("    hyperparameters:")
    for spec in schema.load_supervised_hyperparams(config):
        name = spec["name"]
        sent = hyperparameters.get(name)
        display = display_default(sent) if sent is not None else display_default(spec["default"])
        marker = " *" if sent is not None else ""
        print(f"      {name}: {display}{marker}")
    print("    (* = value being sent to the API)")


def confirm_create_job(config: "Config", hyperparameters: dict) -> None:
    print_job_params(config, hyperparameters)
    if not runtime.confirm("Launch fine-tuning job?"):
        runtime.abort("  cancelled — no job created.")


def extract_adapter(resp, config: "Config", model_id: str) -> Path:
    out_root = Path(config.out_dir)
    out_root.mkdir(parents=True, exist_ok=True)
    zip_path = out_root / f"{model_id}.zip"
    extract_dir = out_root / model_id

    if resp.status_code != 200:
        # With a streaming response, resp.text is not pre-loaded; read a small chunk for diagnostics.
        body = next(resp.iter_bytes(constants.DOWNLOAD_CHUNK_SIZE_BYTES), b"").decode(
            "utf-8", errors="replace"
        )
        runtime.abort(f"error: adapter download failed: {resp.status_code} {body[:200]}")

    with open(zip_path, "wb") as f:
        for chunk in resp.iter_bytes(chunk_size=constants.DOWNLOAD_CHUNK_SIZE_BYTES):
            f.write(chunk)
    print(f"  saved -> {zip_path}")

    extract_dir.mkdir(exist_ok=True)
    with zipfile.ZipFile(zip_path, "r") as z:
        z.extractall(extract_dir)
    print(f"  extracted to {extract_dir}/")
    print(f"  contents: {', '.join(sorted(p.name for p in extract_dir.iterdir()))}")

    config.downloaded = True
    config.out_dir_path = str(extract_dir)
    config.save()

    return extract_dir


def _metrics_to_dict(metrics: Any) -> dict:
    if metrics is None:
        return {}
    if isinstance(metrics, dict):
        return metrics
    if hasattr(metrics, "__dict__"):
        return vars(metrics)
    return {}


def print_checkpoints(checkpoints: list[Any]) -> None:
    if not checkpoints:
        print("  (no checkpoints returned)")
        return
    print(f"  found {len(checkpoints)} checkpoint(s):")
    for cp in checkpoints:
        step = getattr(cp, "step_number", None)
        cp_id = getattr(cp, "id", None)
        fine_tuned_model_id = getattr(cp, "fine_tuned_model_id", None)
        fine_tuned_model_checkpoint = getattr(cp, "fine_tuned_model_checkpoint", None)
        print(f"    step={step}")
        print(f"      id={cp_id}")
        print(f"      fine_tuned_model_id={fine_tuned_model_id or '(pending registration)'}")
        print(f"      fine_tuned_model_checkpoint={fine_tuned_model_checkpoint}")
        metrics = _metrics_to_dict(getattr(cp, "metrics", None))
        for key in ("step", "train_loss", "train_mean_token_accuracy", "valid_loss",
                    "valid_mean_token_accuracy", "full_valid_loss", "full_valid_mean_token_accuracy"):
            value = metrics.get(key)
            if value is not None:
                print(f"      {key}={value}")
