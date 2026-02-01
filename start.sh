#!/bin/sh
# ---------------------------------------------------------------------------
# start.sh — bootstrap OpenClaw on Railway
#
# Environment variables (set these in Railway's UI or .env):
#
#   REQUIRED
#   --------
#   ANTHROPIC_API_KEY      Your Anthropic API key
#
#   OPTIONAL — auth
#   ---------------
#   GATEWAY_TOKEN          Secret for the Control UI.  Auto-generated on first
#                          boot and persisted to /data/.gateway_token if blank.
#
#   OPTIONAL — model
#   ----------------
#   MODEL                  Model string, e.g. anthropic/claude-opus-4-5
#                          (default: anthropic/claude-opus-4-5)
#
#   OPTIONAL — channels (set any combination)
#   ------------------------------------------
#   TELEGRAM_BOT_TOKEN
#   DISCORD_BOT_TOKEN
#   SLACK_BOT_TOKEN
#   SLACK_APP_TOKEN        (required together with SLACK_BOT_TOKEN)
#
#   OPTIONAL — OpenAI (alternative / fallback provider)
#   ---------------------------------------------------
#   OPENAI_API_KEY
#
# ---------------------------------------------------------------------------
set -e

DATA_DIR="/data"
CONFIG_DIR="${HOME}/.openclaw"     # symlink → /data
CONFIG_FILE="${CONFIG_DIR}/openclaw.json"
TOKEN_FILE="${DATA_DIR}/.gateway_token"

# ---------------------------------------------------------------------------
# 1. Ensure data directory exists (first boot on a fresh volume)
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}"

# ---------------------------------------------------------------------------
# 2. Resolve gateway token
# ---------------------------------------------------------------------------
if [ -n "${GATEWAY_TOKEN}" ]; then
  TOKEN="${GATEWAY_TOKEN}"
elif [ -f "${TOKEN_FILE}" ]; then
  TOKEN=$(cat "${TOKEN_FILE}")
else
  # Generate a random 32-char hex token and persist it
  TOKEN=$(openssl rand -hex 16)
  echo "${TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. Write openclaw.json  (only if one doesn't already exist — lets users
#    hand-edit config on the volume and have it survive deploys)
# ---------------------------------------------------------------------------
if [ ! -f "${CONFIG_FILE}" ]; then
  mkdir -p "${CONFIG_DIR}"

  # Resolve model (default to Opus 4.5)
  MODEL_VALUE="${MODEL:-anthropic/claude-opus-4-5}"

  # ---------------------------------------------------------------------------
  # Build the JSON with a heredoc.  Channel blocks are conditionally appended
  # below.
  # ---------------------------------------------------------------------------
  cat > "${CONFIG_FILE}" <<EOF
{
  "agent": {
    "model": "${MODEL_VALUE}"
  },
  "gateway": {
    "bind": "0.0.0.0",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${TOKEN}"
    }
  },
  "channels": {
EOF

  # --- Telegram ----------------------------------------------------------
  if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
    cat >> "${CONFIG_FILE}" <<EOF
    "telegram": {
      "botToken": "${TELEGRAM_BOT_TOKEN}",
      "allowFrom": ["*"]
    },
EOF
  fi

  # --- Discord -----------------------------------------------------------
  if [ -n "${DISCORD_BOT_TOKEN}" ]; then
    cat >> "${CONFIG_FILE}" <<EOF
    "discord": {
      "token": "${DISCORD_BOT_TOKEN}",
      "dm": {
        "allowFrom": ["*"]
      }
    },
EOF
  fi

  # --- Slack -------------------------------------------------------------
  if [ -n "${SLACK_BOT_TOKEN}" ] && [ -n "${SLACK_APP_TOKEN}" ]; then
    cat >> "${CONFIG_FILE}" <<EOF
    "slack": {
      "botToken": "${SLACK_BOT_TOKEN}",
      "appToken": "${SLACK_APP_TOKEN}"
    },
EOF
  fi

  # Close channels (strip trailing comma via a dummy empty object trick isn't
  # great JSON — we use a _placeholder that we'll clean up)
  cat >> "${CONFIG_FILE}" <<EOF
    "_": null
  }
}
EOF
fi

# ---------------------------------------------------------------------------
# 4. Healthcheck shim — Railway needs /health to return 200 *before* the
#    gateway is fully warm.  We run a tiny node one-liner in the background
#    that answers 200 on /health and proxies everything else to the gateway
#    once it's up.  This shim exits as soon as the gateway starts listening
#    (gateway itself then handles /health natively).
# ---------------------------------------------------------------------------
node -e "
const http = require('http');
const net  = require('net');

const PORT = 18789;

function gatewayUp(cb) {
  const s = net.createConnection({ host: '127.0.0.1', port: PORT }, () => {
    s.destroy();
    cb();
  });
  s.on('error', () => {
    setTimeout(() => gatewayUp(cb), 500);
  });
}

// Start a temp server that only answers /health until gateway is ready.
// We bind to 0.0.0.0 but will close as soon as openclaw takes over.
const tmp = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200);
    res.end('ok');
  } else {
    res.writeHead(503);
    res.end('starting…');
  }
});

// Try to bind — if gateway already owns the port we just exit silently.
tmp.listen(PORT, '0.0.0.0', () => {
  console.log('[openclaw-railway] healthcheck shim listening on', PORT);
  gatewayUp(() => {
    console.log('[openclaw-railway] gateway is up — closing healthcheck shim');
    tmp.close();
  });
});

tmp.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.log('[openclaw-railway] port already in use — gateway likely up, skipping shim');
  }
});
" &
SHIM_PID=$!

# ---------------------------------------------------------------------------
# 5. Print the Control UI URL (user grabs this from Railway deploy logs)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  OpenClaw on Railway"
echo "============================================================"
echo "  Gateway token : ${TOKEN}"
echo ""
echo "  Once Railway assigns a domain, your Control UI will be at:"
echo ""
echo "    https://<your-domain>/?token=${TOKEN}"
echo ""
echo "  If you set GATEWAY_TOKEN as a Railway env var, you can"
echo "  change it at any time — the value in the env var always wins."
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# 6. Export API keys so openclaw picks them up
# ---------------------------------------------------------------------------
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
if [ -n "${OPENAI_API_KEY}" ]; then
  export OPENAI_API_KEY="${OPENAI_API_KEY}"
fi

# ---------------------------------------------------------------------------
# 7. Boot the gateway  (exec replaces this shell — PID 1 is openclaw)
# ---------------------------------------------------------------------------
exec openclaw gateway --port 18789 --bind 0.0.0.0 --verbose
