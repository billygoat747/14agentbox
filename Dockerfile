FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Core system utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    socat \
    sudo \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Configure Git safe.directory system-wide so bind-mounted repositories
# under /workspace do not encounter UID ownership mismatch errors
RUN git config --system --add safe.directory '*'

# OpenCode agent system-wide
RUN curl -fsSL https://opencode.ai/install | bash \
    && cp /root/.opencode/bin/opencode /usr/local/bin/opencode \
    && chmod 755 /usr/local/bin/opencode \
    && rm -rf /root/.opencode \
    && opencode --version

# Antigravity CLI (agy / antigravity) system-wide with YOLO mode wrapper
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin \
    && mv /usr/local/bin/agy /usr/local/bin/agy-bin \
    && (test -e /usr/local/bin/antigravity && rm -f /usr/local/bin/antigravity || true) \
    && chmod 755 /usr/local/bin/agy-bin
COPY docker/agy-wrapper.sh /usr/local/bin/agy
RUN sed -i 's/\r$//' /usr/local/bin/agy \
    && chmod 755 /usr/local/bin/agy \
    && ln -s /usr/local/bin/agy /usr/local/bin/antigravity \
    && agy --version

# Non-root developer user with passwordless sudo (UID 1000)
RUN if id -u ubuntu >/dev/null 2>&1; then \
        usermod -l dev ubuntu && groupmod -n dev ubuntu && usermod -d /home/dev -m dev; \
    else \
        useradd -m -s /bin/bash -u 1000 dev; \
    fi \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/dev \
    && chmod 0440 /etc/sudoers.d/dev \
    && mkdir -p /home/dev/.config/opencode /home/dev/.gemini/config /home/dev/.gemini/antigravity-cli /workspace \
    && chown -R dev:dev /home/dev /workspace

# Copy default OpenCode configuration into image
COPY --chown=dev:dev opencode.json /home/dev/.config/opencode/opencode.json

# Copy container entrypoint
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

USER dev
WORKDIR /workspace

ENV HOME=/home/dev \
    ANTIGRAVITY_YOLO=1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/bin/bash"]
