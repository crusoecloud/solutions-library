# %% [markdown]
# # Crusoe Managed Fine-Tuning — end-to-end
#
# This script walks through the full fine-tuning workflow on the Crusoe
# Intelligence Foundry:
#
# 1. Pick a model to fine-tune.
# 2. Upload (or reuse) training and validation files.
# 3. Launch a fine-tuning job with the chosen hyperparameters.
# 4. Poll until the job completes.
# 5. List checkpoints.
# 6. Optionally download the best adapter.
#
# The script is fully resumable: `src/config.py` saves a small state file after
# every step, so you can close the terminal and re-run `python3 run.py` later
# to continue from where you left off.
#
# - **CLI**: `python3 run.py` uses interactive prompts and arrow-key menus.
# - **Jupyter**: `python3 run-jupyter.py` converts this percent-formatted file into
#   a notebook with the same steps.
#
# Configure via `.env` (copy `.env.example` to `.env` and set `CRUSOE_API_KEY`).

# %%
from __future__ import annotations

import os
from pathlib import Path

import dotenv
import httpx
from openai import OpenAI

from src import constants, helper, runtime
from src.config import Config

dotenv.load_dotenv()  # load .env before reading CRUSOE_API_KEY

# %% [markdown]
# ## Configuration and state
#
# `Config` (from `src/config.py`) merges the defaults in `.env` and the resumable
# state file into one object. This script uses it for both configuration and
# saved state.
#
# `crusoe` is the standard OpenAI SDK client pointed at the Crusoe backend; it
# is used for most file and fine-tuning API calls.

# %%
def require_api_key() -> str:
    key = os.environ.get("CRUSOE_API_KEY", "")
    if not key:
        runtime.abort("error: CRUSOE_API_KEY is not set. Copy .env.example to .env and fill it in.")
    return key


def build_client(api_key: str) -> OpenAI:
    return OpenAI(api_key=api_key, base_url=constants.BASE_URL)


api_key = require_api_key()
crusoe = build_client(api_key)
config = Config.load(crusoe, api_key)

# %% [markdown]
# ## Step 0 — Pick a model
#
# Fine-tuning uses the model IDs registered in Crusoe, not raw HuggingFace
# names. This step lists every model visible to your API key and lets you
# pick one.

# %%
print("\n--- Step 0: pick a model ---")
if config.should_pick_model():
    models = list(crusoe.models.list())
    helper.pick_model(config, models)

# %% [markdown]
# ## Step 1 — Choose training and validation files
#
# Reuse a file already uploaded to the API, upload a new local file, or skip
# the validation file. The default local paths come from `Config`.

# %%
def upload_file(path: str, label: str) -> str:
    p = Path(path)
    if not p.exists():
        runtime.abort(f"error: {label} file not found: {path}")
    print(f"  uploading {label}: {path} ({p.stat().st_size} bytes)...")
    with open(p, "rb") as f:
        file_obj = crusoe.files.create(file=f, purpose="fine-tune")
    print(f"  uploaded {label} as {file_obj.id}")
    config.uploaded_file_ids = sorted(set(config.uploaded_file_ids) | {file_obj.id})
    config.save()
    return file_obj.id


def list_uploaded_files() -> list:
    """Return already-uploaded fine-tune files from the API."""
    return list(crusoe.files.list(purpose="fine-tune"))


def retrieve_file(file_id: str):
    """Fetch metadata for an uploaded file from the API."""
    return crusoe.files.retrieve(file_id)


print("\n--- Step 1: choose training file ---")
uploaded_files = list_uploaded_files()
helper.select_training_file(
    config,
    uploaded_files=uploaded_files,
    upload_file=lambda path: upload_file(path, "training"),
    retrieve_file=retrieve_file,
)

print("\n--- Step 1b: choose validation file ---")
helper.select_validation_file(
    config,
    uploaded_files=uploaded_files,
    upload_file=lambda path: upload_file(path, "validation"),
    retrieve_file=retrieve_file,
)

# %% [markdown]
# ## Step 2 — Gather hyperparameter overrides and launch the job
#
# Choose which hyperparameters to override (server defaults are used for the
# rest). You will be asked to confirm the job parameters before starting the job.

# %%
print("\n--- Step 2: launch the fine-tuning job ---")
if config.should_launch_job():
    hyperparameters = helper.gather_hyperparameter_overrides(config)

    helper.confirm_create_job(config, hyperparameters)

    print("  launching job...")
    job_create_kwargs: dict = {
        "model": config.model_id,
        "training_file": config.train_id,
        "suffix": config.suffix,
        "method": {
            "type": "supervised",
            "supervised": {"hyperparameters": hyperparameters},
        },
    }
    if config.val_id:
        job_create_kwargs["validation_file"] = config.val_id
    job = crusoe.fine_tuning.jobs.create(**job_create_kwargs)
    config.job_id = job.id
    config.job_status = "queued"
    config.save()
    print(f"  created job {config.job_id} (status: {job.status})")
    print(f"  view in console: {helper.get_console_uri(config.job_id)}")
else:
    print(f"  using saved job: {config.job_id}")
    print(f"  view in console: {helper.get_console_uri(config.job_id)}")

