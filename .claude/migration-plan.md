# Migration Plan: Gemini-server → mg-tokyo/mg-restock-server

**Priority: 1 (must be completed BEFORE any Pages repos are transferred)**
**Reason: CORS allowlists must permit the new `mg-tokyo.github.io` origin before Pages repos move, or the restock tracker and other tools will be blocked.**

## Instructions for Claude (read this first, follow it exactly)

**User prompt:** `Read .claude/migration-plan.md and follow it.`

You are executing a repo migration plan. Follow these rules strictly:

1. **Execute steps in exact order.** Do not skip, reorder, or combine steps.
2. **[CLAUDE] steps:** Execute the code change or command described. Show what you changed. Move to the next step immediately.
3. **[YOU] steps:** Print the full instructions for that step to the user, then **stop and wait**. Do not proceed until the user confirms the result. Do not guess or assume the outcome.
4. **Do not improvise.** Only make changes described in this plan. Do not refactor, clean up, or "improve" anything beyond what is listed.
5. **If something fails or looks wrong**, stop and tell the user what happened. Do not attempt to fix it creatively.
6. **After all steps are complete**, print the verification summary with all checkboxes filled in based on actual results from this session.

---

## Pre-transfer changes

### Step 1 [CLAUDE]: Update CORS allowlist

**File:** `supabase/functions/_shared/cors.ts` (line 17)

Add `https://mg-tokyo.github.io` to the allowed origins list **alongside** the existing `ryandt2305-cpu.github.io` entry. Do not remove the old origin yet — it stays until all Pages repos are confirmed working under the new org.

### Step 2 [CLAUDE]: Update rate limiter origin check

**File:** `supabase/functions/_shared/rateLimit.ts` (line 132)

Same change — add `https://mg-tokyo.github.io` alongside the existing origin. Do not remove the old one.

### Step 3 [CLAUDE]: Update documentation

**File:** `DEPLOY.md` — replace all occurrences of `ryandt2305-cpu.github.io` with `mg-tokyo.github.io` and all occurrences of `ryandt2305-cpu` in curl examples.

**File:** `SECURITY.md` (line 16) — update `ryandt2305-cpu.github.io` to `mg-tokyo.github.io`.

### Step 4 [CLAUDE]: Commit all changes

Commit the CORS, rate limiter, and docs changes with an appropriate message. Push to the remote.

### Step 5 [YOU]: Deploy Supabase Edge Functions

Deploy the updated Edge Functions to Supabase so the new CORS origin is live.

**How:** Follow the deployment instructions in `DEPLOY.md` for your setup — this is typically done via the Supabase CLI or dashboard. If you're unsure how you deployed these before, tell Claude and it can check `DEPLOY.md` for your specific deployment method.

**Confirm to Claude when done.**

### Step 6 [YOU]: Note down repo secrets BEFORE transferring

1. Go to https://github.com/ryandt2305-cpu/mg-restock-server
2. Click **Settings** (tab at the top)
3. In the left sidebar, click **Secrets and variables** → **Actions**
4. Write down or screenshot every secret name listed there (you'll need to re-add them after transfer — you won't be able to see the values, so make sure you have them saved elsewhere)

**Tell Claude what secrets you found (just the names, not the values).**

### Step 7 [YOU]: Transfer the repo

1. Go to https://github.com/ryandt2305-cpu/mg-restock-server
2. Click **Settings** (tab at the top)
3. Scroll all the way down to the **Danger Zone** section
4. Click **Transfer** (next to "Transfer ownership")
5. In the popup:
   - Type **`mg-tokyo`** as the new owner
   - Type the repo name **`mg-restock-server`** to confirm
6. Click **I understand, transfer this repository**

**Confirm to Claude when the transfer is complete.**

### Step 8 [YOU]: Re-add secrets

1. Go to https://github.com/mg-tokyo/mg-restock-server
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret** for each secret you noted in Step 6
4. Enter the name and value for each one

**Confirm to Claude when done.**

### Step 9 [CLAUDE]: Update local git remote

```bash
git remote set-url origin https://github.com/mg-tokyo/mg-restock-server.git
```

### Step 10 [YOU]: Verify GitHub Actions still work

1. Go to https://github.com/mg-tokyo/mg-restock-server
2. Click the **Actions** tab
3. Check if any workflows have run recently or if there are errors
4. If workflows use a Personal Access Token (PAT), you may need to authorize it for the `mg-tokyo` org:
   - Go to https://github.com/settings/tokens
   - Click on the token → **Configure SSO** or check org access settings

**Tell Claude the result.**

---

## Post-migration cleanup (LATER — after ALL repos are transferred and verified)

Remove the old `ryandt2305-cpu.github.io` origin from:
- `supabase/functions/_shared/cors.ts`
- `supabase/functions/_shared/rateLimit.ts`

Deploy again after removal. This is a separate task — do NOT do it now.

## Do NOT create a redirect stub

This is a backend/API repo, not a GitHub Pages site. No stub needed.

---

## Verification summary (paste back to orchestrator)

```
## Gemini-server migration verification
- [ ] cors.ts: added mg-tokyo.github.io origin (old origin kept)
- [ ] rateLimit.ts: added mg-tokyo.github.io origin (old origin kept)
- [ ] DEPLOY.md: updated all references
- [ ] SECURITY.md: updated reference
- [ ] Changes committed and pushed
- [ ] Supabase functions deployed successfully
- [ ] Repo transferred to mg-tokyo
- [ ] Secrets re-added: (list which ones)
- [ ] Git remote updated
- [ ] GitHub Actions verified: PASS/FAIL
- git diff --stat: (paste)
```
