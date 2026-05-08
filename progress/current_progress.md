# Current Progress

**Status**: ✅ Feature complete. All sub-steps shipped.

## Final state

- `.env` at repo root (gitignored) with `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `X_API_KEY`.
- `src/vendors/oai_proxy.py` wraps `litellm.completion / acompletion / responses / aresponses`
  to inject `X-API-Key` from env.
- `src/cli.py` calls `oai_proxy.install()` after `load_dotenv()`.
- `scripts/smoke_oai_proxy.py` for quick connectivity verification.
- `Dockerfile` documents `.env` contract and installs `uv` system-wide.
- `README.md` documents the proxy / X-API-Key flow + provider_mode override.
- `TODO/TODO.md` reflects task state and follow-ups.
- `progress/plan_oai_wiring.md` (plan) + `progress/progress_oai_wiring.md`
  (full history including the Responses-API failure + resolution).

## How to reproduce the eval run on this proxy

```
source .venv/bin/activate
clbench run --config configs/exploitable_poker/exploitable_poker_icl.json \
  --system-params '{"provider_mode":"litellm_chat"}' \
  --no-live-dashboard
```

## Result summary (exploitable_poker × icl × gpt-5-mini × quick_test)

- **Mean score across 3 runs**: 0.4667 (std 0.7024).
- **Cumulative gain**: +2.8333.
- **Baseline coverage**: 5/5 instances, mean −0.10.

## Comparison to `final_results/runs/icl-gpt-5.4`

Not directly comparable (different schedule + different model). The published
suite uses `default` schedule (5 stages × 5 runs) and `gpt-5.4` (a snapshot
the user's proxy doesn't serve — Azure 404). Closest reproducible substitute
is `gpt-5` on the `default` schedule; recipe in `progress/progress_oai_wiring.md`.

## Known caveats / follow-ups

- Proxy doesn't implement `GET /v1/models` (404). Model availability was
  confirmed by direct chat-completion probes.
- Proxy's Azure backend gates the Responses API on `api-version=2025-03-01-preview`
  the proxy doesn't auto-inject. Until that's fixed at the proxy, icl must
  run with `provider_mode=litellm_chat` (chat-completions). When the proxy
  forwards `api-version`, drop the override (see `TODO/TODO.md`).
- `gpt-5.4` is not deployed on this proxy; full numerical reproduction of
  `final_results/runs/icl-gpt-5.4` not currently possible.
