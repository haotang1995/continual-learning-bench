# Current attempt: sglang upgrade — Dockerfile.newer_sglang

**Live status doc** for the in-flight attempt. Overwrite freely (per AI.md
rule 2B). Permanent history lives in `progress_sglang_upgrade.md`.

The previous "current attempt" (OAI proxy / X-API-Key wiring) is
complete; its frozen final state is preserved in
`progress/progress_oai_wiring.md` and `TODO/TODO.md`.

## Goal of this attempt

Produce `Dockerfile.newer_sglang` (Option A: keep slime base, bump
sglang→0.5.11 + transformers→5.8.0 in our layer) and verify the two smoke
tests pass on 4×A6000.

## Steps

- [x] **Research:** confirm version targets, hardware constraints, HF
      access. (See Attempt 0 in `progress_sglang_upgrade.md`.)
- [x] **Write `Dockerfile.newer_sglang`.** Copies the existing Dockerfile
      with a 3-step version-bump (sglang==0.5.11 + cu13 LD_LIBRARY_PATH +
      FLASHINFER_DISABLE_VERSION_CHECK).
- [x] **Build the image.** Image size 62.7 GB. Build succeeds; in-build
      `from sglang.srt.configs.model_config import ModelConfig` passes.
- [~] **Smoke 1 (Gemma-4 sglang serve).** Functionally passes the Docker
      part: sglang launches, finds `Gemma4ForConditionalGeneration`, picks
      triton attention backend, loads tokenizer, inits torch.distributed,
      starts weight load. Final inference blocked by **host GPU memory
      contention** (each A6000 has ~4 GB free out of 46 GB; gemma-4
      embedding alone needs 4.38 GB). Will re-run when GPUs are free.
- [✗] **Smoke 2 (Qwen3.5-2B GRPO).** Structurally blocked: torch upgrade
      from 2.9.1+cu129 to 2.11.0+cu130 (forced by sglang 0.5.11's pin)
      breaks slime's pre-compiled extensions (`flash_attn` 2.7.4.post1
      undefined symbol; `transformer_engine` 2.10.0 same). slime's
      `megatron.bridge` cannot import. Resolution requires either CUDA-13
      toolkit + source rebuild of flash-attn / TE / cublas alignment, or
      a two-image split (existing `Dockerfile` for GRPO,
      `Dockerfile.newer_sglang` for sglang inference).
- [x] **Commit** `Dockerfile.newer_sglang` + progress entries (commit
      3f773bc); will commit this final progress update next.

## Decision point for the user

Three paths from here:

**(a) Two-image strategy (recommended for time-to-value).** Keep both
files: `Dockerfile` for slime GRPO training, `Dockerfile.newer_sglang`
for sglang 0.5.11 inference. Each works; pick by use case. The
"single image supports both" goal is dropped.

**(b) Source-build everything (recommended for production unification).**
Extend `Dockerfile.newer_sglang` with:
1. `apt install cuda-toolkit-13-0` (~3 GB).
2. Rebuild `flash-attn==2.7.4.post1` from source against torch 2.11+cu130
   (~15-30 min).
3. Upgrade `transformer_engine` and `nvidia-cublas-cu13` to a matched
   pair containing `cublasLtGroupedMatrixLayoutInit_internal`.
4. Re-verify `megatron.bridge` import.
Adds ~30-60 min to build time on first run; later builds cached.

**(c) Wait for upstream alignment.** Future slime release built against
sglang 0.5.11 / torch 2.11+cu130 (when slimerl publishes one) collapses
this to a one-liner FROM slimerl/slime:newer-tag.

## Active blockers

- **Slime GRPO** structurally blocked in `Dockerfile.newer_sglang` until
  one of the paths above is chosen.
- **Gemma-4 final generation** blocked by transient GPU memory contention
  (will resolve when host workload finishes).
