# SP1: VPS Infrastructure — Design Spec

**Status:** Approved
**Date:** 2026-05-15
**Parent:** `docs/superpowers/specs/2026-05-15-discord-bot-master-design.md`
**Manifest:** `docs/superpowers/discord-bot-manifest.md`

## Goal

Provision a hardened Hetzner CX22 VPS with Docker Compose, automated CI/CD, and uptime monitoring. The server hosts no application logic — it exists solely as the deployment target for SP2 (Discord Bot Core).

## Repo

The Discord bot lives in its own repo: `C:\Users\ryand\Feeder-Extension\Gemini-discord-bot` (GitHub: `Gemini-discord-bot`). This keeps it isolated from the Gemini-server data pipeline with its own CI/CD, TypeScript config, and Claude Code optimization (CLAUDE.md, rules, settings).

### Project Tooling
- TypeScript 5.x (strict mode, `noUncheckedIndexedAccess`)
- ESLint 9 (flat config, typescript-eslint strict)
- Prettier
- vitest (unit tests, coverage via v8)
- CI workflow gates PRs on: typecheck + lint + format check + test
- CLAUDE.md + `.claude/rules/core.md` for Claude Code session context

## Server Specification

| Property | Value |
|----------|-------|
| Provider | Hetzner Cloud |
| Plan | CX22 |
| Resources | 2 vCPU, 4 GB RAM, 40 GB NVMe |
| OS | Ubuntu 24.04 LTS |
| Region | US East (Ashburn, `ash`) |
| Cost | ~$3.60/mo |

## Security Hardening

All hardening is applied during initial provisioning.

### SSH
- Key-only authentication (password login disabled)
- Root login disabled; dedicated deploy user (`deploy`) with sudo
- SSH port remains 22 (changing ports is security theater; fail2ban handles brute force)

### Firewall (UFW)
- Default deny incoming
- Allow: SSH (22), HTTP (80), HTTPS (443)
- All other ports closed

### Intrusion Prevention
- `fail2ban` with default SSH jail (ban after 5 failures, 10-minute ban)

### Auto-Updates
- `unattended-upgrades` enabled for security patches only
- Auto-reboot disabled (manual reboot after kernel updates)

## Process Management: Docker Compose

### Why Docker
- Reproducible builds via image tags — every deploy is a known-good snapshot
- Rollback = `docker compose pull` a previous tag
- Isolates the bot process from the host OS
- ~200 MB RAM overhead is negligible on 4 GB

### Container Layout

Single service in `docker-compose.yml`:

```yaml
services:
  bot:
    image: ghcr.io/<owner>/gemini-discord-bot:latest
    restart: unless-stopped
    env_file: .env
    ports:
      - "3000:3000"  # health check endpoint
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

### Dockerfile (SP1 placeholder)

SP1 ships a minimal placeholder that serves `/health`. SP2 replaces it with the real bot.

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY . .
EXPOSE 3000
CMD ["node", "src/health.js"]
```

The placeholder `src/health.js` is a ~15-line HTTP server returning `{ ok: true, uptime: process.uptime() }` on GET `/health`.

## CI/CD: GitHub Actions Auto-Deploy

### Trigger
Push to `main` branch (filtered to bot-relevant paths to avoid deploying on unrelated changes).

### Workflow Steps

1. **Build** — `docker build` + tag with commit SHA and `latest`
2. **Push** — Push image to GitHub Container Registry (GHCR)
3. **Deploy** — SSH into VPS, run `docker compose pull && docker compose up -d`
4. **Verify** — Curl the `/health` endpoint to confirm the new container is running

### GitHub Actions Secrets Required

| Secret | Purpose |
|--------|---------|
| `VPS_HOST` | VPS IP or hostname |
| `VPS_USER` | SSH user (`deploy`) |
| `VPS_SSH_KEY` | Private key for SSH (ed25519) |

### Deploy Script on VPS

A small `deploy.sh` at `/home/deploy/bot/deploy.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/deploy/bot
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```

