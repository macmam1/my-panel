# syntax=docker/dockerfile:1
#
# vpn-panel — image for free PaaS platforms that only allow "deploy from GitHub".
#
# One public HTTPS port is multiplexed by Caddy into:
#   /j/*      -> JupyterLab   (terminal + notebook for the owner)
#   /vless/*  -> xray-core    (VLESS over WebSocket)
#   /panel/*  -> custom panel (stage 2)
#
# Nothing here is a secret: every credential is generated on first boot into
# /app/state, so the image can stay public without leaking anything.

FROM python:3.12-slim-bookworm

ARG XRAY_VERSION=v26.3.27
ARG CADDY_VERSION=2.11.6

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    XRAY_DIR=/opt/xray \
    XRAY_CONFIG=/app/state/config.json \
    STATE_DIR=/app/state \
    CADDYFILE=/etc/caddy/Caddyfile \
    TZ=Asia/Tehran

# build-essential + python3-dev are deliberate: the whole point is that the
# owner can `pip install` / `apt install` anything from the Jupyter terminal.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip tzdata procps iproute2 iputils-ping netcat-openbsd \
        build-essential python3-dev git \
    && rm -rf /var/lib/apt/lists/*

# xray-core
RUN curl -fsSL -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
    && mkdir -p "${XRAY_DIR}" \
    && unzip -q /tmp/xray.zip -d "${XRAY_DIR}" \
    && chmod +x "${XRAY_DIR}/xray" \
    && rm -f /tmp/xray.zip

# caddy (note: release asset name has no "v" prefix, unlike the tag)
RUN curl -fsSL -o /tmp/caddy.tar.gz \
        "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy \
    && chmod +x /usr/local/bin/caddy \
    && rm -f /tmp/caddy.tar.gz

# JupyterLab + the bits an agent will want later
RUN pip install --no-cache-dir \
        jupyterlab ipykernel requests \
    && jupyter server extension enable --py jupyterlab --sys-prefix

WORKDIR /app
COPY entrypoint.sh /entrypoint.sh
COPY Caddyfile /etc/caddy/Caddyfile
RUN chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/entrypoint.sh"]