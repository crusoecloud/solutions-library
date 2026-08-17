# Contributing to the Crusoe Solutions Library

Thanks for helping grow this collection. This repo is a set of independent, runnable solutions for [Crusoe Cloud](https://crusoe.ai/) — each one lives in its own top-level directory and should be usable on its own, without pulling in the rest of the repo.

## Before you start

Open an issue or draft PR early for anything nontrivial — new solutions, breaking changes to an existing one, or restructuring. It's a lot cheaper to redirect a plan than a finished PR.

For small fixes (typos, broken links, doc corrections, minor bug fixes), just send a PR.

## Adding a new solution

1. **Create a new top-level directory** named for what it does, following the existing convention: lowercase, hyphen-separated, often suffixed with the platform it targets (`-cmk` for Crusoe Managed Kubernetes, `-vms` for VM-based solutions, etc.). Look at existing directories for naming precedent before picking a name.
2. **Include a `README.md`** in the directory, following the shape used throughout the repo:
   - `#` title
   - A short paragraph describing what it does and when to use it
   - Setup / prerequisites specific to this solution (beyond the repo-wide ones in the root README)
   - Quick-start usage with copy-pasteable commands
   - Any tunables, gotchas, or known limitations worth calling out
3. **Add an entry to the root [README.md](./README.md)** under the relevant `## Solutions` category (Training, Inference, Storage, Performance, Observability, Identity & Security, Networking, or a new category if none fit) — one link plus a 1-3 sentence summary, matching the existing entries.
4. **Keep it self-contained.** Scripts, manifests, Dockerfiles, and docs for a solution belong inside that solution's directory. Don't introduce shared/common code across solutions unless you're deliberately establishing a new shared pattern — ask first.
5. **Gitignore generated/local output** (results files, state files, secrets) rather than committing it — see existing `.gitignore` files for the pattern.

Steps 2 and 3 are enforced automatically — see [Automated checks](#automated-checks) below. A PR that adds a new top-level directory without a README and a root-README entry will fail CI.

## Modifying an existing solution

- Read the solution's README fully before changing scripts or manifests — several solutions document non-obvious ordering constraints or workarounds (e.g. why a step must run before another). If you must change documented behavior, update the README in the same PR.
- Don't add error handling, abstractions, or config knobs for cases the solution doesn't actually need. Match the existing style of the file you're editing.
- If your change is user-facing (new env var, new required argument, changed default), update both the solution's README and any inline usage/help text in the script.

## Automated checks

CI ([.github/workflows/check-solutions-structure.yml](./.github/workflows/check-solutions-structure.yml)) runs [scripts/check_solutions_structure.py](./scripts/check_solutions_structure.py) on every PR, which enforces:

- Every top-level solution directory has a `README.md`.
- Every top-level solution directory is linked from the root `README.md`.
- No root-`README.md` link points at a top-level directory that doesn't exist.

Run it locally before pushing:

```bash
python3 scripts/check_solutions_structure.py
```

To have it run automatically on every `git commit` in your clone, set up hooks once with either:

```bash
# Option A: plain git, no extra tools
./scripts/setup-hooks.sh

# Option B: if you already use the pre-commit framework
pip install pre-commit
pre-commit install
```

Both do the same check; use whichever fits your existing workflow. Hook setup is per-clone — a fresh `git clone` won't have it wired up until you run one of these.

This check only covers repo *structure* — it doesn't (and can't) verify that a solution actually works.

## Testing your change

Beyond the automated structure check, there's no functional CI in this repo today, so manual verification is on you:

- For scripts/CLIs: run them against a real (or disposable) Crusoe Cloud resource end-to-end, not just a syntax check.
- For Kubernetes manifests: apply them to a real or test cluster and confirm the expected resources come up healthy.
- Note what you tested (and against what, e.g. GPU SKU, cluster type) in your PR description — reviewers can't run everything themselves.

## Pull requests

- Keep PRs scoped to one solution (or one cross-cutting change) at a time.
- Write a PR description that explains *why*, not just *what* — link an issue if one exists.
- All PRs require review from [CODEOWNERS](./CODEOWNERS) before merging.

## Style

- Shell scripts: `set -euo pipefail` (or documented reason not to), quote variables, prefer explicit flags over relying on defaults.
- No secrets, API keys, or customer-identifying data in commits — use env vars / external secret stores and document what's required.
- Favor plain, boring solutions (bash, kubectl, Terraform) over introducing a new language or framework unless the solution genuinely needs it.
