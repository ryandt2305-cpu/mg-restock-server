# SP1: VPS Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `Gemini-discord-bot` repo with production-grade TypeScript tooling, Claude Code optimization, Docker Compose deployment, GitHub Actions CI/CD, and provision a hardened Hetzner CX22 VPS — ready for SP2 to build the bot on.

**Architecture:** Standalone repo at `C:\Users\ryand\Feeder-Extension\Gemini-discord-bot`. TypeScript strict, vitest, ESLint, Prettier. Docker Compose on a Hetzner CX22 (Ubuntu 24.04, US East). GitHub Actions runs CI checks (typecheck + lint + test) on every PR, and auto-deploys to VPS on merge to main. UptimeRobot pings `/health` and alerts via Discord webhook.

**Tech Stack:** TypeScript 5.x (strict), Node.js 20, vitest, ESLint 9 (flat config), Prettier, Docker + Docker Compose, GitHub Actions, GHCR, Caddy (optional), UptimeRobot

**Spec:** `docs/superpowers/specs/2026-05-15-sp1-vps-infrastructure-design.md` (in Gemini-server repo)

---

## File Structure

New repo: `C:\Users\ryand\Feeder-Extension\Gemini-discord-bot`

```
Gemini-discord-bot/
├── .claude/
│   ├── settings.local.json          # Claude Code local settings
│   └── rules/
│       └── core.md                  # Core architecture rules for Claude
├── CLAUDE.md                        # Project memory for Claude Code
├── .github/
│   └── workflows/
│       ├── ci.yml                   # PR checks: typecheck + lint + test
│       └── deploy.yml               # Main merge: build → GHCR → SSH deploy
├── src/
│   └── health.ts                    # SP1 placeholder health server
├── tests/
│   └── health.test.ts               # Health endpoint tests
├── Dockerfile                       # Multi-stage Node.js 20 build
├── docker-compose.yml               # Bot service + optional Caddy
├── deploy.sh                        # VPS deploy script (called by CI/CD)
├── Caddyfile                        # Optional reverse proxy config
├── .env.example                     # Documented env var template
├── .dockerignore                    # Docker build exclusions
├── .gitignore                       # Node.js + env exclusions
├── .prettierrc                      # Prettier config
├── eslint.config.js                 # ESLint 9 flat config
├── tsconfig.json                    # TypeScript strict config
├── vitest.config.ts                 # Vitest config
├── package.json                     # Dependencies + scripts
└── docs/
    └── superpowers/                 # Design specs + plans (cross-linked from Gemini-server)
```

---

### Task 1: Initialize Repo and Git

**Files:**
- Create: `C:\Users\ryand\Feeder-Extension\Gemini-discord-bot\` (directory)
- Create: `.gitignore`

- [ ] **Step 1: Create directory and init git**

```bash
mkdir -p "C:\Users\ryand\Feeder-Extension\Gemini-discord-bot"
cd "C:\Users\ryand\Feeder-Extension\Gemini-discord-bot"
git init
```

- [ ] **Step 2: Create `.gitignore`**

```
node_modules/
dist/
.env
*.tsbuildinfo
coverage/
.tmp/
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: initialize repo"
```

---

### Task 2: Set Up package.json, TypeScript, ESLint, Prettier, Vitest

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `eslint.config.js`
- Create: `.prettierrc`
- Create: `vitest.config.ts`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "gemini-discord-bot",
  "version": "0.1.0",
  "description": "Discord bot for MagicGarden restock tracking, predictions, and weather alerts",
  "private": true,
  "type": "module",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "start": "node dist/health.js",
    "build": "tsc",
    "dev": "tsx watch src/health.ts",
    "typecheck": "tsc --noEmit",
    "lint": "eslint src/ tests/",
    "lint:fix": "eslint src/ tests/ --fix",
    "format": "prettier --write \"src/**/*.ts\" \"tests/**/*.ts\"",
    "format:check": "prettier --check \"src/**/*.ts\" \"tests/**/*.ts\"",
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage",
    "check": "npm run typecheck && npm run lint && npm run test"
  },
  "dependencies": {
    "express": "^4.21.0"
  },
  "devDependencies": {
    "@types/express": "^5.0.0",
    "@types/node": "^20.17.0",
    "eslint": "^9.15.0",
    "@eslint/js": "^9.15.0",
    "typescript-eslint": "^8.18.0",
    "prettier": "^3.4.0",
    "typescript": "^5.7.0",
    "tsx": "^4.19.0",
    "vitest": "^3.0.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "exactOptionalPropertyTypes": false,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "declaration": true,
    "sourceMap": true,
    "esModuleInterop": true
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist", "tests"]
}
```

