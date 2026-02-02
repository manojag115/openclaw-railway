# openclaw-railway

> **Run [OpenClaw](https://github.com/openclaw/openclaw) on [Railway](https://railway.com)** — a one-click, persistent, always-on deployment for your personal AI assistant.

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/openclaw)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/manojag115/openclaw-railway/actions/workflows/ci.yml/badge.svg)](https://github.com/manojag115/openclaw-railway/actions/workflows/ci.yml)

---

## What this is

OpenClaw is a personal AI assistant that runs a gateway you talk to through WhatsApp, Telegram, Discord, Slack, and more. This repo packages it into a Docker image that Railway can build and run with **zero configuration beyond an API key**. It's the Railway equivalent of what [moltworker](https://github.com/cloudflare/moltworker) does for Cloudflare Workers.

Key differences from running OpenClaw on a Mac mini or a bare VPS:

- **One-click deploy** — no SSH, no systemd, no manual Docker commands.
- **Persistent volume** — sessions, paired devices, and conversation history survive deploys. Mounted automatically at `/data`.
- **Auto-restart** — Railway restarts the container on crash; no supervisord needed.
- **Healthcheck shim** — a lightweight HTTP shim answers `/health` during the OpenClaw warm-up window so Railway doesn't kill the container on cold start.

---

## Prerequisites

| What | Why |
|---|---|
| [Railway account](https://railway.com) | Hosts the container. Free tier works for dev; paid ($5/mo) for production. |
| [Anthropic API key](https://console.anthropic.com) | OpenClaw needs this to reach Claude. |

That's it. No Cloudflare account, no VPS, no local Docker required (unless you want to test locally — see below).

---

## Deploy to Railway (30 seconds)

1. Click the **Deploy on Railway** button above (or use the direct URL: `https://railway.app/template/openclaw`).
2. Set `ANTHROPIC_API_KEY` in the environment variables panel.
3. Click **Deploy**.
4. Wait for the build to finish (30–60 s). Railway will assign a `.up.railway.app` domain.
5. **Grab your token.** Open the deploy logs and look for the block that starts with `OpenClaw on Railway`. Copy the token value.
6. Open your Control UI:

   ```
   https://<your-domain>/?token=<your-token>
   ```

Done. You now have a persistent, always-on OpenClaw instance.

---

## Environment variables

Set these in Railway's **Variables** tab for your service.

### Required

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Your Anthropic API key (`sk-ant-…`). |

### Auth

| Variable | Default | Description |
|---|---|---|
| `GATEWAY_TOKEN` | *(auto-generated)* | Secret appended as `?token=…` to access the Control UI. If you leave this blank, a random token is generated on first boot, persisted to the volume, and printed to deploy logs. Set it explicitly if you want a stable value you can share or rotate. |

### Model

| Variable | Default | Description |
|---|---|---|
| `MODEL` | `anthropic/claude-opus-4-5` | The model string OpenClaw passes to the provider. Any model supported by your configured provider works here. |

### Channels (all optional — add whichever you use)

| Variable | Notes |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Create a bot via [@BotFather](https://t.me/BotFather). |
| `DISCORD_BOT_TOKEN` | From the [Discord Developer Portal](https://discord.com/developers/applications). |
| `SLACK_BOT_TOKEN` | From your Slack app's OAuth page (`xoxb-…`). |
| `SLACK_APP_TOKEN` | Required alongside `SLACK_BOT_TOKEN` (`xapp-…`). |

### Alternative providers

| Variable | Notes |
|---|---|
| `OPENAI_API_KEY` | If you want OpenAI as a fallback or primary provider, set `MODEL` to an OpenAI model string (e.g. `openai/gpt-4o`). |

---

## Persistent storage

Railway gives every service a **persistent volume** you can mount. For this template, mount it at `/data`. Everything OpenClaw writes (sessions, credentials, config) lives there via a symlink from `~/.openclaw → /data`.

To enable the volume in Railway:

1. Go to your service → **Settings** → **Volumes**.
2. Add a volume and mount it at `/data`.

Without a volume, the container still works — it just loses state on restart. For anything beyond quick testing, add the volume.

---

## Local development

If you want to test before deploying:

```bash
cp .env.example .env
# Edit .env — at minimum set ANTHROPIC_API_KEY

docker compose up --build
```

The Control UI will be at `http://localhost:18789/?token=<token>`. The token is printed to the container logs on first boot (or check `./data/.gateway_token` after the first run).

---

## How it works (architecture)

```
Railway Router
      │  HTTPS + WebSocket
      ▼
┌─────────────────────────────┐
│   Docker container          │
│                             │
│  start.sh                   │
│    ├─ writes openclaw.json  │  ← config generated from env vars
│    ├─ spawns healthcheck    │  ← tiny HTTP shim on :18789 until
│    │   shim (node)          │     openclaw is ready
│    └─ exec openclaw gateway │  ← PID 1, binds 0.0.0.0:18789
│                             │
│  /data  (persistent volume) │  ← sessions, creds, config
└─────────────────────────────┘
```

The healthcheck shim is the main reason this "just works" on Railway. OpenClaw's gateway takes a few seconds to warm up after the process starts. Railway's healthcheck fires immediately — without the shim, it would get a connection refused, mark the deploy as failed, and restart the container in a loop. The shim answers `200 OK` on `/health` during that window, then exits cleanly once OpenClaw takes over the port.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Deploy loops / never becomes healthy | Railway can't reach `/health` on port 18789 | Check that you haven't overridden the port. The container must expose 18789. |
| Control UI loads but WebSocket disconnects immediately | Binding issue — gateway is on 127.0.0.1 | This shouldn't happen with this template (we force `0.0.0.0`), but if you edited `openclaw.json` manually, ensure `gateway.bind` is `"0.0.0.0"`. |
| "Token invalid" on Control UI | Wrong token in the URL | Check deploy logs for the correct token, or read `/data/.gateway_token` from a Railway shell. |
| Channels not responding | Bot token is wrong or bot lacks permissions | Verify your bot tokens in the respective platform's developer portal. |
| Config changes not taking effect | OpenClaw only reads `openclaw.json` on startup | Delete `/data/openclaw.json` (or edit it) and restart the service in Railway. |
| State lost after deploy | No persistent volume mounted | Mount a volume at `/data` — see [Persistent storage](#persistent-storage) above. |

---

## License

MIT — same as OpenClaw itself.
