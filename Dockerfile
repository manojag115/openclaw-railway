# openclaw-railway — run OpenClaw on Railway
# Based on the image openclaw itself recommends for container deploys.

FROM node:22-bookworm AS base

# ---------------------------------------------------------------------------
# 1. Global install of openclaw (pulls the latest stable release)
# ---------------------------------------------------------------------------
RUN npm install -g openclaw@latest

# ---------------------------------------------------------------------------
# 2. Persistent data directory (mount a Railway volume here)
#    OpenClaw stores sessions, credentials, and config under ~/.openclaw.
#    We symlink that to /data so a Railway persistent volume survives deploys.
# ---------------------------------------------------------------------------
ENV HOME=/root
RUN mkdir -p /data && ln -sf /data /root/.openclaw

# ---------------------------------------------------------------------------
# 3. Copy in our startup script (generates config + boots gateway)
# ---------------------------------------------------------------------------
COPY start.sh /start.sh
RUN chmod +x /start.sh

# ---------------------------------------------------------------------------
# 4. Expose the gateway port Railway will route to.
#    The healthcheck wrapper also listens here (see start.sh).
# ---------------------------------------------------------------------------
EXPOSE 18789

# ---------------------------------------------------------------------------
# 5. Run
# ---------------------------------------------------------------------------
CMD ["/start.sh"]
