# SP1: VPS Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a hardened Hetzner CX22 VPS with Docker Compose, GitHub Actions auto-deploy, and uptime monitoring — ready for SP2 to deploy the Discord bot onto.

**Architecture:** Hetzner CX22 (Ubuntu 24.04, US East) runs a single Docker Compose service behind an optional Caddy reverse proxy. GitHub Actions builds a Docker image on push to main, pushes to GHCR, and SSHs into the VPS to pull and restart. UptimeRobot pings the `/health` endpoint and alerts via Discord webhook on failure.

**Tech Stack:** Hetzner Cloud, Ubuntu 24.04 LTS, Docker + Docker Compose, GitHub Actions, GitHub Container Registry (GHCR), Caddy (optional), UptimeRobot (free tier)

**Spec:** `docs/superpowers/specs/2026-05-15-sp1-vps-infrastructure-design.md`

---

## File Structure

These files will be created in the Gemini-server repo:

| File | Responsibility |
|------|---------------|
| `bot/Dockerfile` | Multi-stage Node.js 20 image for the bot process |
| `bot/package.json` | Bot dependencies (just `express` for the SP1 placeholder) |
| `bot/src/health.js` | Placeholder HTTP server serving `/health` |
| `bot/docker-compose.yml` | Single-service compose file with health check |
| `bot/Caddyfile` | Optional Caddy reverse proxy config (TLS) |
| `bot/.env.example` | Documented env var template (never contains real secrets) |
| `bot/deploy.sh` | Deploy script called by CI/CD on the VPS |
| `.github/workflows/deploy-bot.yml` | Build → push GHCR → SSH deploy workflow |
| `docs/superpowers/plans/2026-05-15-sp1-vps-infrastructure.md` | This plan |

All bot files live under `bot/` to keep them separate from the existing data pipeline code in the repo root.

---

### Task 1: Create Placeholder Health Check Server

**Files:**
- Create: `bot/package.json`
- Create: `bot/src/health.js`

- [ ] **Step 1: Create `bot/package.json`**

```json
{
  "name": "gemini-discord-bot",
  "version": "0.1.0",
  "description": "Discord bot for MagicGarden restock tracking",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/health.js"
  },
  "dependencies": {
    "express": "^4.21.0"
  }
}
```

- [ ] **Step 2: Create `bot/src/health.js`**

```js
import express from 'express';

const app = express();
const PORT = process.env.PORT || 3000;
const startTime = Date.now();

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    uptime: Math.floor((Date.now() - startTime) / 1000),
    version: process.env.npm_package_version || '0.1.0',
  });
});

app.listen(PORT, () => {
  console.log(`Health check listening on port ${PORT}`);
});
```

- [ ] **Step 3: Test locally**

Run:
```bash
cd bot && npm install && npm start
```

In another terminal:
```bash
curl http://localhost:3000/health
```

Expected: `{"ok":true,"uptime":1,"version":"0.1.0"}`

Kill the server with Ctrl+C.

- [ ] **Step 4: Commit**

```bash
git add bot/package.json bot/src/health.js
git commit -m "feat(bot): add placeholder health check server for SP1"
```

---

### Task 2: Create Dockerfile and Docker Compose

**Files:**
- Create: `bot/Dockerfile`
- Create: `bot/docker-compose.yml`
- Create: `bot/.dockerignore`

- [ ] **Step 1: Create `bot/.dockerignore`**

```
node_modules
npm-debug.log
.env
```

- [ ] **Step 2: Create `bot/Dockerfile`**

```dockerfile
FROM node:20-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --production

FROM node:20-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package*.json ./
COPY src ./src
EXPOSE 3000
USER node
CMD ["node", "src/health.js"]
```

Note: `curl` is installed for Docker's health check probe. The `USER node` directive runs the process as non-root inside the container.

- [ ] **Step 3: Create `bot/docker-compose.yml`**

