# Solutions Library Standards (DRAFT)

Enforced by CI on every MR (`scripts/`), and locally by the pre-MR Claude skill. "MUST" fails the MR; "SHOULD" warns.

## What a solution is
A reproducible way to do something on Crusoe Cloud that is hard or impossible with the product alone. It MUST contain runnable artifacts (code, IaC, manifests, charts, scripts), not only markdown. Documentation intended only for AI ingestion is not a solution.

## Layout
- One directory per solution at `<category>/<solution>/` (or `<category>/<group>/<solution>/` for the groups listed in `scripts/check_solutions_structure.py`), lowercase-hyphenated, suffixed with platform where useful (`-cmk`, `-vms`).
- MUST self-contain its scripts, manifests, and docs; no cross-solution imports.
- MUST have `README.md`: H1 title, one-paragraph summary, then H2 `Prerequisites` and `Quick start` (aliases accepted: Requirements; Usage/Installation/Getting started). SHOULD also have `Configuration`, `Verification`, `Cleanup`, `Troubleshooting` where they apply.
- MUST be linked from the root README under a category with a 1-3 sentence summary.
- MUST NOT contain AI-assistant instruction files: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.windsurfrules`, `copilot-instructions.md`, `.claude/`, `.cursor/`.
- SHOULD have a `.gitignore` covering state, results, and local env files; examples use `*.example`.
- SHOULD carry its own `LICENSE` only if it differs from the root Apache-2.0 license.

## Existing solutions (grandfathering)
Violations present when the standards were adopted are listed in `scripts/standards_baseline.json` and tolerated until an MR touches that solution. The MR that touches it must fix every violation for that solution (including removing AI-instruction files). New solutions get no grace. Never add entries to the baseline by hand.

## Security and confidentiality
- No secrets, keys, tokens, customer names, internal hostnames/URLs, pricing, or internal ticket links (gitleaks + deny-list).
- Example identities use `example.com`/placeholder values.
- Dependencies pinned (lockfile or exact image digest/tag); no known HIGH/CRITICAL vulnerabilities.

## Code
- Shell: `set -euo pipefail`, quoted variables, shellcheck clean.
- Python/Go: formatted and linted (ruff / go vet), non-trivial logic has tests.
- Terraform: `terraform fmt`, tflint clean, no hardcoded credentials.
- Comments explain why, not what. Reuse shared pattern inside the solution rather than copy-pasting blocks.

## Public presentation
- Root has README, LICENSE, CONTRIBUTING. Add SECURITY.md only if Crusoe names a vulnerability-reporting channel.
- Tone: factual, no internal jargon or unreleased product names.
- Disclaimer text (community resource, no warranty) lives in the root README only.

## Review
- Every MR needs approval from a designated approver (CODEOWNERS), CI green, and the author's statement of what was tested and on what.
