# Current Progress

**Status**: ✅ All sub-steps complete.

**Active sub-step**: S7 — final consolidation (this commit).

**Done**: S0 .. S6.

## Final state

- `.env` at repo root (gitignored) with `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `X_API_KEY`.
- `src/vendors/oai_proxy.py` wraps `litellm.completion` / `acompletion` /
  `responses` / `aresponses` to inject `X-API-Key` from env.
- `src/cli.py` calls `oai_proxy.install()` after `load_dotenv()`.
- `scripts/smoke_oai_proxy.py` for quick connectivity verification.
- `Dockerfile` documents `.env` contract and installs `uv` system-wide.
- `progress/plan_oai_wiring.md` (plan), `progress/progress_oai_wiring.md`
  (full history including the Responses-API failure + resolution).

## How to reproduce the eval run

```
source .venv/bin/activate
clbench run --config configs/exploitable_poker/exploitable_poker_icl.json \
  --system-params '{"provider_mode":"litellm_chat"}' \
  --no-live-dashboard
```

## Result summary

- **Mean score across 3 runs**: 0.4667 (std 0.7024).
- **Cumulative gain**: +2.8333.
- **Baseline coverage**: 5/5 instances, mean −0.10.

## Known caveats

- The proxy doesn't implement `GET /v1/models` (404). Model availability was
  confirmed by direct chat-completion probes; not via catalog enumeration.
- The proxy's Azure-OpenAI backend gates the Responses API on a query-string
  `api-version`. Until that's plumbed through the proxy, icl must run in
  `provider_mode=litellm_chat`. If you want auto/native mode to work, the
  fix is at the proxy (not in this repo).
