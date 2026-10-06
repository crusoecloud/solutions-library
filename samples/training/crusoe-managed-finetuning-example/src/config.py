"""Configuration and state management for the fine-tuning example.

This module merges environment defaults and the resumable state file into a
single `Config` object. `run.py` creates one `Config` instance and passes it
through the flow, so step functions read/write both static settings and
runtime state in one place.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from openai import OpenAI

from . import constants, helper
from .runtime import confirm


# Fields that are persisted to the state file. The API key is intentionally
# excluded — it stays in the environment only.
_STATE_FIELDS = (
    "model_id",
    "train_id",
    "val_id",
    "hyperparameters",
    "job_id",
    "job_status",
    "fine_tuned_model",
    "downloaded",
    "out_dir_path",
    "uploaded_file_ids",
    "created_at",
    "updated_at",
)


@dataclass
class Config:
    """Static defaults + dynamic state for one fine-tuning run."""

    # Static configuration (passed in by run.py or hard-coded defaults; never
    # persisted to the state file).
    api_key: str = ""
    train_file: str = "data/training_file.jsonl"
    val_file: str = "data/validation_file.jsonl"
    suffix: str = "crusoe-finetune-script"
    poll_interval: int = 10
    out_dir: str = "outputs"
    state_file_path: str = ".crusoe-finetune-state.json"
    swagger_cache_path: str = ".crusoe-swagger.json"

    # Runtime flag (not persisted).
    resuming: bool = False

    # Dynamic state (persisted).
    model_id: str = ""
    train_id: str | None = None
    val_id: str | None = None
    hyperparameters: dict = field(default_factory=dict)
    job_id: str | None = None
    job_status: str | None = None
    fine_tuned_model: str | None = None
    downloaded: bool = False
    out_dir_path: str | None = None
    uploaded_file_ids: list[str] = field(default_factory=list)
    created_at: str | None = None
    updated_at: str | None = None

    @classmethod
    def load(cls, client: OpenAI, api_key: str) -> "Config":
        """Create a Config, load any saved state, and prompt for resume."""
        config = cls(api_key=api_key)
        config.prompt_resume(client)
        if config.resuming:
            print(f"  resuming job {config.job_id or '(not yet launched)'}")
        else:
            print("  starting a new run")
        return config

    @property
    def resume_from_job(self) -> bool:
        return self.resuming and bool(self.job_id)

    def should_pick_model(self) -> bool:
        if not self.model_id:
            return True
        if self.resuming:
            print(f"  using saved model: {self.model_id}")
        return False

    def resolve_train_id(self) -> tuple[str | None, bool]:
        """Return (train_id, is_resolved). None means training file was not chosen."""
        if self.resume_from_job:
            return self.train_id, True
        if self.resuming and self.train_id:
            return self.train_id, True
        return None, False

    def resolve_val_id(self) -> tuple[str | None, bool]:
        """Return (val_id, is_resolved). None means validation was skipped."""
        if self.resume_from_job:
            return self.val_id, True
        if self.resuming and self.val_id is not None:
            return self.val_id, True
        return None, False

    def should_gather_hyperparameter_overrides(self) -> bool:
        return not self.resume_from_job and not (self.resuming and self.hyperparameters)

    def should_launch_job(self) -> bool:
        return not self.resume_from_job

    def should_await_fine_tuned_model(self) -> bool:
        if self.resuming and self.fine_tuned_model:
            print(f"  using saved fine_tuned_model: {self.fine_tuned_model}")
        return not (self.resuming and self.fine_tuned_model)

    def should_download(self, model: str | None = None) -> bool:
        """Prompt for adapter download and handle the no-download path."""
        if self.resuming and self.downloaded and self.out_dir_path:
            print(f"  already downloaded to: {Path(self.out_dir_path)}")
            return False

        adapter = model or self.fine_tuned_model
        if not adapter:
            print("  error: no fine_tuned_model available to download")
            return False

        if not confirm(f"Download {adapter}?"):
            self.downloaded = False
            self.save()
            print("  download skipped")
            return False
        return True

    def save(self) -> None:
        state = {k: getattr(self, k) for k in _STATE_FIELDS}
        self._save_state(state)

    def clear(self) -> None:
        """Delete the state file and reset key runtime fields."""
        self._clear_state()
        self.job_id = None
        self.job_status = None
        self.resuming = False

    def prompt_resume(self, client: OpenAI) -> None:
        """Load existing state or create a fresh one; set resuming flags."""
        state = self._load_state()

        if state:
            # Refresh status if we already have a job id.
            if state.get("job_id"):
                try:
                    job = client.fine_tuning.jobs.retrieve(state["job_id"])
                    state["job_status"] = job.status
                    if getattr(job, "fine_tuned_model", None):
                        state["fine_tuned_model"] = job.fine_tuned_model
                except Exception as e:
                    print(f"  warning: could not refresh job status: {e}")

            print(f"Found saved state file: {self.state_file_path}")
            print(f"  Created:      {self._fmt_ts(state.get('created_at'))}")
            print(f"  Updated:      {self._fmt_ts(state.get('updated_at'))}")
            print(f"  Job ID:       {state.get('job_id') or 'not yet launched'}")
            if state.get("job_id"):
                print(f"  Console:      {helper.get_console_uri(state['job_id'])}")
            print(f"  Status:       {state.get('job_status') or 'not yet launched'}")
            print(f"  Best adapter: {state.get('fine_tuned_model') or 'not yet available'}")
            print(f"  Downloaded:   {'yes' if state.get('downloaded') else 'no'}")

            if state.get("job_status") in {"succeeded", "failed", "cancelled"}:
                print("  This job has already reached a terminal state.")

            if confirm("Resume from this state? (no = start fresh and clear saved state)", default=True):
                self.resuming = True
                for k, v in state.items():
                    if hasattr(self, k) and v is not None:
                        setattr(self, k, v)
            else:
                self._clear_state()

        if not self.resuming:
            self.created_at = datetime.now().isoformat()
            self.save()

    def _load_state(self) -> dict:
        try:
            with open(self.state_file_path, "r") as f:
                return json.load(f)
        except FileNotFoundError:
            return {}
        except json.JSONDecodeError:
            print(f"  warning: state file {self.state_file_path} is corrupt; starting fresh.")
            return {}

    def _save_state(self, state: dict) -> None:
        Path(self.state_file_path).parent.mkdir(parents=True, exist_ok=True)
        state["updated_at"] = datetime.now().isoformat()
        with open(self.state_file_path, "w") as f:
            json.dump(state, f, indent=2)

    def _clear_state(self) -> None:
        try:
            os.remove(self.state_file_path)
        except FileNotFoundError:
            pass

    @staticmethod
    def _fmt_ts(iso: str | None) -> str:
        if not iso:
            return "unknown"
        try:
            return datetime.fromisoformat(iso).strftime("%Y-%m-%d %H:%M:%S")
        except ValueError:
            return iso