```yaml
services:
  bot:
    build: .
    image: ghcr.io/ryandt2305-cpu/gemini-discord-bot:latest
    restart: unless-stopped
    env_file: .env
    ports:
      - "3000:3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

- [ ] **Step 4: Build and test locally**

Run:
```bash
cd bot && docker compose build && docker compose up -d
```

Wait 10 seconds for the container to start, then:
```bash
curl http://localhost:3000/health
docker compose ps
```

Expected: `/health` returns `{"ok":true,...}` and `docker compose ps` shows the bot as `healthy`.

```bash
docker compose down
```

- [ ] **Step 5: Commit**

```bash
git add bot/Dockerfile bot/docker-compose.yml bot/.dockerignore
git commit -m "feat(bot): add Dockerfile and Docker Compose config"
```

---

### Task 3: Create .env.example and Deploy Script

**Files:**
- Create: `bot/.env.example`
- Create: `bot/deploy.sh`

- [ ] **Step 1: Create `bot/.env.example`**

```bash
# Discord bot token from https://discord.com/developers/applications
DISCORD_TOKEN=

# Supabase project URL (https://<project-ref>.supabase.co)
SUPABASE_URL=

# Supabase service role key (Settings → API → service_role)
SUPABASE_SERVICE_ROLE_KEY=
```

- [ ] **Step 2: Create `bot/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd /home/deploy/bot

echo "Pulling latest image..."
docker compose pull

echo "Starting updated container..."
docker compose up -d --remove-orphans

echo "Pruning old images..."
docker image prune -f

echo "Verifying health..."
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/health)
if [ "$HTTP_CODE" != "200" ]; then
  echo "WARN: Health check returned HTTP $HTTP_CODE"
  docker compose logs --tail=20
  exit 1
fi
echo "Deploy complete. Health check: HTTP $HTTP_CODE"
```

- [ ] **Step 3: Commit**

```bash
git add bot/.env.example bot/deploy.sh
git commit -m "feat(bot): add env template and deploy script"
```

---

### Task 4: Create GitHub Actions Deploy Workflow

**Files:**
- Create: `.github/workflows/deploy-bot.yml`

- [ ] **Step 1: Create `.github/workflows/deploy-bot.yml`**

```yaml
name: Deploy Discord Bot

on:
  push:
    branches: [main]
    paths:
      - 'bot/**'
      - '.github/workflows/deploy-bot.yml'
  workflow_dispatch:

concurrency:
  group: deploy-bot
  cancel-in-progress: false

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/gemini-discord-bot

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: bot
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}

      - name: Deploy to VPS
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          script: bash /home/deploy/bot/deploy.sh
```

- [ ] **Step 2: Verify workflow syntax**

Run:
```bash
cd "C:\Users\ryand\Feeder-Extension\Gemini-folder\Gemini-server"
cat .github/workflows/deploy-bot.yml | head -5
```

Expected: File exists and starts with `name: Deploy Discord Bot`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-bot.yml
git commit -m "feat(bot): add GitHub Actions deploy workflow (build → GHCR → SSH)"
```

---

### Task 5: Create Optional Caddy Config

**Files:**
- Create: `bot/Caddyfile`

- [ ] **Step 1: Create `bot/Caddyfile`**

```
# Replace bot.yourdomain.com with your actual subdomain.
# Only used when DNS is configured. See docker-compose.yml
# comments for how to enable the Caddy service.
bot.yourdomain.com {
    reverse_proxy bot:3000
}
```

- [ ] **Step 2: Add Caddy service as a commented block in `bot/docker-compose.yml`**

Append to the end of `bot/docker-compose.yml`:

```yaml

  # Uncomment to enable Caddy reverse proxy with automatic TLS.
  # Requires: DNS A record pointing bot.yourdomain.com to this VPS IP.
  # When enabled, remove the `ports` section from the bot service above.
  #
  # caddy:
  #   image: caddy:2-alpine
  #   restart: unless-stopped
  #   ports:
  #     - "80:80"
  #     - "443:443"
  #   volumes:
  #     - ./Caddyfile:/etc/caddy/Caddyfile:ro
  #     - caddy_data:/data
  #     - caddy_config:/config
  #
  # volumes:
  #   caddy_data:
  #   caddy_config:
```

- [ ] **Step 3: Commit**

```bash
git add bot/Caddyfile bot/docker-compose.yml
git commit -m "feat(bot): add optional Caddy reverse proxy config"
```

---

