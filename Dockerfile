FROM slimerl/slime:latest

# UTF-8 locale so tmux and Neovim draw box-drawing characters correctly
ENV LANG=C.UTF-8

# Dev tooling missing from the slime base. Pre-installed there: curl, less,
# tree, wget, gpg, ssh, gcc, git, uv, wandb, torch, sglang.
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
  build-essential \
  ca-certificates \
  gnupg \
  jq \
  ripgrep \
  unzip \
  && rm -rf /var/lib/apt/lists/*

# Node.js 22 via NodeSource — needed for the npm-installed CLIs below
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y -qq --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Azure CLI — lets AzureCliCredential() work inside the container when the
# host's ~/.azure is bind-mounted in (see ai-sandbox.sh). Required for TRAPI
# (MSR's OAuth-gated Azure OpenAI gateway, api://trapi/.default).
# Microsoft's apt repo only ships amd64; on arm64 (e.g. M-series Macs, Win-on-ARM
# WSL) fall back to pip per Microsoft's official ARM64 install guidance.
RUN ARCH="$(dpkg --print-architecture)" \
  && if [ "$ARCH" = "amd64" ]; then \
       install -m 0755 -d /etc/apt/keyrings \
       && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
       && chmod a+r /etc/apt/keyrings/microsoft.gpg \
       && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(. /etc/os-release && echo $VERSION_CODENAME) main" \
            > /etc/apt/sources.list.d/azure-cli.list \
       && apt-get update -qq \
       && apt-get install -y -qq --no-install-recommends azure-cli \
       && rm -rf /var/lib/apt/lists/*; \
     else \
       pip install --no-cache-dir --break-system-packages azure-cli; \
     fi

# Docker CLI — for sibling-container workflows (--docker-sock / SANDBOX_DOCKER_SOCK=1).
# Installs only docker-ce-cli (no daemon); the host socket is bind-mounted at runtime.
# Docker's apt repo supports both amd64 and arm64.
RUN install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
  && chmod a+r /etc/apt/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
       > /etc/apt/sources.list.d/docker.list \
  && apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends docker-ce-cli \
  && rm -rf /var/lib/apt/lists/*

# Non-root user (uid 1000) for Claude's --dangerously-skip-permissions
RUN if getent passwd 1000 >/dev/null; then \
      usermod -l sandbox -d /home/sandbox -m $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true; \
    else \
      groupadd -g 1000 sandbox && useradd -m -u 1000 -g sandbox sandbox; \
    fi

RUN npm install -g @google/gemini-cli @openai/codex @github/copilot \
  && npm cache clean --force

# Claude Code — install via official script to a world-readable prefix so the
# non-root sandbox user can execute it (the default /root prefix is mode 700).
RUN HOME=/opt/claude-cli curl -fsSL https://claude.ai/install.sh | HOME=/opt/claude-cli bash \
  && chmod -R a+rX /opt/claude-cli \
  && ln -sf /opt/claude-cli/.local/bin/claude /usr/local/bin/claude

# Install clbench third-party deps directly into the slime base's system Python
# (no .venv anywhere). UV_PROJECT_ENVIRONMENT=/usr is uv's documented "install
# to system Python instead of a venv" knob; --inexact preserves the slime
# base's preinstalled torch/sglang/megatron stack instead of removing them
# as "extraneous". UV_BREAK_SYSTEM_PACKAGES=1 lets uv write past Ubuntu's
# EXTERNALLY-MANAGED marker.
ENV UV_PROJECT_ENVIRONMENT=/usr \
    UV_SYSTEM_PYTHON=1 \
    UV_BREAK_SYSTEM_PACKAGES=1

# Build-time dep prebuild: COPY pyproject.toml only and run a minimal-project
# uv sync. The src/ + README.md stubs satisfy setuptools/uv project-discovery
# without pulling in the real source (which lands at /workspace via bind
# mount). The project itself is wired up editably at runtime.
COPY pyproject.toml /tmp/clbench-build/pyproject.toml
RUN cd /tmp/clbench-build \
 && : > README.md \
 && mkdir -p src && : > src/__init__.py \
 && uv sync --all-extras --inexact --no-install-project \
 && rm -rf /tmp/clbench-build

# Entrypoint: register /workspace as an editable install on container start so
# `clbench` resolves and src/ edits are live, then exec the user's command.
# The user never has to touch uv or activate anything.
COPY --chmod=0755 <<'EOF' /usr/local/bin/clbench-entrypoint.sh
#!/usr/bin/env bash
set -e
if [ -f /workspace/pyproject.toml ]; then
  uv pip install --quiet --no-deps -e /workspace \
    || echo "warning: editable install of /workspace failed; clbench may be unavailable" >&2
fi
if [ "$#" -eq 0 ]; then
  exec bash
fi
exec "$@"
EOF

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/clbench-entrypoint.sh"]
CMD ["bash"]

# Runtime env contract for clbench:
#
#   /workspace/.env must define:
#     OPENAI_API_KEY    — placeholder accepted by the openai/litellm SDKs
#     OPENAI_BASE_URL   — custom OAI-compatible proxy URL (no /v1 suffix
#                         issues; litellm honours this verbatim)
#     X_API_KEY         — proxy gateway key. src/vendors/oai_proxy.py
#                         injects this into extra_headers["X-API-Key"]
#                         on every litellm.{,a}completion call.
#
# Without X_API_KEY, the proxy 403s "Invalid API Key" regardless of the
# bearer token. See progress/plan_oai_wiring.md for the full rationale.
