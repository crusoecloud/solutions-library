# Crusoe Managed Fine-Tuning — end-to-end

A runnable end-to-end example that picks a base model, chooses training and validation files (reusing already-uploaded files or uploading new ones), launches a fine-tuning job via the OpenAI-compatible Crusoe Intelligence Foundry API, polls to completion, lists checkpoints, and optionally downloads the best adapter.

The script is **fully resumable**: it writes a small state file after every step, so you can close the terminal during a long-running job and resume later simply by re-running `python3 run.py`.

The same `run.py` runs as a CLI (`python3 run.py` — arrow-key menus + Y/n) or as a Jupyter notebook (`python3 run-jupyter.py` generates `run.ipynb` and opens it in JupyterLab with `input()` boxes and numbered menus, cleaning up on exit). The runtime plumbing (prompts, environment detection, and environment-aware exits) lives in `src/runtime.py`; configuration and state live in `src/config.py`; selection/formatting/builder logic lives in `src/helper.py`; constants live in `src/constants.py`; `run.py` itself reads as a clean demo of the underlying API.

## Prerequisites

- Python 3.10+
- A Crusoe Cloud account with access to the Intelligence Foundry (fine-tuning)
- A Crusoe API key (bearer-style) — generate one in the Crusoe Console under Security

## Quick start

```bash
# 1. install dependencies
pip install -r requirements.txt

# 2. configure credentials
cp .env.example .env
#   edit .env and set CRUSOE_API_KEY (required)

# 3. run end-to-end (.env is auto-loaded by the script)
python3 run.py
```

> `python-dotenv` auto-loads `.env` when `run.py` starts — no need to source it
> yourself. Vars already exported in your shell take precedence over `.env`,
> so `CRUSOE_API_KEY=x python3 run.py` still wins over a `.env` value.

