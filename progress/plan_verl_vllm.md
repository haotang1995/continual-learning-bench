# Plan: upgrade Docker for newer sglang + slime model coverage

## Goal (final, narrowed 2026-05-10)

A new file **`Dockerfile.newer_sglang`** (existing `Dockerfile` untouched)
that delivers, on the local 4×A6000 host:

1. **Working sglang rollout from `google/gemma-4-E2B-it`**
2. **One GRPO smoke-test round-trip via slime+sglang on `Qwen/Qwen3.5-2B`**

DeepSeek-V4-Flash is **dropped from the smoke set** — the model requires
FP4/FP8 hardware kernels (Hopper/Blackwell) that A6000s lack, and the 284 B
weights would not fit on 184 GB regardless. We still bump sglang to a
version that has V4 *code-path support* so the image is V4-ready for future
hardware, but we do not run any V4 smoke locally.

Verified upstream (2026-05-10):
- `sglang==0.5.11` on PyPI (latest)
- `transformers==5.8.0` on PyPI (latest)
- `google/gemma-4-E2B-it` config: arch `Gemma4ForConditionalGeneration`
  (audio+vision+text multimodal), model_type `gemma4`, requires transformers
  ≥5.5
- `Qwen/Qwen3.5-2B` config: arch `Qwen3_5ForConditionalGeneration`
  (vision+text multimodal), model_type `qwen3_5`, requires transformers ≥
  the 4.57.0.dev0-equivalent (i.e. modern 5.x)

Slime base ships sglang 0.5.10.post1 + transformers 5.3.0 — both below
threshold for these two models, so an upgrade is required.

## What's blocking us today

Per the research (web search of sglang/slime/HF repos, see "References"):

