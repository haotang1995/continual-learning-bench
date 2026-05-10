# Progress — Local vLLM (Gemma 4 E4B IT)

Permanent historical record of every attempt, including failures.
See `plan_local_vllm.md` for the plan and `current_progress.md` for live state.

---

## 2026-05-08 — Setup baseline

### Host probe (pre-S1)
- 4× NVIDIA RTX A6000 (46 GB ea), driver 580.126.09, CUDA 13.0.
- 17 TB free on `/`.
- No `.venv` and no `uv` in this fresh sandbox; pyproject pins Py 3.13.
- HF auth: `HF_TOKEN` set; `whoami-v2` returns user `haotang`;
  `GET https://huggingface.co/google/gemma-4-E4B-it/resolve/main/config.json`
  returns 200 (855 bytes) — no gating block.
- Confirmed model exists: `google/gemma-4-E4B-it` (created 2026-03-02,
  ~5.5M downloads, `gemma4` arch, `image-text-to-text` pipeline).

### S1 — Install vLLM (success)
- Bootstrap: installed `uv 0.11.12` to `/root/.local/bin/uv` (the system-wide
  install at `/usr/local/bin` failed because the `sandbox` user can't write
  there in this container).
- `uv sync --all-extras` materialized `.venv` (Python 3.13.13) with the
  full clbench dependency set.
- `uv add --optional local_llm vllm` resolved and installed
  `vllm==0.20.1`, `torch==2.11.0+cu130`, `transformers==5.8.0`,
  `triton==3.6.0`, `xgrammar==0.2.0`, `outlines-core==0.2.14`,
  `sentencepiece==0.2.1`, etc. uv normalized the extra to `local-llm` in
  pyproject (PEP 503 dash-form).
- Dockerfile updated with a "Local-LLM mode" comment block documenting
  the optional install + env-override contract.

**Verify**:
```
$ /workspace/.venv/bin/python -c "import vllm, torch; print('vllm', vllm.__version__); print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), 'devices', torch.cuda.device_count())"
vllm 0.20.1
torch 2.11.0+cu130 cuda True devices 4
```

Status: **success**.

---

## 2026-05-09 — S2/S3/S4 (E4B) success, S5 partial

### S2 — Pre-download `google/gemma-4-E4B-it`
- `huggingface-cli` is deprecated in `huggingface_hub>=1.0`; first attempt
  exited 0 without downloading. Switched to the new `hf` CLI
  (`/workspace/.venv/bin/hf download google/gemma-4-E4B-it`).
- Result: 15 GB on disk under
  `~/.cache/huggingface/hub/models--google--gemma-4-E4B-it/`.
- Note: `Gemma4ForConditionalGeneration` is multimodal (text + audio +
  vision). vLLM serves it text-only without extra flags.

Status: success.

### S3 — Launch vLLM (E4B)
- First launch failed with `vllm: error: unrecognized arguments: --disable-log-requests`
  (vLLM 0.20.1 dropped that flag). Retried without it.
- Second launch failed inside KV-cache init with
  `PermissionError: [Errno 13] Permission denied: '/root/.triton'`.
  Container `sandbox` user has `HOME=/root` but cannot write to top-level
  `/root`. Resolved by redirecting cache dirs to writable workspace paths:
  ```
  TRITON_CACHE_DIR=/workspace/.cache/triton
  TORCHINDUCTOR_CACHE_DIR=/workspace/.cache/torchinductor
  VLLM_CACHE_ROOT=/workspace/.cache/vllm
  XDG_CACHE_HOME=/workspace/.cache
  ```
- Third launch (single-GPU, GPU 0) succeeded. `/v1/models` returned
  `google/gemma-4-E4B-it` with `max_model_len=16384`.
- Subsequently relaunched with `--data-parallel-size 4` (per user direction)
  to use all 4 A6000s. All 4 EngineCore replicas allocated 972k tokens of
  KV cache (59× concurrency per replica). Application startup complete on
  all 4 ApiServer processes.

Status: success.

### S4 — Smoke test
- `scripts/smoke_local_vllm.py` issued plain chat + `response_format=json_schema`
  probes against the local server.
- Both passed (plain returned `'pong'`; json_schema returned valid
  `{"color": "red", "count": 3}`).

Status: success.

### S5 — Run `exploitable_poker × icl × quick_test` (E4B): partial / blocked

First attempt:
- Hung on retry loop with `Transient error (attempt N/6), retrying in Ks:
  no embedded JSON object matching schema fields found: line 1 column 1
  (char 0)`. Killed after ~15 minutes; only 22 of an estimated 80+ calls
  served.