- [ ] **Step 3: Create `eslint.config.js`**

```js
import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.strict,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/explicit-function-return-type': 'off',
      '@typescript-eslint/consistent-type-imports': 'error',
    },
  },
  {
    ignores: ['dist/', 'node_modules/', '*.config.*'],
  },
);
```

- [ ] **Step 4: Create `.prettierrc`**

```json
{
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "semi": true,
  "tabWidth": 2
}
```

- [ ] **Step 5: Create `vitest.config.ts`**

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.d.ts'],
    },
  },
});
```

- [ ] **Step 6: Install dependencies**

```bash
cd "C:\Users\ryand\Feeder-Extension\Gemini-discord-bot"
npm install
```

- [ ] **Step 7: Verify tooling works**

```bash
npm run typecheck
npm run lint
npm run format:check
```

Expected: All three pass (no source files to check yet, so they exit cleanly).

- [ ] **Step 8: Commit**

```bash
git add package.json package-lock.json tsconfig.json eslint.config.js .prettierrc vitest.config.ts
git commit -m "chore: add TypeScript, ESLint, Prettier, and vitest tooling"
```

---

### Task 3: Create CLAUDE.md and Rules

**Files:**
- Create: `CLAUDE.md`
- Create: `.claude/rules/core.md`
- Create: `.claude/settings.local.json`

- [ ] **Step 1: Create `CLAUDE.md`**

```markdown
# Gemini Discord Bot (Claude Code)

Project memory for Claude Code. Keep it short and actionable.

## TL;DR
- Project: Discord bot for MagicGarden restock tracking, predictions, weather alerts, and pipeline health
- Reads from: Supabase (same instance as Gemini-server — read-only)
- Deployed to: Hetzner CX22 VPS via Docker Compose
- Stack: TypeScript (strict), Node.js 20, Discord.js (SP2), Express (health), vitest

## Commands
- build: `npm run build`
- dev: `npm run dev` (tsx watch)
- typecheck: `npm run typecheck`
- lint: `npm run lint`
- test: `npm run test`
- all checks: `npm run check` (typecheck + lint + test)
- format: `npm run format`

## Repo map
- `src/health.ts` — HTTP health check server (SP1 placeholder, extended in SP2)
- `tests/` — vitest test files, mirrors `src/` structure
- `Dockerfile` — multi-stage production build
- `docker-compose.yml` — bot service definition
- `deploy.sh` — VPS deploy script (called by GitHub Actions)
- `.github/workflows/ci.yml` — PR gate: typecheck + lint + test
- `.github/workflows/deploy.yml` — auto-deploy on merge to main

## Related repos
- `Gemini-server` — data pipeline (Supabase edge functions, restock polling, weather tracking)
- `Gemini-main` (Feeder-Extension) — userscript mod (Tampermonkey)

## Rules
- Core: `.claude/rules/core.md`

## Data source
The bot queries Supabase **read-only**. It never writes to Supabase tables.
Key views/RPCs the bot will use (defined in Gemini-server):
- `restock_predictions` view — live ETAs + probabilities per item
- `weather_predictions` view — weather pattern analysis
- `restock_history` table — per-item aggregated stats
- `check_restock_pipeline_health()` RPC — pipeline staleness check
```

- [ ] **Step 2: Create `.claude/rules/core.md`**

```markdown
# Core rules

## 1) TypeScript strict (non-negotiable)
- No `any`. Use `unknown` + narrowing.
- All functions must have explicit return types in public APIs.
- Use `type` imports (`import type { ... }`) for type-only imports.

