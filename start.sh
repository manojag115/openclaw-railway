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

  # ---------------------------------------------------------------------------
  # Build openclaw.json via node — avoids trailing-comma / placeholder hacks
  # that break OpenClaw's strict JSON validator.
  # ---------------------------------------------------------------------------
  TOKEN="${TOKEN}" MODEL="${MODEL}" CONFIG_FILE="${CONFIG_FILE}" \
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
  DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}" \
  SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}" \
  SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}" \
  node -e "
    const cfg = {
      agents: { defaults: { model: { primary: process.env.MODEL || 'anthropic/claude-opus-4-5' } } },
      gateway: {
        mode: 'local',
        bind: 'lan',
        port: 18789,
        auth: { token: process.env.TOKEN },
        controlUi: {
          enabled: true,
          allowInsecureAuth: true,
          dangerouslyDisableDeviceAuth: true   // required in Docker — no device identity available (see openclaw #1679)
        }
      }
    };

    const ch = {};
    if (process.env.TELEGRAM_BOT_TOKEN)
      ch.telegram = { botToken: process.env.TELEGRAM_BOT_TOKEN, dmPolicy: 'pairing' };
    if (process.env.DISCORD_BOT_TOKEN)
      ch.discord  = { token: process.env.DISCORD_BOT_TOKEN, dm: { policy: 'pairing' } };
    if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN)
      ch.slack    = { botToken: process.env.SLACK_BOT_TOKEN, appToken: process.env.SLACK_APP_TOKEN, dm: { policy: 'pairing' } };

    if (Object.keys(ch).length) cfg.channels = ch;

    require('fs').writeFileSync(process.env.CONFIG_FILE, JSON.stringify(cfg, null, 2) + '\n');
    console.log('[openclaw-railway] wrote config ->', process.env.CONFIG_FILE);
  "
fi

# ---------------------------------------------------------------------------
# 4. Run doctor --fix to auto-migrate any legacy/stale config keys.
#    This is a no-op on a fresh config but saves us if openclaw ships another
#    schema change in the future.
# ---------------------------------------------------------------------------
openclaw doctor --fix 2>&1 || true

# ---------------------------------------------------------------------------
# 5. Healthcheck shim — Railway needs /health to return 200 *before* the
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
# 6. Print the Control UI URL (user grabs this from Railway deploy logs)
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
# 7. Export API keys so openclaw picks them up
# ---------------------------------------------------------------------------
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
if [ -n "${OPENAI_API_KEY}" ]; then
  export OPENAI_API_KEY="${OPENAI_API_KEY}"
fi

# ---------------------------------------------------------------------------
# 8. Boot the gateway  (exec replaces this shell — PID 1 is openclaw)
# ---------------------------------------------------------------------------
exec openclaw gateway --port 18789 --verbose