### Task 6: Provision Hetzner CX22 and Harden

This task is manual — it happens in the Hetzner Cloud console and via SSH. The steps below are the exact commands to run.

**Prerequisites:** Hetzner Cloud account, an SSH key pair on your local machine (`~/.ssh/id_ed25519` or similar).

- [ ] **Step 1: Create the server in Hetzner Cloud Console**

1. Go to https://console.hetzner.cloud
2. Create a new project (or use an existing one)
3. Add your SSH public key under **Security → SSH Keys**
4. Create server:
   - **Location:** Ashburn (US East)
   - **Image:** Ubuntu 24.04
   - **Type:** CX22 (2 vCPU, 4 GB RAM, 40 GB)
   - **SSH key:** Select your key
   - **Name:** `gemini-bot`
5. Note the IP address

- [ ] **Step 2: SSH in and create the deploy user**

```bash
ssh root@<VPS_IP>

# Create deploy user with sudo
adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy

# Allow deploy user to sudo without password (for initial setup only)
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy

# Copy SSH authorized_keys to deploy user
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

- [ ] **Step 3: Harden SSH**

```bash
# Still as root on the VPS
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

Verify you can still SSH in as `deploy` from a new terminal before closing the root session:
```bash
ssh deploy@<VPS_IP>
```

- [ ] **Step 4: Install fail2ban and UFW**

```bash
# As deploy user
sudo apt update && sudo apt install -y fail2ban ufw

# Configure UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

# fail2ban starts automatically with default SSH jail
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

- [ ] **Step 5: Enable unattended-upgrades**

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
# Select "Yes" when prompted
```

Verify:
```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
```

Expected output includes:
```
APT::Periodic::Unattended-Upgrade "1";
```

- [ ] **Step 6: Install Docker**

```bash
# Install Docker using the official convenience script
curl -fsSL https://get.docker.com | sudo sh

# Add deploy user to docker group (no sudo needed for docker commands)
sudo usermod -aG docker deploy

# Log out and back in for group change to take effect
exit
```

SSH back in:
```bash
ssh deploy@<VPS_IP>
docker --version
docker compose version
```

Expected: Docker 27+ and Docker Compose v2+.

- [ ] **Step 7: Set up the bot directory and .env**

```bash
mkdir -p /home/deploy/bot/src
```

Create the `.env` file with your actual secrets:
```bash
cat > /home/deploy/bot/.env << 'EOF'
DISCORD_TOKEN=<your-bot-token>
SUPABASE_URL=<your-supabase-url>
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
EOF

chmod 600 /home/deploy/bot/.env
```

- [ ] **Step 8: Copy deploy.sh and docker-compose.yml to VPS**

From your local machine:
```bash
scp bot/deploy.sh deploy@<VPS_IP>:/home/deploy/bot/deploy.sh
scp bot/docker-compose.yml deploy@<VPS_IP>:/home/deploy/bot/docker-compose.yml
```

On the VPS:
```bash
chmod +x /home/deploy/bot/deploy.sh
```

---

### Task 7: Configure GitHub Actions Secrets

This task is manual — done in the GitHub repo settings.

- [ ] **Step 1: Generate a deploy SSH key**

On your local machine:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/gemini-bot-deploy -N "" -C "github-actions-deploy"
```

- [ ] **Step 2: Add the public key to the VPS**

```bash
ssh-copy-id -i ~/.ssh/gemini-bot-deploy.pub deploy@<VPS_IP>
```

Or manually append the public key to `/home/deploy/.ssh/authorized_keys` on the VPS.

- [ ] **Step 3: Add secrets to GitHub repo**

Go to: `https://github.com/<owner>/Gemini-server/settings/secrets/actions`

Add these repository secrets:

| Secret | Value |
|--------|-------|
| `VPS_HOST` | The Hetzner VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of `~/.ssh/gemini-bot-deploy` (the **private** key) |

- [ ] **Step 4: Verify by triggering a manual deploy**

Go to: `https://github.com/<owner>/Gemini-server/actions/workflows/deploy-bot.yml`

Click **Run workflow** → **Run workflow**.

Watch the workflow. Expected: builds image, pushes to GHCR, SSHs into VPS, runs `deploy.sh`, health check passes.

