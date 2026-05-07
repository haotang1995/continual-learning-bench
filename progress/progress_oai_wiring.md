# Progress: OAI Proxy Wiring for `exploitable_poker` × `icl`

Permanent historical record. New entries appended chronologically; failures are kept.

Plan: `progress/plan_oai_wiring.md`.

---

## S1 — Create `.env` at repo root  ✅ success

**What was tried**: wrote `/workspace/.env` with the three vars copied from `prv_oai_example/.env_oai`.

**Environment bootstrap (not in plan, but blocker)**: the workspace had no `uv` and no `.venv`. Installed uv via `curl -LsSf https://astral.sh/uv/install.sh | sh` (lands in `~/.local/bin`), then `uv sync --all-extras`. uv created a Python 3.13 venv at `/workspace/.venv` and installed the locked dependency set (litellm, dotenv, typer, etc.). Took ~1m. No Dockerfile change needed yet — Dockerfile already has `python3`/`pip`; uv installs as user-level. Will document at S5.

**Verification**:
```
$ source .venv/bin/activate && python -c "from dotenv import load_dotenv, os; load_dotenv(); ..."
OPENAI_API_KEY -> set (len=24)
OPENAI_BASE_URL -> set (len=68)
X_API_KEY -> set (len=24)
BASE_URL: https://dwip-openai-ehe0b4f3cdctbfbp.westus2-01.azurewebsites.net/v1
```

`.env` is gitignored (line 1 of `.gitignore`). Will not be committed.

---
