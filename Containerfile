FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    python3 \
    build-essential \
    ca-certificates \
    openssh-client \
  && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends sudo \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -m -s /bin/bash claude \
  && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
USER claude

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