The script will:
0. Check for a saved state file and offer to resume if one exists
1. List every model visible to your API key and prompt you to pick one — expect several base models (different families and sizes) to be available
2. Ask whether to reuse an uploaded file or upload a local file for training
3. Ask whether to reuse an uploaded file, upload a local file, or skip validation
4. Show all supervised hyperparameters with their defaults and let you override any subset
5. Pretty-print the resolved job parameters and ask for Y/n confirmation before launching
6. Poll the job until it reaches `succeeded` / `failed` / `cancelled`, printing dots while the status is unchanged and a timestamp when it changes
7. Wait for the scheduler to register the adapter (`fine_tuned_model`)
8. List all checkpoints with metrics, checkpoint model name, and inference-ready model ID
9. Ask whether to download the best adapter (the job's `fine_tuned_model`) as a ZIP and extract it to `outputs/`

## Files

| File | Purpose |
|---|---|
| `run.py` | Main script — the full fine-tuning flow. Percent-format (`# %%` cells) so it converts to a notebook via jupytext. |
| `src/constants.py` | Non-configurable constants: API base URL, terminal statuses, polling/download tuning, and hyperparameter metadata. |
| `src/config.py` | Configuration and state management: `Config` holds hard-coded defaults and the resumable state, receives the API key from `run.py`, and handles the resume prompt. |
| `src/helper.py` | Formatting, selection, and builder helpers — no API calls; takes API outputs and `Config`, prompts the user, and returns API-ready values. Used by `run.py`. |
| `src/runtime.py` | Runtime helper (`pick`, `confirm`, `text`, `multi_pick`, `abort`) — uses questionary on a TTY and a zero-dependency `input()` fallback in notebooks / pipes; stops cleanly in both CLI (`sys.exit`) and Jupyter (`WorkflowError`). |
| `run-jupyter.py` | Generates `run.ipynb` from `run.py` via jupytext, opens it in JupyterLab, and removes it on exit. Checks for missing deps and offers to install them. |
| `requirements.txt` | `openai`, `httpx`, `questionary`, `python-dotenv`. |
| `requirements-jupyter.txt` | `jupyterlab`, `jupytext` — dev-only deps used by `run-jupyter.py`. |
| `.env.example` | Template — copy to `.env` and fill in `CRUSOE_API_KEY`. |
| `data/training_file.jsonl` | 20-row training sample (OpenAI chat-format). |
| `data/validation_file.jsonl` | 5-row validation sample. |

## Configuration

Only the API key is read from the environment (see `.env.example`). All other values are either hard-coded defaults in `src/config.py`, chosen interactively, or restored from the state file:

| Variable | Required | Default | Description |
|---|---|---|---|
| `CRUSOE_API_KEY` | yes | — | Bearer API key for `api.intelligence.crusoecloud.com` |

Editable defaults in `src/config.py`:

| Setting | Default | Description |
|---|---|---|
| `train_file` | `data/training_file.jsonl` | Default training JSONL path (used when uploading a local file) |
| `val_file` | `data/validation_file.jsonl` | Default validation JSONL path (used when uploading a local file) |
| `suffix` | `crusoe-finetune-script` | Job suffix (shows up in the job/model name) |
| `poll_interval` | `10` | Seconds between status polls |
| `out_dir` | `outputs` | Where to save the downloaded adapter ZIP + extracted files |
| `state_file_path` | `.crusoe-finetune-state.json` | Path to the resumable state file |

## Resuming a job

The script saves progress to `config.state_file_path` (`.crusoe-finetune-state.json` by default) after every step. This makes long-running fine-tuning jobs resumable — there is no timeout, so you can close the terminal and come back later.

When you re-run the script, it detects the state file and shows a summary:

```
Found saved state file: .crusoe-finetune-state.json
  Created:      2026-07-08 12:00:00
  Updated:      2026-07-08 14:32:00
  Job ID:       ftjob-abc123
  Status:       running
  Best adapter: not yet available
  Downloaded:   no

Resume from this state? [Y/n]
```

Answer `Y` to pick up where you left off. The script will skip already-completed steps and continue from the next one.

To force a fresh run, either delete the state file or answer `n` at the resume prompt.

### During polling

While polling, the script prints:

```
  polling ftjob-abc123 every 10s.
  you can exit and resume later; state is saved in .crusoe-finetune-state.json
  press Ctrl-C to pause.
```

Pressing Ctrl-C pauses polling and asks:

```
Job is still running. Keep it running and exit? (no = cancel job) [Y/n]
```

- **Y** (default): saves state and exits. The job keeps running on Crusoe. Re-run the script later to resume.
- **n**: cancels the job, clears the state file, and exits.

## Running as a notebook

`run.py` uses `# %%` cell markers (jupytext percent-format), so it runs as a
plain script *and* launches as a JupyterLab notebook in one command:

```bash
python3 run-jupyter.py   # generate run.ipynb, open in JupyterLab, clean up on exit
```

If any dependencies are missing, the script will list them and prompt you to
install them with:

```bash
python3 -m pip install -r requirements.txt -r requirements-jupyter.txt
```

To install manually up front, run that command before `python3 run-jupyter.py`.

Each notebook cell both defines a helper and executes that step inline, so
you can run the notebook one cell at a time or hit **Run All**. The model
picker, file picker, hyperparameter editor, and launch gate use the same
`pick()` / `confirm()` / `multi_pick()` calls as the CLI. In a notebook they
render as Jupyter `input()` boxes and numbered menus instead of arrow-key
menus. Close JupyterLab when done and `run-jupyter.py` removes the generated
`run.ipynb` automatically (it's git-ignored either way).

## Data (JSONL) format

Both data files use OpenAI chat-format — one JSON object per line:

```json
{"messages": [{"role": "system", "content": "You are an intent classifier..."}, {"role": "user", "content": "The order I placed yesterday still hasn't shipped."}, {"role": "assistant", "content": "shipping_status"}]}
```

Replace `data/*.jsonl` with your own data in the same format to fine-tune on a different task.

## Cleanup

The script keeps all artifacts by default — the uploaded files, the job record, and the downloaded adapter (if you chose to download it). To remove them:

- **Uploaded files**: delete via the Crusoe Console or the Intelligence Foundry API (`client.files.delete(id)`). The final step of `run.py` also offers to delete files uploaded during that run.
- **Running job**: cancel via the Crusoe Console or the API (`client.fine_tuning.jobs.cancel(id)`). Cancellation stops the job; the job record itself remains in the console.
- **Downloaded adapter**: `rm -rf outputs/`.
- **State file**: `rm .crusoe-finetune-state.json` (or the path set in `src/config.py`).

## Disclaimer

This solution is provided **AS IS, WITHOUT WARRANTY OF ANY KIND**, express or implied. The script, data, and documentation are reference implementations intended to help you get started — they are not a supported Crusoe product and may not be appropriate for every deployment without customization. Running fine-tuning jobs incurs compute cost. Use at your own risk; review the script against your security and operational requirements before running it against production resources.
