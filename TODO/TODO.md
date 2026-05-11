# Tasks

- [x] Initial Setup
- [x] Wire clbench to custom OAI-compatible proxy (X-API-Key injection)
  - `.env` contract documented in `Dockerfile` + `README.md`
  - `src/vendors/oai_proxy.py` wraps litellm chat-completions and Responses API
  - `src/cli.py` installs the wrap after `load_dotenv()`
  - Smoke test: `python scripts/smoke_oai_proxy.py`
  - Verified end-to-end on `exploitable_poker × icl` (`progress/progress_oai_wiring.md`)
- [x] Add Docker image supporting Gemma-4 vllm inference + Qwen3.5-2B GRPO
  - `Dockerfile.verl_vllm` (FROM verlai/verl:vllm018.dev1, vllm 0.19.1, verl 0.7.1)
  - Smoke 1: `vllm serve google/gemma-4-E2B-it` on 1× A6000 — PASS
  - Smoke 3: 35-step verl GRPO on `Qwen/Qwen3.5-2B` (4× A6000, FSDP, vllm
    rollout) — val acc 0.391 → 0.625 on held-out GSM8K (+60 % relative)
  - Full attempt log: `progress/progress_sglang_upgrade.md` (Attempts 1-10)
  - Slime+sglang dead-end (`Dockerfile.newer_sglang`) kept on disk as reference
- [ ] Reproduce `final_results/runs/icl-gpt-5.4` on this proxy
  - Blocker: proxy doesn't serve `gpt-5.4`; only `gpt-5` available
  - Fallback recipe (gpt-5 substitute): see `progress/progress_oai_wiring.md` "How to reproduce"
- [ ] Drop `provider_mode=litellm_chat` override once the proxy forwards `api-version=2025-03-01-preview` to enable the OpenAI Responses API path
- [x] Add `viewers/compare_traces_remote.html` — remote-picker variant of `compare_traces.html`
  - Scans `results/` and `final_results/runs/*/tasks/` over an `http.server`-style index
  - Matches both live `viewer_artifact_*.json[.gz]` and per-task `<task>.json[.gz]` (final_results) since both are `kind: "viewer_artifact"` shape
  - Local file picker preserved; remote selections append to the comparison
- [ ] Live in-progress comparison (poll `live/<id>/manifest.json` and synthesize a viewer-artifact-shaped record) — out of scope for this change
