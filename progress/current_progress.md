# Current attempt: sglang upgrade — Dockerfile.newer_sglang

**Live status doc** for the in-flight attempt. Overwrite freely (per AI.md
rule 2B). Permanent history lives in `progress_verl_vllm.md`.

The previous "current attempt" (OAI proxy / X-API-Key wiring) is
complete; its frozen final state is preserved in
`progress/progress_oai_wiring.md` and `TODO/TODO.md`.

## Goal of this attempt

Produce `Dockerfile.newer_sglang` (Option A: keep slime base, bump
sglang→0.5.11 + transformers→5.8.0 in our layer) and verify the two smoke
tests pass on 4×A6000.

## Steps

- [x] **Research:** confirm version targets, hardware constraints, HF
      access. (See Attempt 0 in `progress_verl_vllm.md`.)
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

## Pivot to verl+vllm (2026-05-10)

The slime+sglang path hit structural ABI walls. Switched to a fresh
attempt with `verlai/verl:vllm018.dev1` as the base (torch 2.10+cu129,
flash-attn 2.8.3, TE 2.12, all aligned). vllm 0.19.x stays in this CUDA
12.9 envelope, and verl's FSDP path doesn't need TE.

**`Dockerfile.verl_vllm`** built green. Image size 32.9 GB.

- ✅ **Smoke 1 (vllm serve Gemma-4):** end-to-end PASS. Single A6000,
  prompt "In one short sentence, what is the capital of France?" →
  "The capital of France is Paris." (8 tokens, finish_reason=stop).
- ✅ **Smoke 2 (verl GRPO 1-step on Qwen3.5-2B):** end-to-end PASS.
  4 GPUs FSDP, 8 train + 4 val rows GSM8K. Step 1 completed in 57.6s,
  `critic/score/mean=0.25`, `max_memory_allocated_gb=9.2/GPU`.

## Final state — all goals met

✅ **Smoke 1 (vllm Gemma-4):** end-to-end PASS — "The capital of France
   is Paris." (8 tokens, finish_reason=stop), 1× A6000.
✅ **Smoke 2 (verl GRPO 1-step):** end-to-end PASS — Qwen3.5-2B FSDP shard 4,
   step 1 in 57.6 s, score 0.25.
✅ **Smoke 3 (verl GRPO 35-step real run):** end-to-end PASS — 45 min
   total. Held-out GSM8K val accuracy: 0.391 → 0.656 → 0.641 → 0.625 →
   0.625. **+60-68 % relative improvement** over baseline. Train rolling
   mean (w=5): 0.34 → 0.65. Per-GPU peak memory 12.07 GB.

## Active blockers

(none — `Dockerfile.verl_vllm` satisfies both Gemma-4 inference and
Qwen3.5-2B real GRPO training on the local 4× A6000 host)

## Slime+sglang artifacts kept for reference

- `Dockerfile.newer_sglang` (slime+sglang 0.5.11 attempt) is no longer
  the primary path; superseded by `Dockerfile.verl_vllm`. Kept on disk
  for reference; can be removed in a future cleanup.
- `Dockerfile` (slime+sglang 0.5.10.post1, original) still works for
  users who specifically want sglang inference + slime training without
  Gemma-4. No changes recommended.