GitHub Actions SSHs in and runs this script. Keeps deploy logic on the server rather than inlined in the workflow YAML.

## Secrets Management

### On the VPS
`.env` file at `/home/deploy/bot/.env`, readable only by the `deploy` user:

```
DISCORD_TOKEN=<bot token from Discord Developer Portal>
SUPABASE_URL=<project URL>
SUPABASE_SERVICE_ROLE_KEY=<service role key>
```

This file is created once via SSH. It is never committed, never deployed, and never overwritten by CI/CD. Docker Compose reads it via `env_file: .env`.

### File permissions
```bash
chmod 600 /home/deploy/bot/.env
chown deploy:deploy /home/deploy/bot/.env
```

## Monitoring

### Layer 1: Docker Auto-Restart
`restart: unless-stopped` in Docker Compose. If the process crashes, Docker restarts it immediately. The health check marks the container unhealthy after 3 consecutive failures.

### Layer 2: External Uptime Ping
- Service: UptimeRobot (free tier, 5-minute interval) or Healthchecks.io
- Target: `http://<vps-ip>:3000/health` (or `https://bot.yourdomain.com/health` if DNS is configured)
- Alert channel: Discord webhook to a private monitoring channel in your server
- Alert condition: 2 consecutive failures (10 minutes of downtime)

### Health Check Response
```json
{
  "ok": true,
  "uptime": 123456.789,
  "version": "1.0.0"
}
```

SP2 will extend this with bot-specific health data (Gateway connection status, last heartbeat ACK, guild count).

## DNS and TLS (Optional)

### DNS
- Add an A record: `bot.yourdomain.com` → VPS IP
- TTL: 300s (5 minutes)
- Done in your domain registrar's DNS panel — no VPS-side config needed for this step

### Reverse Proxy (Caddy)
If DNS is configured, add Caddy as a second Docker Compose service for automatic TLS:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

```
# Caddyfile
bot.yourdomain.com {
    reverse_proxy bot:3000
}
```

Caddy handles Let's Encrypt certificate provisioning and renewal automatically. When Caddy is present, remove the bot's `ports: - "3000:3000"` mapping from `docker-compose.yml` — Caddy reaches the bot via Docker's internal network, and port 3000 is never exposed to the internet.

If DNS is not configured, skip Caddy entirely. The bot container exposes port 3000 directly and the health check uses the raw IP (`http://<vps-ip>:3000/health`).

## Directory Structure on VPS

```
/home/deploy/bot/
├── docker-compose.yml
├── .env                 # secrets (created once, never deployed)
├── deploy.sh            # called by CI/CD
├── Caddyfile            # optional, only if DNS is configured
```

The Docker image contains the application code. No source code lives on the VPS filesystem.

## Deliverables Checklist

1. Hetzner CX22 provisioned (Ubuntu 24.04, US East)
2. Security hardened (SSH keys, fail2ban, UFW, unattended-upgrades)
3. `deploy` user created with Docker permissions
4. Docker + Docker Compose installed
5. `docker-compose.yml` with placeholder health check service
6. GitHub Actions workflow: build → push GHCR → SSH deploy
7. `.env` file template documented (user creates manually on VPS)
8. UptimeRobot or equivalent monitoring configured
9. Discord webhook for downtime alerts
10. Optional: DNS A record + Caddy reverse proxy with TLS

## What SP1 Does NOT Include

- Discord bot code or Gateway connection (SP2)
- Supabase queries or data formatting (SP3)
- Alert/notification logic (SP4)
- Summary/analytics features (SP5)
- Any changes to existing Supabase edge functions or GitHub Actions workflows

## Out of Scope Decisions Captured for Later

- **Role-based mention alerts** (user wants `@Starweaver` role pings when items restock) — SP4 will handle this. SP2 bot core needs `Manage Roles` intent noted.
- **Sharding** — not needed until 2,500+ servers. SP2 will architect for it but not implement.