# %% [markdown]
# ## Step 3 — Poll until the job finishes
#
# Polls the job status until it is `succeeded`, `failed`, or `cancelled`.
# There is no timeout — fine-tuning jobs can run for hours. Press Ctrl-C to
# pause; the state file is saved, so you can resume later.

# %%
print("\n--- Step 3: poll until terminal ---")
if config.resuming and config.job_status in constants.TERMINAL_STATUSES:
    print(f"  job already terminal: {config.job_status}")
    job = crusoe.fine_tuning.jobs.retrieve(config.job_id)
else:
    job = helper.poll_until_terminated(
        config,
        config.job_id,
        get_job=lambda: crusoe.fine_tuning.jobs.retrieve(config.job_id),
        cancel_job=lambda: crusoe.fine_tuning.jobs.cancel(config.job_id),
    )
    if job.status != "succeeded":
        err = getattr(job, "error", None)
        runtime.abort(f"error: job ended with status '{job.status}'{f': {err}' if err else ''}")
    print(f"  job {config.job_id} succeeded (finished_at={job.finished_at})")

# %% [markdown]
# ## Step 3b — Wait for the adapter to register
#
# A `succeeded` job still needs a moment to register the final
# `fine_tuned_model` ID. Poll until it is available before moving on.

# %%
print("\n--- Step 3b: await fine_tuned_model registration ---")
if config.should_await_fine_tuned_model():
    config.fine_tuned_model = helper.poll_until_value(
        "fine_tuned_model",
        poll_fn=lambda: getattr(crusoe.fine_tuning.jobs.retrieve(config.job_id), "fine_tuned_model", None),
    )
    config.save()

# %% [markdown]
# ## Step 4 — List checkpoints
#
# Print the checkpoints the job produced, including step number, metrics, and
# the model ID for each checkpoint (when available).

# %%
print("\n--- Step 4: list checkpoints ---")
checkpoints = crusoe.fine_tuning.jobs.checkpoints.list(config.job_id).data
helper.print_checkpoints(checkpoints)

# %% [markdown]
# ## Step 5 — Optionally download the best adapter
#
# Download the final adapter as a ZIP and extract it to `outputs/<model_id>/`.
# This step is optional; the model is also available for inference through
# the API.

# %%
print("\n--- Step 5: download the best adapter ---")
out: Path | None = None
if config.should_download(config.fine_tuned_model):
    url = f"{constants.BASE_URL}/models/{config.fine_tuned_model}/download"
    print(f"  downloading {url} ...")
    with httpx.Client() as client:
        with client.stream(
            "GET",
            url,
            headers={"Authorization": f"Bearer {config.api_key}"},
            timeout=constants.ADAPTER_DOWNLOAD_TIMEOUT_SECONDS,
        ) as resp:
            out = helper.extract_adapter(resp, config, config.fine_tuned_model)

# %% [markdown]
# ## Summary
#
# At this point, the end-to-end fine-tuning workflow is complete:
#
# 1. **Picked a model** to fine-tune from the available Crusoe models.
# 2. **Chose training and validation files** (uploading new ones or reusing already uploaded files).
# 3. **Launched the fine-tuning job** with the selected hyperparameters.
# 4. **Polled until the job finished** and reached a terminal state.
# 5. **Waited for the best adapter** to register with a `fine_tuned_model` ID.
# 6. **Listed the checkpoints** produced by the job.
# 7. **Downloaded the best adapter** (if requested) to the local `outputs/` directory.
#
# The next cell prints a concise summary of the actual results from this run.

# %%
print("\nSummary\n")
summary_lines = [
    ("Model selected", config.model_id),
    ("Training file uploaded", config.train_id),
    ("Validation file", config.val_id or "skipped"),
    ("Fine-tuning job launched", config.job_id),
    ("Console URL", helper.get_console_uri(config.job_id)),
    ("Job completed", config.job_status),
    ("Best adapter registered", config.fine_tuned_model),
    ("Checkpoints listed", f"{len(checkpoints)} checkpoint(s)"),
    ("Adapter download", out or "skipped"),
]
width = max(len(label) for label, _ in summary_lines)
for label, value in summary_lines:
    print(f"{label:<{width}}: {value}")

# %% [markdown]
# ## Cleanup
#
# If this run uploaded new files to Crusoe, you can optionally delete them now to avoid
# leaving orphaned files in your account. Files that were reused (not uploaded by this
# run) are not affected.

# %%
print("\n--- Cleanup: uploaded files ---")
if config.uploaded_file_ids:
    ids = ", ".join(sorted(config.uploaded_file_ids))
    if runtime.confirm(f"Delete uploaded files ({ids})?", default=False):
        remaining: list[str] = []
        for file_id in sorted(config.uploaded_file_ids):
            print(f"  deleting {file_id}...")
            try:
                crusoe.files.delete(file_id)
            except Exception as e:
                print(f"  warning: could not delete {file_id}: {e}")
                remaining.append(file_id)
        config.uploaded_file_ids = remaining
        config.save()
        print("  cleanup complete")
    else:
        print("  uploaded files kept")
else:
    print("  no files uploaded in this run")
