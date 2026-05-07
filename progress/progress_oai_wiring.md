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

## S5 — Update Dockerfile  ✅ success

Two changes appended to `Dockerfile`:
1. Install `uv` system-wide via the official installer (the workspace
   started without it; needed for `uv sync --all-extras`).
2. Comment block documenting the `.env` contract (`OPENAI_API_KEY`,
   `OPENAI_BASE_URL`, `X_API_KEY`) and pointing at
   `src/vendors/oai_proxy.py` for the rationale.

No new pip packages introduced; litellm + dotenv come from `pyproject.toml`
via uv. The Dockerfile remains a reproducible record.

---

## S6 — Run `exploitable_poker` × `icl` end-to-end

### Attempt 1 (failed) — `provider_mode=auto`

`clbench run --config configs/exploitable_poker/exploitable_poker_icl.json`
fired off the icl system, which detected the model as `openai` and dispatched
through `litellm.responses(...)` (the OpenAI Responses API).

Failure surface: `litellm.exceptions.BadGatewayError: ... 400 Azure OpenAI
Responses API is enabled only for api-version 2025-03-01-preview and later`.

**Why it failed**: the proxy is fronting an Azure OpenAI deployment which
gates the Responses API on a query-string `api-version` that the proxy
doesn't auto-inject. Our `X-API-Key` reached the proxy fine (no 403), so
the wrap was working — the failure is at Azure's request validation.

**Side fix**: the original wrap only patched `litellm.completion` /
`litellm.acompletion`, missing `litellm.responses` / `litellm.aresponses`
which the openai-native branch of `provider_adapters.py:312` uses.
Updated `src/vendors/oai_proxy.py` to also wrap both Responses entry
points. Smoke-checked the wrap reaches them by re-running the failing
call: still got the Azure 400 (so the request is reaching Azure with
our header attached) — confirming the issue is purely the Responses
API gating, not auth.

**Resolution**: pass `--system-params '{"provider_mode":"litellm_chat"}'`.
That is one of the documented `ProviderMode` values (`auto | native |
litellm_chat`) and forces the chat-completions code path, which the
proxy supports without the `api-version` quirk.

### Attempt 2 (success) — single-run smoke

```
clbench run --config configs/exploitable_poker/exploitable_poker_icl.json \
  --system-params '{"provider_mode":"litellm_chat"}' \
  --no-live-dashboard --runs 1 --max-workers 1 --debug
```

- 1 run + 5-instance baseline, all 6 episodes complete.
- Score: **0.2000**.
- 20 LLM calls, 84 581 tokens, $0.029 estimated by litellm.
- No errors. Trace at
  `results/exploitable_poker/traces/2026-05-07T00-35-29.394652Z/`.

### Attempt 3 (success) — full quick_test schedule

```
clbench run --config configs/exploitable_poker/exploitable_poker_icl.json \
  --system-params '{"provider_mode":"litellm_chat"}' \
  --no-live-dashboard
```

- Schedule defaults: 3 runs × 5 instances + 5 baseline (all calling-station
  opponent). max_workers=8, mode=permute.
- Per-run scores: **+0.40, −0.20, +1.20**. Mean = **0.4667**, std = 0.7024.
- Baseline mean: −0.10 (5/5 covered).
- Final cumulative gain: **+2.8333**. Final cumulative reward: +2.3333.
- Run cumulative gains: +2.5, −0.5, +6.5.
- Artifacts:
  - Viewer: `results/exploitable_poker/viewer_artifact_2026-05-07T00-40-36.913441Z_20260507_004329.json.gz`
  - Traces: `results/exploitable_poker/traces/2026-05-07T00-40-36.913441Z/{baseline,run_0000,run_0001,run_0002}.json`

The benchmark is fully wired up: every LLM call traversed the user's proxy
via `X-API-Key`, structured-output parsing worked, traces and viewer artifacts
landed under `results/`.

---