Diagnostic probes:
- Standalone `litellm.completion(model="openai/google/gemma-4-E4B-it",
  response_format=PokerAction, ...)` works perfectly — even across an 8-hand
  growing-history simulation (5-8 s per call, all valid JSON).
- The failure is specific to icl's actual prompt shape (the multi-line
  "What's your action? FOLD/CALL/CHECK/RAISE X / Respond according to the
  PokerSchema..." block).

Root cause:
- Instrumented `completion_with_structured_output` to log every response.
  Found `finish=length, compl_tok=16096, content_len=25067`, with the
  trailing 100 chars being `' \n  \n  \n  \n  \n  ...'` — Gemma 4 E4B,
  under guided-decoding, degenerates inside the `thinking` string field
  into endless whitespace. JSON object never closes; parser fails at
  position 0 because no decode strategy produces a valid object.

Mitigation tried: env-var `CLBENCH_MAX_COMPLETION_TOKENS=2048` knob that
caps per-call output. After the cap, of 49 calls:
- 30 succeeded (`finish=stop`, valid JSON)
- 16 truncated at 2048 (`finish=length`, JSON open) → parse fail → retry
- 3 from before the cap took effect at 16096 / 10092
- 5 of those parse failures exhausted the full 6-retry budget; one of those
  aborted the entire run with
  `RuntimeError: Run 1/1 failed: ... LLM call failed: no embedded JSON
   object matching schema fields found`.

Conclusion: wiring works; Gemma 4 E4B IT is too unreliable on icl's
structured-action schema for a clean run. Switching to
`google/gemma-4-31B-it` with TP=4 across the 4 A6000s.

Code change kept from this attempt:
- `src/systems/utils/structured_output.py`: read
  `CLBENCH_MAX_COMPLETION_TOKENS` env var and inject `max_tokens` into
  the litellm.completion call. Inert when unset; useful for any local
  model prone to guided-decoding runaway.

Status: partial (wiring verified; reliable run blocked on model capacity).
Next: download `google/gemma-4-31B-it`, relaunch vLLM with
`--tensor-parallel-size 4`, retry.

---

### S5b — Switch to gemma-4-31B-it (success)

- Downloaded `google/gemma-4-31B-it` (~62 GB total, two safetensors shards
  of 49.8 GB + 12.8 GB) into HF cache.
- Killed E4B vLLM, GPUs back to 1 MiB each.
- First TP=4 launch failed with
  `ValueError: Chunked MM input disabled but max_tokens_per_mm_item (2496)
   is larger than max_num_batched_tokens (2048)`. Gemma 4 is multimodal
  (image + audio + text); the vision encoder needs ≥ 2496 tokens of batch
  budget. Resolved by passing `--max-num-batched-tokens 16384`.
- Second launch succeeded:
  - Loading weights took ~8 s (4 TP ranks in lockstep).
  - Engine init (profile + KV cache + warmup) took 116 s, of which
    44.8 s was compilation.
  - GPU KV cache: 86 663 tokens / cluster (= 5.29× concurrency at
    16 384-token requests).
  - All 4 GPUs settled at ~39.3 GiB used.

Status: success.

### S5 (re-run on 31B) — success

- Same env: `CLBENCH_MAX_COMPLETION_TOKENS=2048`, `OPENAI_BASE_URL=http://127.0.0.1:8000/v1`,
  `OPENAI_API_KEY=local`, `X_API_KEY=` (empty so oai_proxy.install is no-op).
- Command:
  ```
  clbench run --config configs/exploitable_poker/exploitable_poker_icl_local_vllm.json
              --no-live-dashboard --runs 1 --max-workers 1 -v
  ```
- Result: completed cleanly.
  - Score: **−0.1000**
  - 17 icl LLM calls, 58 783 total tokens.
  - **0 transient retries** (vs 16 on E4B).
  - 35 chat-completions served by vLLM (includes 5-instance baseline +
    1-run main, plus per-hand betting-round calls).
  - Wall time: ~2 min.
  - Trace: `results/exploitable_poker/traces/2026-05-10T00-35-08.649372Z/`.
- Result snippet from `run_0000.json`:
  ```
  score: -0.1
  total_profit: -5
  hands_played: 5
  bb_per_hand: -0.1
  improvement (1st half → 2nd half): +10.83
  ```

Conclusion: wiring works end-to-end against a local vLLM server, with zero
outbound traffic to public LLMs. The structured-output reliability problem
on E4B does not appear on 31B.

Status: success.

### S6 — Documentation + Dockerfile + commit

- `README.md` extended with a "Running against a local vLLM" section
  documenting the 31B-on-TP=4 recipe, the cache-dir contract, the
  `--max-num-batched-tokens` requirement, and the
  `CLBENCH_MAX_COMPLETION_TOKENS` knob.
