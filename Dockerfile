FROM ubuntu:24.04

# UTF-8 locale so tmux and Neovim draw box-drawing characters correctly
ENV LANG=C.UTF-8

# Build tools, common utilities, and agent dependencies
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  gnupg \
  jq \
  less \
  openssh-client \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep \
  tree \
  unzip \
  wget \
  && rm -rf /var/lib/apt/lists/*

# Node.js 22 via NodeSource
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
# ubuntu:24.04 ships with a 'ubuntu' user at uid 1000; reuse it or create fresh.
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

# W&B (Weights & Biases) — pre-install so training scripts can log metrics
RUN pip install --no-cache-dir --break-system-packages wandb
