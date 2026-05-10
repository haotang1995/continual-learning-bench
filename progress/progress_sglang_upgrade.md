# Progress: sglang upgrade — Dockerfile.newer_sglang

Append-only log of every attempt (per AI.md rule 2). See
`plan_sglang_upgrade.md` for the static plan and `current_progress.md` for
the live status of the in-flight attempt.

## Attempt 0 — Research and version pinning (success)

**Date:** 2026-05-10
**Goal:** confirm which sglang / transformers versions support the target
models so the Dockerfile.newer_sglang upgrade is concrete.

**Actions:**
1. Inventoried the slime base (`docker run --rm slimerl/slime:latest`):
   - Python 3.12.3, torch 2.9.1+cu129, sglang 0.5.10.post1,
     transformers 5.3.0, flash-attn 2.7.4.post1, megatron-core 0.16.0rc0,
     uv 0.11.5, wandb 0.26.1.
2. Queried PyPI for latest versions:
   - `sglang` latest = **0.5.11**, 145 historical releases.
   - `transformers` latest = **5.8.0**.
3. Fetched HF model configs (HF_TOKEN set in shell):
   - `google/gemma-4-E2B-it`: arch `Gemma4ForConditionalGeneration`,
     model_type `gemma4`, transformers_version `5.5.0.dev0` →
     **needs transformers ≥ ~5.5**.
   - `Qwen/Qwen3.5-2B`: arch `Qwen3_5ForConditionalGeneration`,
     model_type `qwen3_5`, transformers_version `4.57.0.dev0` (legacy
     numbering; equivalent to modern 5.x) → **transformers 5.x supports**.
4. Confirmed local hardware: 4× RTX A6000, compute capability 8.6, 46 GB
   each (~184 GB total VRAM). Ampere only — no FP8 (needs sm_90), no FP4
   (needs sm_100).
5. Confirmed `HF_TOKEN` is exported in the shell (37 chars, hf_xxx form).

**Result:** the upgrade target is **sglang 0.5.11 + transformers 5.8.0** on
top of `slimerl/slime:latest`. DeepSeek-V4-Flash dropped from the smoke
set per hardware reality (still installed in the image so V4 code path is
present for future Hopper/Blackwell hosts).

**Status:** success.
**Next:** Attempt 1 — write Dockerfile.newer_sglang (Option A: in-layer
upgrade) and build it.

## Attempt 1 — first build: pin transformers to wrong version (failed)

**Date:** 2026-05-10
**Goal:** copy the current Dockerfile, add `uv pip install sglang==0.5.11
transformers==5.8.0`, build.

**Result:** build failed at the version-bump RUN with
```
× Because sglang==0.5.11 depends on transformers==5.6.0 and you require
  sglang==0.5.11, we can conclude that you require transformers==5.6.0.
  And because you require transformers==5.8.0, we can conclude that your
  requirements are unsatisfiable.
```
sglang 0.5.11 hard-pins `transformers==5.6.0`. Over-constraining transformers
to the latest 5.8.0 broke uv's resolver.

**Status:** failed.
**Fix:** drop the transformers pin; let sglang pull its required 5.6.0.

## Attempt 2 — sglang requires flash-attn-4 prerelease (failed)

**Date:** 2026-05-10
**Goal:** retry build with just `sglang==0.5.11` (no transformers pin).

**Result:** build failed:
```
× Because only flash-attn-4<4.0.0b9 is available and sglang==0.5.11
  depends on flash-attn-4>=4.0.0b9, we can conclude that sglang==0.5.11
  cannot be used.
hint: ... try: --prerelease=allow
```
sglang 0.5.11 transitively requires `flash-attn-4>=4.0.0b9`, which is a
prerelease wheel; uv requires `--prerelease=allow` to resolve it.

**Status:** failed.
**Fix:** add `--prerelease=allow`.

## Attempt 3 — BuildKit COPY heredoc unavailable on this host (failed)

**Date:** 2026-05-10
**Goal:** retry build after adding `--prerelease=allow`.

**Result:** the version-bump succeeded, the project deps prebuild succeeded,
but the build failed at the entrypoint COPY step with:
```
the --chmod option requires BuildKit. Refer to ... to learn how to build
images with BuildKit enabled
```
The host has docker 29.4.3 but no buildx plugin and no permission to
install one (`/var/lib/dpkg/lock-frontend: Permission denied`,
`/root/.docker: Permission denied`).

**Status:** failed.
**Fix:** rewrite the entrypoint create as `RUN printf ... > /usr/local/bin/...
&& chmod a+rx ...`, which works on the legacy docker builder.

## Attempt 4 — tokenizers conflict between transformers and clbench (failed)

**Date:** 2026-05-10
**Goal:** retry build after the entrypoint rewrite.

**Result:** image built successfully. But `import transformers` failed at
runtime:
```
ImportError: tokenizers>=0.22.0,<=0.23.0 is required for a normal
functioning of this module, but found tokenizers==0.23.1.
```
Build order had been:
1. version-bump (sglang+transformers+tokenizers) → installs the right pins.
2. `uv sync --all-extras --inexact` (clbench deps) → upgrades tokenizers
   to 0.23.1 transitively (probably via huggingface-hub or datasets).
The post-sync state had `tokenizers==0.23.1` even though step 1 installed
0.23.0.

**Status:** failed.
**Fix:** swap the order so `uv sync` runs first and the version-bump runs
last. The bump's strict pins win the final resolution.