- `Dockerfile` "Local-LLM mode" comment block extended with the same
  recipe + env-var contract.
- `TODO/TODO.md` updated: marked the local-LLM goal done, recorded
  follow-ups (E4B reliability, cross-task verification, cache-dir UX).
- `progress/current_progress.md` rewritten to reflect ✅ done state.
- This file (`progress/progress_local_vllm.md`) appended with the full
  S5b / S5-on-31B / S6 narrative, including the failures.

Status: success.

---

## TL;DR — what this whole effort actually was

clbench was already provider-agnostic via LiteLLM, so "add local-LLM
support" reduces to two runtime moves and one defensive code tweak:

1. **Run an OpenAI-compatible server locally**
   `vllm serve <model> --host 127.0.0.1 --port 8000` (or sglang on :30000;
   the choice of server doesn't matter to clbench).
2. **Point LiteLLM at it**
   Set `OPENAI_BASE_URL=http://127.0.0.1:8000/v1`, `OPENAI_API_KEY=local`,
   leave `X_API_KEY=""` so `src/vendors/oai_proxy.install()` stays a no-op.
   Use a model id with the `openai/` prefix (e.g. `openai/google/gemma-4-31B-it`)
   so LiteLLM routes through its OpenAI-compatible client.
3. **`provider_mode: "litellm_chat"`** in the icl system params — bypasses
   clbench's automatic Responses-API path (which vLLM doesn't serve) and
   forces the plain chat-completions API.

That's it. Same flow works for any OpenAI-compatible local server
(vLLM, sglang, llama.cpp's `--api-server`, TGI, etc.) by changing only
the URL.

### What changed in the repo

| File | Why |
|------|-----|
| `pyproject.toml` | Added optional `local-llm` extra (`vllm>=0.20.1`) |
| `uv.lock` | Auto-regenerated by `uv add` |
| `src/systems/utils/structured_output.py` | +12 lines: read `CLBENCH_MAX_COMPLETION_TOKENS` env var and pass through as `max_tokens` (safety net for small local models that degenerate under guided decoding) |
| `configs/exploitable_poker/exploitable_poker_icl_local_vllm.json` | New config: model id + `provider_mode=litellm_chat` + schedule. Backend-agnostic — all routing comes from env. |
| `scripts/smoke_local_vllm.py` | New: plain + `response_format=json_schema` probe |
| `Dockerfile` | Comment block documenting the `local-llm` install + env contract |
| `README.md` | "Running against a local vLLM" section |
| `.gitignore` | `.cache/` for vLLM/Triton/Inductor scratch |

The only behavioral code change is the env-var hook — all other edits
are config, deps, or documentation.

### Lessons / gotchas worth remembering

- **vLLM 0.20.1 dropped `--disable-log-requests`** — older example
  commands won't launch.
- **`$HOME`-not-writable hosts**: redirect Triton, TorchInductor, vLLM,
  and XDG caches to `/workspace/.cache/...`. Without this, KV-cache
  init crashes with `PermissionError: '/root/.triton'`.
- **Gemma 4 multimodal encoder** needs `--max-num-batched-tokens >= 2496`.
  Default 2048 hits `Chunked MM input disabled but max_tokens_per_mm_item
  (2496) is larger than max_num_batched_tokens (2048)` at startup.
- **`huggingface-cli` is deprecated** in `huggingface_hub>=1.0`. Use the
  new `hf` CLI (`hf download <repo>`); the legacy command exits 0
  without downloading.
- **Small-model guided-decoding runaway**: Gemma 4 E4B IT under
  `response_format=json_schema` degenerates ~30 % of the time inside
  required string fields (`thinking`), filling output budget with
  whitespace and never closing the JSON. Symptom in clbench:
  `Transient error: no embedded JSON object matching schema fields
  found: line 1 column 1 (char 0)` retried with backoff. 31B does not
  exhibit this. The new `CLBENCH_MAX_COMPLETION_TOKENS` env var caps
  damage but doesn't cure it; for small models, a `maxLength` constraint
  on the schema's free-text fields would.
- **Same probe in isolation worked** even with E4B (8 hands, 5–8 s each,
  all valid JSON). The failure only appeared with icl's actual prompt
  shape ("What's your action? FOLD/CALL/CHECK/RAISE / Respond according
  to the PokerSchema..."). Isolated probes are not a proof of clbench-
  level reliability.

### Final verified run

`exploitable_poker × icl × quick_test` against
`google/gemma-4-31B-it` with TP=4 across 4× A6000:

- score **−0.1000** (5 hands, total profit −5 chips)
- 17 LLM calls, 58 783 total tokens
- **0 transient retries**
- ~2 min wall time
- trace at `results/exploitable_poker/traces/2026-05-10T00-35-08.649372Z/`
