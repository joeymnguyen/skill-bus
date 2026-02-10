---
name: remove-sub
description: Unsubscribe from a skill event. Removes or disables subscriptions with scope-aware options.
---

# Unsubscribe from Skill Event

**Announce:** "Removing a skill-bus subscription."

## Process

### Step 1: Load Current Subscriptions

Read both config files (skip gracefully if they don't exist):
- `~/.claude/skill-bus.json` (global)
- `.claude/skill-bus.json` (project, if exists)

If neither file exists or both have empty subscriptions arrays, show:
> "No subscriptions found. Run /skill-bus:add-sub to create your first subscription."
...and stop.

### Step 2: Show Active Subscriptions

Present them in a table:

```
Active Subscriptions:

  #  | ID                              | Scope   | On                          | When | Inject (preview)
  1  | handover-check                  | global  | superpowers:*               | pre  | Check HANDOVER.md for...
  2  | check-plans                     | project | superpowers:writing-plans   | pre  | Read docs/plans/ for...
  3  | post-commit-handover            | global  | commit-commands:commit      | post | Update HANDOVER.md...
```

### Step 3: Select Subscription to Remove

Ask: **"Which subscription to remove? (number or ID)"**

### Step 4: Confirm and Remove

Ask for confirmation: **"Remove `[id]` ([scope])? This cannot be undone."**

If confirmed:
- If scope is global: remove from `~/.claude/skill-bus.json`
- If scope is project: remove from `.claude/skill-bus.json`

If the subscriptions array becomes empty AND there are no custom settings, delete the config file entirely to keep things clean.

Show: "Removed subscription `[id]` from [scope] config."