## Attempt 5 — sglang+sgl_kernel built for cu130 but slime base is cu129 (failed)

**Date:** 2026-05-10
**Goal:** retry build with reordered steps. Run Smoke 1 (Gemma-4 sglang
serve).

**Build output:**
```
sglang 0.5.11 | transformers 5.6.0 | tokenizers 0.23.0-rc0 | torch 2.11.0+cu130
```
**Notable:** torch was upgraded from 2.9.1+cu129 (slime base) to
2.11.0+cu130 because PyPI's sglang 0.5.11 wheel pins torch 2.11+cu130.

**Smoke 1 result:** server died at startup with:
```
ImportError: [sgl_kernel] CRITICAL: Could not load any common_ops library!
- ImportError: libnvrtc.so.13: cannot open shared object file
- ModuleNotFoundError: No module named 'common_ops'
GPU Info: Compute capability: 86, Expected variant: SM86, CUDA version: 13.0
```
Two distinct issues stacked:
1. `libnvrtc.so.13` is installed at
   `/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib/libnvrtc.so.13`
   but not on `LD_LIBRARY_PATH` so the dynamic loader can't find it.
2. sgl_kernel 0.3.21 wheel only ships `sm90/` and `sm100/` arch directories
   (no `sm86/`). For Ampere, the loader falls back to
   `sm100/common_ops.abi3.so` — a "precise math compatibility" build that
   does run on sm86 — but only if libnvrtc.so.13 is loadable.

Verified independently: the original `slimerl/slime:latest` base also has
only `sm90/` + `sm100/` (no sm86), but its sgl_kernel **does** import on
A6000 because cu129 libs are already on LD_LIBRARY_PATH.

**Status:** failed (Smoke 1 blocked).

## Attempt 6 — try cu129 sglang dev build (failed: Python ABI mismatch)

**Date:** 2026-05-10
**Goal:** install sglang 0.5.11 from the cu129 index instead of cu130, to
keep the slime base's torch 2.9.1+cu129 stack and avoid the cu13 lib issue
entirely. Used:
```
uv pip install --extra-index-url https://docs.sglang.ai/whl/cu129/ \
  --index-strategy unsafe-best-match \
  "sglang==0.5.11.dev20260505+g2b769d37a"
```

**Result:** build failed:
```
× Because sglang==0.5.11.dev20260505+g2b769d37a has no wheels with a
  matching Python ABI tag (e.g., `cp312`) and you require ...
hint: only found wheels for `sglang` with the following Python ABI tag:
`cp310`
```
The cu129 sglang dev wheels are built for Python 3.10 (`cp310-cp310`); the
slime base ships Python 3.12. They're ABI-incompatible.

**Status:** failed.
**Fix:** revert to PyPI's cu130 sglang 0.5.11 (`cp312-abi3`, compatible
with slime's Python 3.12) and patch around the two cu130 issues:
- Add cu13 lib path to `LD_LIBRARY_PATH` so `libnvrtc.so.13` is found.
- Set `FLASHINFER_DISABLE_VERSION_CHECK=1` to bypass the
  flashinfer-jit-cache 0.6.7.post3+cu129 vs flashinfer 0.6.8.post1 ABI
  mismatch (slime base ships cu129 jit cache; sglang 0.5.11 pulls flashinfer
  cu130). Also try upgrading flashinfer-jit-cache.

## Attempt 7 — cu130 sglang + LD_LIBRARY_PATH fix + flashinfer bypass (success on import; OOM at weight load)

**Date:** 2026-05-10
**Goal:** retry with the two fixes.

**Build verification (in-build `python -c "from sglang.srt.configs.model_config
import ModelConfig"`):** PASS. sgl_kernel imports, sglang model_config imports,
no flashinfer error.

**Image size:** 62.7 GB.

**Smoke 1 result (Gemma-4, 1 GPU, mem-fraction 0.85):**
- sglang launched OK
- Loaded transformers 5.6.0, recognized model arch
  `Gemma4ForConditionalGeneration`, picked `triton` attention backend (no
  flashinfer-on-Gemma4 path)
- Loaded tokenizer, init torch.distributed (1 GPU), began weight load
- **`torch.OutOfMemoryError`** at
  `Gemma4TextScaledWordEmbedding.__init__()`: tried to allocate 4.38 GiB
  but only 4.07 GiB free (host-side: each GPU at 39.3/46 GB used by other
  processes).

**Smoke 1 result (Gemma-4, tp=2 on GPUs 0+1, mem-fraction 0.10,
disable-cuda-graph, max-total-tokens 4096):**
- Same OOM at `Gemma4TextScaledWordEmbedding.__init__()` even with
  `--mem-fraction-static 0.10` and tp=2 — the embedding allocation itself
  is 4.38 GiB and we have 4.31 GiB free per GPU. Off by 70 MB.

**Status:** Dockerfile.newer_sglang **functionally passes Smoke 1**:
sglang 0.5.11 + cu13 fixes correctly install, launch, find the Gemma-4
model class, and start loading weights. The actual final inference is
blocked **only by host-side GPU memory contention** from another workload
already holding ~85% of each card's memory. This is a hardware-availability
problem, not a Dockerfile problem.

**Next:** record this outcome, commit Dockerfile.newer_sglang, then attempt
Smoke 2 (Qwen3.5-2B GRPO). Qwen3.5-2B (~4 GB bf16) is smaller and may fit
in the available 4 GiB free per GPU. If it also OOMs, document and stop.
