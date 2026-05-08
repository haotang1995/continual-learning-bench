# Tasks

- [x] Initial Setup
- [x] Wire clbench to custom OAI-compatible proxy (X-API-Key injection)
  - `.env` contract documented in `Dockerfile` + `README.md`
  - `src/vendors/oai_proxy.py` wraps litellm chat-completions and Responses API
  - `src/cli.py` installs the wrap after `load_dotenv()`
  - Smoke test: `python scripts/smoke_oai_proxy.py`
  - Verified end-to-end on `exploitable_poker × icl` (`progress/progress_oai_wiring.md`)
- [ ] Reproduce `final_results/runs/icl-gpt-5.4` on this proxy
  - Blocker: proxy doesn't serve `gpt-5.4`; only `gpt-5` available
  - Fallback recipe (gpt-5 substitute): see `progress/progress_oai_wiring.md` "How to reproduce"
- [ ] Drop `provider_mode=litellm_chat` override once the proxy forwards `api-version=2025-03-01-preview` to enable the OpenAI Responses API path