## 2) Testing
- Every feature must have tests. Write the test first (TDD).
- Test files live in `tests/` and mirror the `src/` structure.
- Use vitest. No mocking frameworks — use vitest's built-in `vi.fn()` / `vi.spyOn()`.
- Test behavior, not implementation. Tests should survive refactors.

## 3) Supabase access
- The bot is read-only. Never insert, update, or delete Supabase data.
- All Supabase queries go through a single client module (not scattered across commands).
- Cache responses (30–60s TTL) to avoid hammering the database.

## 4) Discord patterns
- All slash commands must validate inputs and handle errors gracefully.
- Embeds must have consistent color coding and formatting.
- Rate limit handling is mandatory — use Discord.js built-in retry.
- Per-server config must be validated on write, not on read.

## 5) Error handling
- Never swallow errors silently. Log them with structured context.
- Health check must report degraded state (not just ok/not-ok).
- Unhandled rejections and uncaught exceptions must trigger graceful shutdown.

## 6) Code quality
- File size: 300 lines soft limit, 500 lines hard limit.
- Functions: single-purpose, early returns, no deep nesting.
- No magic numbers or strings — use named constants.
- `npm run check` must pass before every commit.
```

- [ ] **Step 3: Create `.claude/settings.local.json`**

```json
{
  "permissions": {
    "allow": [
      "Bash(npm run typecheck)",
      "Bash(npm run lint)",
      "Bash(npm run lint:fix)",
      "Bash(npm run test)",
      "Bash(npm run test:watch)",
      "Bash(npm run test:coverage)",
      "Bash(npm run check)",
      "Bash(npm run build)",
      "Bash(npm run dev)",
      "Bash(npm run format)",
      "Bash(npm run format:check)",
      "Bash(npm install)"
    ]
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md .claude/
git commit -m "chore: add CLAUDE.md and rules for Claude Code optimization"
```

---

### Task 4: Write Health Check Server (TDD)

**Files:**
- Create: `src/health.ts`
- Create: `tests/health.test.ts`

- [ ] **Step 1: Write the failing test**

Create `tests/health.test.ts`:

```ts
import { describe, it, expect, afterAll } from 'vitest';
import type { Server } from 'node:http';

describe('health endpoint', () => {
  let server: Server;
  let baseUrl: string;

  // Dynamic import so we can control when the server starts
  it('should start and respond to /health', async () => {
    // Set a test port to avoid conflicts
    process.env.PORT = '0'; // 0 = random available port

    const { createHealthServer } = await import('../src/health.js');
    server = createHealthServer();

    await new Promise<void>((resolve) => {
      server.listen(0, () => resolve());
    });

    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('No address');
    baseUrl = `http://localhost:${address.port}`;

    const res = await fetch(`${baseUrl}/health`);
    const body = (await res.json()) as Record<string, unknown>;

    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(typeof body.uptime).toBe('number');
    expect(typeof body.version).toBe('string');
  });

  it('should return 404 for unknown routes', async () => {
    const res = await fetch(`${baseUrl}/nonexistent`);
    expect(res.status).toBe(404);
  });

  afterAll(() => {
    server?.close();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npm run test
```

Expected: FAIL — `Cannot find module '../src/health.js'`

- [ ] **Step 3: Write the implementation**

Create `src/health.ts`:

```ts
import express from 'express';
import type { Server } from 'node:http';

const PORT = process.env.PORT || 3000;
const startTime = Date.now();

export function createHealthServer(): Server {
  const app = express();

  app.get('/health', (_req, res) => {
    res.json({
      ok: true,
      uptime: Math.floor((Date.now() - startTime) / 1000),
      version: process.env.npm_package_version ?? '0.1.0',
    });
  });

  return app.listen();
}

// Start the server when run directly (not imported for tests)
const isDirectRun = process.argv[1]?.endsWith('health.js') || process.argv[1]?.endsWith('health.ts');
if (isDirectRun) {
  const server = createHealthServer();
  server.listen(Number(PORT), () => {
    console.log(`Health check listening on port ${PORT}`);
  });
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npm run test
```

Expected: 2 tests pass.

- [ ] **Step 5: Run full check suite**

```bash
npm run check
```

Expected: typecheck, lint, and test all pass.

- [ ] **Step 6: Commit**

```bash
git add src/health.ts tests/health.test.ts
git commit -m "feat: add health check server with tests"
```

---

### Task 5: Create Dockerfile and Docker Compose

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `.dockerignore`**

```
node_modules
dist
.env
.git
.github
tests
coverage
docs
.claude
*.md
!package*.json
```

- [ ] **Step 2: Create `Dockerfile`**

```dockerfile
# Stage 1: Install production dependencies
FROM node:20-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --production

# Stage 2: Build TypeScript
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Stage 3: Production image
FROM node:20-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE 3000
USER node
CMD ["node", "dist/health.js"]
```

- [ ] **Step 3: Create `docker-compose.yml`**

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

  # --- Optional: Caddy reverse proxy with automatic TLS ---
  # Uncomment below + remove `ports` from bot service above.
  # Requires: DNS A record pointing your subdomain to this VPS IP.
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

- [ ] **Step 4: Build and test Docker image locally**

```bash
docker compose build
docker compose up -d
sleep 5
curl http://localhost:3000/health
docker compose ps
docker compose down
```

Expected: `/health` returns `{"ok":true,...}` and `docker compose ps` shows `healthy`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile .dockerignore docker-compose.yml
git commit -m "feat: add multi-stage Dockerfile and Docker Compose"
```

---

### Task 6: Create Deploy Script, Caddyfile, and .env.example

**Files:**
- Create: `deploy.sh`
- Create: `Caddyfile`
- Create: `.env.example`

- [ ] **Step 1: Create `.env.example`**

```bash
# Discord bot token — https://discord.com/developers/applications
DISCORD_TOKEN=

# Supabase project URL — https://<project-ref>.supabase.co
SUPABASE_URL=

# Supabase service role key — Settings → API → service_role
SUPABASE_SERVICE_ROLE_KEY=
```

- [ ] **Step 2: Create `deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd /home/deploy/bot

echo "[deploy] Pulling latest image..."
docker compose pull

echo "[deploy] Starting updated container..."
docker compose up -d --remove-orphans

echo "[deploy] Pruning old images..."
docker image prune -f

echo "[deploy] Verifying health..."
sleep 5
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/health)
if [ "$HTTP_CODE" != "200" ]; then
  echo "[deploy] FAIL: Health check returned HTTP $HTTP_CODE"
  docker compose logs --tail=20
  exit 1
fi
echo "[deploy] Success. Health check: HTTP $HTTP_CODE"
```

- [ ] **Step 3: Create `Caddyfile`**

```
# Replace with your actual subdomain.
# Only used when Caddy is enabled in docker-compose.yml.
bot.yourdomain.com {
    reverse_proxy bot:3000
}
```

- [ ] **Step 4: Commit**

```bash
git add .env.example deploy.sh Caddyfile
git commit -m "feat: add deploy script, env template, and Caddy config"
```

---

### Task 7: Create GitHub Actions Workflows (CI + Deploy)

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/deploy.yml`

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

This runs on every PR and push. It gates merges — PRs cannot merge unless typecheck, lint, and tests all pass.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_call:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 5

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Typecheck
        run: npm run typecheck

      - name: Lint
        run: npm run lint

      - name: Format check
        run: npm run format:check

      - name: Test
        run: npm run test
```

- [ ] **Step 2: Create `.github/workflows/deploy.yml`**

This runs only on main after CI passes. It builds the Docker image, pushes to GHCR, and deploys to the VPS.

```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy
  cancel-in-progress: false

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/gemini-discord-bot

jobs:
  ci:
    uses: ./.github/workflows/ci.yml

  deploy:
    needs: ci
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
          context: .
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

- [ ] **Step 3: Commit**

```bash
git add .github/
git commit -m "ci: add CI checks (typecheck + lint + test) and deploy workflow"
```

---

### Task 8: Create GitHub Remote and Push

- [ ] **Step 1: Create GitHub repo**

```bash
cd "C:\Users\ryand\Feeder-Extension\Gemini-discord-bot"
gh repo create Gemini-discord-bot --private --source=. --push
```

If the repo already exists or you prefer to create it via the GitHub UI, use:
```bash
git remote add origin https://github.com/<owner>/Gemini-discord-bot.git
git push -u origin main
```

- [ ] **Step 2: Configure branch protection (recommended)**

Go to: `https://github.com/<owner>/Gemini-discord-bot/settings/branches`

Add rule for `main`:
- Require status checks to pass before merging: **check** (from ci.yml)
- Require branches to be up to date before merging

This ensures no code reaches main without passing typecheck + lint + test.

- [ ] **Step 3: Verify CI runs**

Check the Actions tab. The push to main should have triggered both CI and Deploy workflows. Deploy will fail (no VPS secrets yet) — that's expected. CI should pass.

---

### Task 9: Provision Hetzner CX22 and Harden

This task is manual — it happens in the Hetzner Cloud console and via SSH.

**Prerequisites:** Hetzner Cloud account, an SSH key pair on your local machine.

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

adduser --disabled-password --gecos "" deploy
usermod -aG sudo deploy
echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy

mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys
```

- [ ] **Step 3: Harden SSH**

```bash
# Still as root
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
```

Verify from a new terminal before closing root session:
```bash
ssh deploy@<VPS_IP>
```

- [ ] **Step 4: Install fail2ban and UFW**

```bash
sudo apt update && sudo apt install -y fail2ban ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

- [ ] **Step 5: Enable unattended-upgrades**

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Verify:
```bash
cat /etc/apt/apt.conf.d/20auto-upgrades
```

Expected: `APT::Periodic::Unattended-Upgrade "1";`

- [ ] **Step 6: Install Docker**

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy
exit
```

SSH back in and verify:
```bash
ssh deploy@<VPS_IP>
docker --version
docker compose version
```

Expected: Docker 27+ and Docker Compose v2+.

- [ ] **Step 7: Set up bot directory and .env on VPS**

```bash
mkdir -p /home/deploy/bot

cat > /home/deploy/bot/.env << 'EOF'
DISCORD_TOKEN=<your-bot-token>
SUPABASE_URL=<your-supabase-url>
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
EOF

chmod 600 /home/deploy/bot/.env
```

- [ ] **Step 8: Copy deploy files to VPS**

From your local machine:
```bash
scp deploy.sh deploy@<VPS_IP>:/home/deploy/bot/deploy.sh
scp docker-compose.yml deploy@<VPS_IP>:/home/deploy/bot/docker-compose.yml
scp Caddyfile deploy@<VPS_IP>:/home/deploy/bot/Caddyfile
```

On the VPS:
```bash
chmod +x /home/deploy/bot/deploy.sh
```

---

### Task 10: Configure GitHub Actions Secrets and First Deploy

- [ ] **Step 1: Generate a deploy SSH key**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gemini-bot-deploy -N "" -C "github-actions-deploy"
```

- [ ] **Step 2: Add the public key to the VPS**

```bash
ssh-copy-id -i ~/.ssh/gemini-bot-deploy.pub deploy@<VPS_IP>
```

- [ ] **Step 3: Add secrets to the Gemini-discord-bot GitHub repo**

Go to: `https://github.com/<owner>/Gemini-discord-bot/settings/secrets/actions`

| Secret | Value |
|--------|-------|
| `VPS_HOST` | The Hetzner VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of `~/.ssh/gemini-bot-deploy` (private key) |

- [ ] **Step 4: Trigger manual deploy**

Go to: `https://github.com/<owner>/Gemini-discord-bot/actions/workflows/deploy.yml`

Click **Run workflow**. Watch the workflow.

Expected: builds image → pushes to GHCR → SSHs into VPS → `deploy.sh` runs → health check passes.

- [ ] **Step 5: Verify the bot is running on the VPS**

```bash
curl -s http://<VPS_IP>:3000/health | python3 -m json.tool
```

Expected: `{"ok": true, "uptime": ..., "version": "0.1.0"}`

---

### Task 11: Set Up UptimeRobot Monitoring

- [ ] **Step 1: Create a Discord webhook for alerts**

1. In your Discord server, go to a private channel (e.g., `#bot-monitoring`)
2. Edit Channel → Integrations → Webhooks → New Webhook
3. Name it `UptimeRobot` and copy the webhook URL

- [ ] **Step 2: Create UptimeRobot monitor**

1. Go to https://uptimerobot.com (create free account if needed)
2. Add New Monitor:
   - **Type:** HTTP(s)
   - **Friendly Name:** `Gemini Discord Bot`
   - **URL:** `http://<VPS_IP>:3000/health`
   - **Monitoring Interval:** 5 minutes
3. Under Alert Contacts, add a new contact:
   - **Type:** Webhook
   - **URL:** The Discord webhook URL from Step 1
   - Alert on **Down** and **Up** events

- [ ] **Step 3: Verify monitoring**

Stop the container:
```bash
ssh deploy@<VPS_IP> "cd /home/deploy/bot && docker compose stop"
```

Wait for UptimeRobot alert in Discord (up to 5 minutes).

Restart:
```bash
ssh deploy@<VPS_IP> "cd /home/deploy/bot && docker compose start"
```

Verify "back up" notification arrives.

---

### Task 12: Update Gemini-server Manifest and Final Verification

**Files:**
- Modify: `docs/superpowers/discord-bot-manifest.md` (in Gemini-server repo)

- [ ] **Step 1: Update the manifest**

In the Gemini-server repo, update SP1:

```markdown
### SP1: VPS Infrastructure
- **Status:** Complete
- **Spec:** `docs/superpowers/specs/2026-05-15-sp1-vps-infrastructure-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-15-sp1-vps-infrastructure.md`
- **Repo:** `Gemini-discord-bot` (separate repo)
- **Depends on:** Nothing (first in chain)
- **Deliverable:** Hardened Hetzner CX22 with CI/CD and monitoring
- **Decisions made:** Docker Compose, auto-deploy via GitHub Actions, UptimeRobot + Discord webhook monitoring, .env secrets on VPS, own repo with TypeScript strict + vitest + ESLint
```

- [ ] **Step 2: Run the full verification checklist**

```bash
# 1. SSH access
ssh deploy@<VPS_IP> "echo 'SSH OK'"

# 2. Docker running
ssh deploy@<VPS_IP> "docker compose -f /home/deploy/bot/docker-compose.yml ps"

# 3. Health endpoint
curl -s http://<VPS_IP>:3000/health | python3 -m json.tool

# 4. Firewall
ssh deploy@<VPS_IP> "sudo ufw status"

# 5. fail2ban
ssh deploy@<VPS_IP> "sudo fail2ban-client status sshd"

# 6. unattended-upgrades
ssh deploy@<VPS_IP> "cat /etc/apt/apt.conf.d/20auto-upgrades"

# 7. CI passes in Gemini-discord-bot repo
# (check GitHub Actions tab)

# 8. UptimeRobot shows "Up"
# (check UptimeRobot dashboard)
```

- [ ] **Step 3: Commit manifest update in Gemini-server**

```bash
cd "C:\Users\ryand\Feeder-Extension\Gemini-folder\Gemini-server"
git add docs/superpowers/discord-bot-manifest.md
git commit -m "docs: mark SP1 VPS Infrastructure as complete"
```

---

## Summary

| Task | Type | What it produces |
|------|------|-----------------|
| 1 | Code | Git repo initialized with `.gitignore` |
| 2 | Code | TypeScript + ESLint + Prettier + vitest tooling |
| 3 | Code | `CLAUDE.md`, `.claude/rules/core.md`, settings |
| 4 | Code (TDD) | Health check server with tests |
| 5 | Code | Multi-stage Dockerfile + Docker Compose |
| 6 | Code | Deploy script, env template, Caddyfile |
| 7 | Code | CI workflow (PR gate) + Deploy workflow |
| 8 | Manual | GitHub remote repo + branch protection |
| 9 | Manual | Provisioned + hardened Hetzner CX22 |
| 10 | Manual | GitHub Actions secrets + first deploy |
| 11 | Manual | UptimeRobot monitoring with Discord alerts |
| 12 | Code + Manual | Manifest update + final verification |

Tasks 1–7 are code committed to the new `Gemini-discord-bot` repo. Tasks 8–11 are manual setup. Task 12 closes SP1 in the Gemini-server manifest.
