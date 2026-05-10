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
- [ ] **Smoke 2 (Qwen3.5-2B GRPO).** Qwen3.5-2B is ~4 GB at bf16, may fit
      in the 4 GB free per GPU. Try next.
- [ ] **Commit** `Dockerfile.newer_sglang` + progress entries.

## Open risks for this attempt

1. **Host GPU contention.** All 4 A6000s currently 39.3/46 GB used by
   another workload. Both smokes are bounded by this until the GPUs free
   up. The Dockerfile itself is independently verifiable (sglang 0.5.11
   imports, model_config + Gemma-4 architecture both load successfully).
2. **Slime patches may break for GRPO.** Slime ships in-tree patches
   against sglang 0.5.10.post1; force-upgrading sglang under them may
   break the GRPO smoke. Will discover during Smoke 2.
3. **Image size: 62.7 GB.** Almost 3× the 23 GB slime base. The bump
   pulls torch 2.11+cu130 + flash-attn-4 + cu13 nvidia wheels alongside
   the existing cu129 stack. Acceptable for the goal but not lean.

## Active blockers

- **GPU memory pressure on the host** prevents end-to-end weight load of
  Gemma-4 E2B-it. Image is otherwise functional.
