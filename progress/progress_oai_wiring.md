# Progress: OAI Proxy Wiring for `exploitable_poker` × `icl`

Permanent historical record. New entries appended chronologically; failures are kept.

Plan: `progress/plan_oai_wiring.md`.

---

## S0 — Probe proxy `/models`  ✅ success (with caveat)

**What was tried**:
1. `GET $OPENAI_BASE_URL/models` with both headers → **404** (`Cannot GET /v1/models`). Proxy doesn't expose the catalog endpoint. Recorded as known limitation; not a blocker.
2. Fell back to direct `POST /chat/completions` against five candidate model IDs.

**Verification commands**:
```
curl -sS "$OPENAI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "X-API-Key: $X_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<MODEL>","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":5}'
```

**Results** (HTTP status):

| Model         | Status |
|---------------|--------|
| gpt-4.1       | 200    |
| gpt-5         | 200    |
| gpt-4o-mini   | 200    |
| gpt-4.1-mini  | 200    |
| gpt-5-mini    | 200    |
| gpt-5-nano    | 200    |

**Negative test (no X-API-Key)**: `Authorization: Bearer` alone → **403 "Invalid API Key"**. Confirms the proxy enforces `X-API-Key` as the real gatekeeper; the bearer token is theater.

**Implication for icl**: `src/systems/icl/system.py:45` defaults `model="gpt-5"` and that works on the proxy. No CLI `--model` override required.

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

## S2 — `src/vendors/oai_proxy.py` bootstrap  ✅ success

Wraps `litellm.completion` and `litellm.acompletion` to splice
`extra_headers["X-API-Key"]` from `os.environ["X_API_KEY"]` into every
call. Idempotent (guarded by `_clbench_xkey_installed` flag on the
litellm module). No-op when `X_API_KEY` is unset.

Uses `setdefault`, so explicit `extra_headers` passed by callers is
preserved untouched. The repo currently has zero other `extra_headers`
sites, so no conflict surface.

**Verification**:
```
$ python -c "from dotenv import load_dotenv; load_dotenv('.env'); \
  from src.vendors import oai_proxy; \
  print('install#1:', oai_proxy.install()); \
  print('install#2:', oai_proxy.install())"
install#1: True
install#2: False
```

---

## S3 — Wire bootstrap into `src/cli.py`  ✅ success

Added `from .vendors import oai_proxy as _oai_proxy` + `_oai_proxy.install()`
immediately after `load_dotenv()` at `src/cli.py:64`. `run_benchmark.py`
imports `src.cli` so it inherits the wrap automatically; same for any
console-script entry point pointing at `src.cli:main`.

**Verification**:
```
$ python -c "import src.cli, litellm, inspect; \
  print('wrapper present:', '_inject' in inspect.getsource(litellm.completion))"
wrapper present: True
```

---

## S4 — Smoke test via litellm  ✅ success

Added `scripts/smoke_oai_proxy.py`. Calls `litellm.completion(model='gpt-4.1', …)`
after installing the wrap.

**Verification**:
```
$ python scripts/smoke_oai_proxy.py
oai_proxy.install() -> True
base_url      : https://dwip-openai-ehe0b4f3cdctbfbp.westus2-01.azurewebsites.net/v1
resolved model: gpt-4.1-2025-04-14
response      : 'pong'
```

The `gpt-4.1-2025-04-14` echo (vs requested `gpt-4.1`) confirms the
proxy resolves to a dated Azure model deployment — i.e. traffic really
went through the proxy, not OpenAI direct.

---