---

### Task 8: Set Up UptimeRobot Monitoring

This task is manual — done in the UptimeRobot web UI and Discord settings.

- [ ] **Step 1: Create a Discord webhook for alerts**

1. In your Discord server, go to a private channel (e.g., `#bot-monitoring`)
2. Edit Channel → Integrations → Webhooks → New Webhook
3. Name it `UptimeRobot` and copy the webhook URL

- [ ] **Step 2: Create UptimeRobot monitor**

1. Go to https://uptimerobot.com (create free account if needed)
2. Add New Monitor:
   - **Type:** HTTP(s)
   - **Friendly Name:** `Gemini Discord Bot`
   - **URL:** `http://<VPS_IP>:3000/health` (or `https://bot.yourdomain.com/health` if DNS is set up)
   - **Monitoring Interval:** 5 minutes
3. Under Alert Contacts, add a new contact:
   - **Type:** Webhook
   - **URL:** The Discord webhook URL from Step 1
   - Set to alert on **Down** and **Up** events

- [ ] **Step 3: Verify monitoring**

Stop the container on the VPS:
```bash
ssh deploy@<VPS_IP> "cd /home/deploy/bot && docker compose stop"
```

Wait for UptimeRobot to detect the failure (up to 5 minutes). Check your Discord channel for the alert.

Restart:
```bash
ssh deploy@<VPS_IP> "cd /home/deploy/bot && docker compose start"
```

Verify the "back up" notification arrives in Discord.

---

### Task 9: Update Manifest and Final Verification

**Files:**
- Modify: `docs/superpowers/discord-bot-manifest.md`

- [ ] **Step 1: Update the manifest**

Change SP1 status:
```markdown
### SP1: VPS Infrastructure
- **Status:** Complete
- **Spec:** `docs/superpowers/specs/2026-05-15-sp1-vps-infrastructure-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-15-sp1-vps-infrastructure.md`
- **Depends on:** Nothing (first in chain)
- **Deliverable:** Hardened Hetzner CX22 with CI/CD and monitoring
- **Decisions made:** Docker Compose, auto-deploy via GitHub Actions, UptimeRobot + Discord webhook monitoring, .env secrets on VPS
```

- [ ] **Step 2: Run the full verification checklist**

From your local machine, verify each component:

```bash
# 1. SSH access works
ssh deploy@<VPS_IP> "echo 'SSH OK'"

# 2. Docker is running
ssh deploy@<VPS_IP> "docker compose -f /home/deploy/bot/docker-compose.yml ps"

# 3. Health endpoint responds
curl -s http://<VPS_IP>:3000/health | python3 -m json.tool

# 4. Firewall is configured
ssh deploy@<VPS_IP> "sudo ufw status"

# 5. fail2ban is running
ssh deploy@<VPS_IP> "sudo fail2ban-client status sshd"

# 6. unattended-upgrades is enabled
ssh deploy@<VPS_IP> "cat /etc/apt/apt.conf.d/20auto-upgrades"
```

Expected: All commands succeed. Health endpoint returns `{"ok": true, ...}`. UFW shows SSH/HTTP/HTTPS allowed. fail2ban shows the SSH jail active.

- [ ] **Step 3: Commit manifest update**

```bash
git add docs/superpowers/discord-bot-manifest.md
git commit -m "docs: mark SP1 VPS Infrastructure as complete"
```

---

## Summary

| Task | Type | What it produces |
|------|------|-----------------|
| 1 | Code | Placeholder health check server (`bot/src/health.js`) |
| 2 | Code | Dockerfile + Docker Compose config |
| 3 | Code | `.env.example` template + `deploy.sh` script |
| 4 | Code | GitHub Actions deploy workflow |
| 5 | Code | Optional Caddy reverse proxy config |
| 6 | Manual | Provisioned + hardened Hetzner CX22 |
| 7 | Manual | GitHub Actions secrets configured |
| 8 | Manual | UptimeRobot monitoring with Discord alerts |
| 9 | Code + Manual | Manifest update + final verification |

Tasks 1–5 are code changes committed to the repo. Tasks 6–8 are manual provisioning steps. Task 9 ties it all together.
