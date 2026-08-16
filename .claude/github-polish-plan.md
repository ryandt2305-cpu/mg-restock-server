# GitHub Polish Plan: Gemini-server (mg-restock-server)

## Instructions for Claude (read this first, follow it exactly)

**User prompt:** `Read .claude/github-polish-plan.md and follow it.`

You are polishing this repo's GitHub presentation. Follow these rules strictly:

1. **Execute steps in exact order.** Do not skip, reorder, or combine steps.
2. **[CLAUDE] steps:** Execute the change described. Show what you changed. Move to the next step.
3. **[YOU] steps:** Print the full instructions for that step to the user, then **stop and wait** for confirmation.
4. **Do not improvise.** Only make changes described in this plan. Do not refactor, clean up, or "improve" anything beyond what is listed.
5. **If something fails or looks wrong**, stop and tell the user what happened.

---

## Step 1 [CLAUDE]: Read the current README.md and package.json

Read both files fully. Understand what the server does. You'll need this for context.

## Step 2 [CLAUDE]: Create LICENSE file

Create a file called `LICENSE` at the repo root with the MIT license. Use this exact copyright line:

```
Copyright (c) 2025 TOKYO.#6464
```

## Step 3 [CLAUDE]: Update package.json fields

Add these fields to `package.json` (do not change existing fields, do not remove `private: true`):

- `"version": "1.0.0"`
- `"description": "Restock and weather data pipeline for Magic Garden"`
- `"license": "MIT"`

## Step 4 [YOU]: Update GitHub repo settings

1. Go to https://github.com/mg-tokyo/mg-restock-server
2. Click the **gear icon** next to "About" (top right of the repo page)
3. Set **Description** to: `Restock and weather data pipeline powering MG Tokyo tools`
4. Set **Topics** to: `magic-garden`, `supabase`, `api`, `backend`
5. Click **Save changes**

**Confirm to Claude when done.**

## Done

Print this summary:

```
## mg-restock-server polish complete
- [ ] LICENSE file created (MIT)
- [ ] package.json: version, description, and license added
- [ ] GitHub description and topics set
```