| Model | Required sglang | Required transformers | slime:latest? |
|---|---|---|---|
| `gemma-4-E2B-it` | ≥ **0.5.11** (PR [#21952](https://github.com/sgl-project/sglang/pull/21952), merged 2026-04-07) | pinned commit `91b1ab1f…` or transformers ≥ 5.4 | **No** |
| `DeepSeek-V4-Flash` | ≥ **0.5.11** (Day-0 PRs #23600/#23882, [LMSYS blog 2026-04-25](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/)) | likely ≥ 5.4 | **No** |
| `Qwen3.5-2B` | ≥ 0.5.9 basic; **0.5.11** for GDN kernel opt | ≥ 5.3 (latest recommended for vision/GDN paths) | text path probably yes; **GDN/vision needs 0.5.11** |

So the upgrade target is **sglang ≥ 0.5.11 + transformers ≥ 5.4** (or the
specific commit pinned by the Gemma 4 PR), with a slime build tracking sglang
0.5.11. The slime base's torch 2.9.1+cu129 / flash-attn 2.7.4.post1 / megatron-
core 0.16.0rc0 should remain compatible.

## Output artifact

**Do not modify `Dockerfile`.** All changes go to a **new file
`Dockerfile.newer_sglang`** alongside the existing one. The original
`Dockerfile` (slime:latest with sglang 0.5.10.post1) stays as-is for users
who don't need the new models, and `Dockerfile.newer_sglang` is the opt-in
path for Gemma-4 / V4-architecture / Qwen3.5-2B-GRPO work. Build with:

```
docker build -f Dockerfile.newer_sglang -t clbench-sglang-newer .
```

## High-level options

We have to decide where the upgrade lives. Three options enumerated; the
plan picks one to try first.

### Option A — keep slime base, upgrade sglang+transformers in our layer

- `Dockerfile.newer_sglang`: `FROM slimerl/slime:latest`
- Append a `RUN` step that does something like
  ```
  uv pip install --upgrade --force-reinstall \
    "sglang==0.5.11" \
    "transformers @ git+https://github.com/huggingface/transformers.git@<gemma4-commit>"
  ```
  with `UV_PROJECT_ENVIRONMENT=/usr` so it overrides the slime base's pinned
  versions in-place.
- **Pros:** smallest diff over the existing Dockerfile; we keep slime's
  megatron-core / megatron-bridge / NCCL setup intact for the GRPO smoke.
- **Risks:**
  - slime's preinstalled patches (megatron-bridge, sglang router patches in
    `slime/docker/patch/`) are wired against 0.5.10.post1. Forcibly bumping
    sglang underneath them may break the slime RL loop, even if pure sglang
    inference still works.
  - flash-attn 2.7.4.post1 may need a rebuild against a newer sglang's CUDA
    kernel layout.
  - `--force-reinstall` of transformers from a git commit pulls in deps that
    may shadow slime's pinned versions (numpy, tokenizers).

### Option B — switch to a newer slime/sglang upstream image

- Pin to a slime image tagged after the Gemma-4 / V4 work landed. Candidates
  (need to verify availability):
  - `slimerl/slime:v0.3.x` once published with sglang 0.5.11
  - `slimerl/sglang:v0.5.11` (sglang-only base; we'd then add slime via a
    pip/git install in our layer)
  - `lmsysorg/sglang:v0.5.11-cu129` for inference-only support, dropping
    slime entirely (kills the GRPO smoke goal).
- **Pros:** the upstream maintainer has already validated the
  sglang/slime/megatron version triplet; we don't have to debug it.
- **Risks:**
  - At time of writing, no `slimerl/slime:v0.3.x` tag is confirmed published.
    Need to check Docker Hub / THUDM/slime releases.
  - Image swap may invalidate the existing `Dockerfile`'s layout assumptions
    (`/usr/local/lib/python3.12/dist-packages`, `EXTERNALLY-MANAGED`, the
    sandbox uid-1000 setup, etc.). Since we're writing a *new* file we can
    re-derive cleanly, but we duplicate ~120 lines of plumbing.

### Option C — drop slime, use sglang-only base + install slime manually

- `FROM lmsysorg/sglang:v0.5.11-cu129`
- `pip install git+https://github.com/THUDM/slime.git@<commit>`
- **Pros:** clean version pinning; no slime tag waiting.
- **Risks:** slime's installation expects megatron-core, megatron-bridge,
  patches, NCCL configs that the slime image preassembles. Reproducing that
  in `Dockerfile.newer_sglang` is a project unto itself, and the GRPO smoke
  is the most likely casualty.

**Recommended order to try:** **A first, fall back to B, only do C if both
fail.** Option A is a 5-10 line addition to a copy of the current Dockerfile
and we can test in <30 minutes; B/C take hours.

## Hardware reality check (confirmed with user 2026-05-10)

Available host: **4× RTX A6000 (compute capability 8.6, Ampere, 46 GB each =
~184 GB total VRAM).** This forces three concrete consequences:

- **No FP8 kernels.** FP8 e4m3/e5m2 tensor-core ops require Hopper (sm_90)
  or newer. sglang's FP8 path on Ampere falls back to BF16, with no perf
  benefit and a memory increase.
- **No FP4 kernels at all.** FP4 e2m1 requires Blackwell (sm_100+).
- **184 GB VRAM ceiling.** No workable quantization to fit a 284B-parameter
  model.

This makes **`deepseek-ai/DeepSeek-V4-Flash` physically unservable on this
host**: it ships with FP4 experts + FP8 attention, both of which the GPUs
can't execute, and even at FP4-equivalent storage the weights (~142 GB)
plus KV cache + activations would not fit comfortably in 184 GB once you
account for sglang's overhead.

**Decision:** the Dockerfile must still install sglang ≥0.5.11 (so the V4
*code path* is present and the image is "V4-ready" for future Blackwell
hosts), but the V4-Flash smoke test on **this** host is replaced by a
proxy smoke that exercises the same code path on a smaller DeepSeek model.

## Smoke tests (definition of done)

All run inside the freshly built image, on the local 4×A6000 host. Auth
uses `HF_TOKEN` (already set in shell; we'll add it to the `.env` contract).

1. **sglang inference smoke — Gemma 4 E2B-it**
   ```
   python -m sglang.launch_server \
     --model-path google/gemma-4-E2B-it \
     --port 30000 --trust-remote-code \
     --tp-size 1 &
   curl -s localhost:30000/generate \
     -d '{"text":"Hello, ", "sampling_params":{"max_new_tokens":16}}'
   ```
   Pass criterion: non-empty completion. The 5B-total / 2.3B-active model
   fits comfortably on 1×A6000.

2. **sglang inference smoke — DeepSeek V4 architecture (proxy)**
   Full V4-Flash is deferred (see "Hardware reality check"). Proxy options
   in increasing strength — pick the strongest that runs:
   - **(a) Import smoke (always do this):**
     ```
     python -c "from sglang.srt.models.deepseek_v4 import DeepseekV4ForCausalLM; print('ok')"
     ```
     Confirms the V4 architecture module is present in the installed
     sglang. Pass criterion: clean import, no `ModuleNotFoundError`.
   - **(b) Smaller-model proxy (if a V4 architecture variant is published
     in a size that fits, e.g. a hypothetical `DeepSeek-V4-Lite` or one of
     the V4 single-expert distillations):** launch sglang server on it.
     Pass criterion: server boots and serves one completion. If no such
     variant exists, skip and document.
   - **(c) V3 fallback proxy:** launch sglang on
     `deepseek-ai/DeepSeek-V3-Lite-Chat` (~16 B, fits on 2×A6000 with
     `--tp-size 2`). This validates that our sglang install can serve the
     DeepSeek family end-to-end, even if not V4 specifically. Pass
     criterion: one completion.
   - Document **explicitly in `progress_verl_vllm.md`** that full
     V4-Flash serving is **deferred until Hopper/Blackwell hardware is
     available** and is **not a regression** of this image.

3. **slime+sglang GRPO smoke — Qwen3.5-2B**
   - Locate slime's nearest GRPO example under `slime/examples/` or
     `slime/scripts/` (likely `qwen3_grpo.sh` or similar — confirm
     during execution).
   - Run with `--model Qwen/Qwen3.5-2B`, single rollout iteration, batch
     size = 1, sequence length capped to fit on 4×A6000 with `tp=2,
     dp=2` for the SGLang rollout engine and the trainer split.
   - Pass criterion: one rollout completes, one optimizer step runs, no
     CUDA OOM, no NCCL error.
   - We do **not** require loss to decrease or convergence — just that
     the loop round-trips.

## Step-by-step execution plan

1. **Confirm versions are real and reachable.**
   - `pip index versions sglang` to verify 0.5.11 is published on PyPI.
   - Check the Gemma 4 PR's transformers commit is pinned and fetchable.
   - Verify slime main supports sglang 0.5.11 (look at
     `slime/docker/Dockerfile` upstream).
2. **Try Option A** (in-layer upgrade).
   - Append a `RUN uv pip install --upgrade ...` to our Dockerfile that
     bumps sglang + transformers.
   - Build the image. Note size + build time.
   - Run smoke #1 (Gemma 4) on the dev host.
3. **If Option A breaks slime's RL loop**, switch to Option B and try
   `slimerl/sglang:v0.5.11` (or whatever the next slime tag is).
4. **Run smoke #3** (Qwen3.5-2B GRPO). Capture logs to
   `progress/progress_verl_vllm.md`.
5. **Run smoke #2** (DeepSeek-V4-Flash) only on a multi-GPU host;
   otherwise document as "deferred — needs ≥8×H100 / B200".
6. **Commit** the working Dockerfile change. Update
   `progress/progress_verl_vllm.md` with all attempts (including
   failures).

## Risks and unknowns

- **HF token gate.** `gemma-4-E2B-it` is gated. The image needs
  `HF_TOKEN` available at `sglang.launch_server` time. Plan to pull from
  `/workspace/.env` (already wired for `OPENAI_API_KEY`); add `HF_TOKEN`
  to the documented env contract.
- **Hardware reality check.** None of the smoke tests run useful traffic on a
  CPU-only or single-consumer-GPU host. The DeepSeek-V4 smoke is the most
  hardware-bound — likely deferred. Need to confirm with the user what
  hardware is available before committing to a full smoke-test pass.
- **Image bloat.** Adding sglang 0.5.11 + transformers 5.4 on top of slime
  (which already has 0.5.10) adds ~3-5 GB before the old wheels are GC'd.
  May want a `pip cache purge` and a multi-stage build to keep size sane.
- **Lockfile drift.** Our `pyproject.toml` doesn't pin sglang/transformers
  at all (they're slime-base implicit deps), so `uv.lock` is unaffected.
  No host-side action needed.

## References

- sgl-project/sglang [PR #21952 — Gemma 4](https://github.com/sgl-project/sglang/pull/21952)
- sgl-project/sglang [issue #23602 — DeepSeek V4 roadmap](https://github.com/sgl-project/sglang/issues/23602)
- sgl-project/sglang [issue #18465 — Qwen 3.5 support](https://github.com/sgl-project/sglang/issues/18465)
- sgl-project/sglang [releases](https://github.com/sgl-project/sglang/releases)
- THUDM/slime [docker/Dockerfile](https://github.com/THUDM/slime/blob/main/docker/Dockerfile)
- LMSYS [DeepSeek-V4 Day-0 blog (2026-04-25)](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/)
- HF [google/gemma-4-E2B-it](https://huggingface.co/google/gemma-4-E2B-it)
- HF [deepseek-ai/DeepSeek-V4-Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash)
- HF [Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B)
