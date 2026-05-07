# Plan: Wire `clbench` to custom OAI proxy for `exploitable_poker` evaluation

## Goal

Run the Continual Learning Bench `exploitable_poker` task with the `icl` system, routing **all** LLM calls through the user's custom OpenAI-compatible proxy (the one demoed in `prv_oai_example/`). Public OpenAI must not be hit.

## What "wired up" means concretely

The proxy needs three things on every request:
1. `OPENAI_BASE_URL` = `https://dwip-openai-ehe0b4f3cdctbfbp.westus2-01.azurewebsites.net/v1`
2. Standard `Authorization: Bearer $OPENAI_API_KEY`
3. **Extra header** `X-API-Key: $X_API_KEY` (this is the non-standard part — neither litellm nor the openai SDK send it by default)

litellm already picks up (1) and (2) from env. Only (3) needs new code.

## Scope

- **Task**: `exploitable_poker` only.
- **System**: `icl` only.
- **Other systems** (`ace`, `mem0`, `icl_notepad`, `claude`, `codex`, `human`): out of scope. Won't break them, but won't verify them either.

## Relevant call sites under icl (already audited)

- `src/systems/utils/structured_output.py:274` — `litellm.completion(**completion_kwargs)` (the one synchronous LLM call icl makes per step)
- `src/systems/icl/system.py` — uses `litellm.token_counter` (local, no network) and dispatches through `provider_adapters` / `structured_output`
- `src/cli.py` already calls `load_dotenv()` so a repo-root `.env` is honored

There are no other live network calls under icl's path. `vendors/ace/llm.py` is ace-only, ignored.

## Approach: global litellm hook

Per the user's choice, inject `X-API-Key` exactly once, in a bootstrap module that runs before any LLM call. Two viable mechanisms; will pick whichever actually works after a smoke test:

1. **`litellm.headers`** — global dict merged into every request's headers. Simplest if it's still supported on this litellm version.
2. **Monkey-patch `litellm.completion` / `litellm.acompletion`** — wrap to inject `extra_headers["X-API-Key"]` from env when set, mirroring `prv_oai_example/sema_utils.py:63-66`.

Mechanism (2) is the fallback and is guaranteed to work; will only use (1) if a smoke test confirms the header actually lands on the wire.

## Sub-steps

### S0 — Probe proxy `/models` to confirm available model IDs
Before committing to any model name in configs, hit the proxy directly:

```bash
curl -sS "$OPENAI_BASE_URL/models" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "X-API-Key: $X_API_KEY" | jq '.data[].id'
```

(Run with env loaded from the new `.env`, after S1.) Record the full list in `progress/progress_oai_wiring.md`. This determines:
- Whether `gpt-4.1` (the example in `sema_utils.py`) is actually served.
- What `icl`'s default `model="gpt-5"` (`src/systems/icl/system.py:45`) should be overridden to via CLI flag or config.
- Whether reasoning/structured-output models are available, since `icl` uses `litellm`'s structured-output path.

If the listed models don't match what configs expect, S6 must pass `--model <available-id>` (or edit the schedule) rather than relying on defaults.

### S1 — Create `.env` at repo root
Copy values from `prv_oai_example/.env_oai` into `/workspace/.env`. Verify `.gitignore` excludes `.env` (it does — checked).

**Verify**: `python -c "from dotenv import load_dotenv; load_dotenv(); import os; print(bool(os.getenv('OPENAI_BASE_URL')), bool(os.getenv('X_API_KEY')))"` prints `True True`.

### S2 — Add `src/vendors/oai_proxy.py` bootstrap
A tiny module that, on import, registers the global header injection. Roughly:

```python
import os
import litellm

def install():
    x_key = os.getenv("X_API_KEY")
    if not x_key:
        return
    # Try mechanism 1: litellm.headers
    if hasattr(litellm, "headers") and isinstance(litellm.headers, dict):
        litellm.headers["X-API-Key"] = x_key
    # Mechanism 2 fallback: wrap completion/acompletion
    _orig_completion = litellm.completion
    _orig_acompletion = litellm.acompletion
    def _inject(kwargs):
        eh = dict(kwargs.get("extra_headers") or {})
        eh.setdefault("X-API-Key", x_key)
        kwargs["extra_headers"] = eh
        return kwargs
    def completion(*a, **kw):
        return _orig_completion(*a, **_inject(kw))
    async def acompletion(*a, **kw):
        return await _orig_acompletion(*a, **_inject(kw))
    litellm.completion = completion
    litellm.acompletion = acompletion

install()
```

### S3 — Hook the bootstrap into the CLI startup
Add `from .vendors import oai_proxy  # noqa: F401` (or explicit `oai_proxy.install()`) near the top of `src/cli.py`, **after** `load_dotenv()` so env is populated. This guarantees the hook is in place before any system imports its LLM client.

### S4 — Smoke test the proxy from inside the repo
Tiny script `scripts/smoke_oai_proxy.py` that calls `litellm.completion(model="gpt-4.1", messages=[...], max_tokens=10)` and prints the response. Run it once. Expected: a non-error response from the proxy. If it fails, inspect the actual outgoing request (mechanism 1 may not work — fall back to mechanism 2).

### S5 — Update `Dockerfile`
Per AI.md rule 1: no new pip installs are needed (litellm + python-dotenv already in `pyproject.toml`), but add a comment block in `Dockerfile` documenting that `.env` with `OPENAI_BASE_URL` + `X_API_KEY` must be mounted/provided at runtime. No package changes.

### S6 — Run the actual benchmark
```
clbench run exploitable_poker --schedule quick_test --system icl
```
- Verify the run completes without auth errors.
- Verify trace artifacts are produced under `results/`.
- Capture stdout + final scores in `progress/progress_oai_wiring.md`.

### S7 — Document & commit
Per each sub-step:
- Append result to `progress/progress_oai_wiring.md` (permanent log, including any failures).
- Refresh `progress/current_progress.md` (live status).
- Commit using the AI.md commit message format with prefix `feat:` (S2/S3), `chore:` (S1/S5), `test:` (S4/S6).

### Sub-step ordering note
S0 depends on S1 (needs `.env` loaded). Real order: **S1 → S0 → S2 → S3 → S4 → S5 → S6 → S7**.

## Risks / open questions

- **`litellm.headers` may be ignored** for OpenAI-compatible providers in the installed litellm version. Mitigation: mechanism (2) wrap is the safe default; will use it from the start unless a quick check shows (1) suffices.
- **Structured output path** in `structured_output.py` may pass its own `extra_headers`. The wrap uses `setdefault`, so it won't clobber explicit values — but it also won't override them. Acceptable.
- **`exploitable_poker` may not exist as a runnable schedule on this branch** — confirmed it does (`src/tasks/exploitable_poker/` is present, `configs/exploitable_poker/` is present).
- **Cost / rate limits**: a `quick_test` schedule should be cheap. Will check the schedule's episode count before running and bail if it looks like a full sweep.

## Out of scope

- Wiring up any system other than `icl`.
- Caching changes (litellm disk cache like in `sema_utils.py` is not strictly needed; can be added later if the user wants).
- Touching `src/vendors/ace/`.

## Definition of done

`clbench run exploitable_poker --schedule quick_test --system icl` completes end-to-end with all LLM traffic going to the proxy URL, results land in `results/`, and `progress/progress_oai_wiring.md` records the run with verification output.
