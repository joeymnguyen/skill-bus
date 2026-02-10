#!/bin/bash
set -euo pipefail

# Comprehensive test suite for Skill Bus (Groups H-S)
# Tests dispatch.sh, prompt-monitor.sh, and dispatcher.py edge cases

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCHER="$REPO_ROOT/lib/dispatcher.py"
CLI="$REPO_ROOT/lib/cli.py"
DISPATCH_SH="$REPO_ROOT/hooks/dispatch.sh"
PROMPT_MONITOR="$REPO_ROOT/hooks/prompt-monitor.sh"

# CI isolation: prevent leaking runner's real ~/.claude/skill-bus.json
# Tests needing a specific global config override this inline
# Use nonexistent path (not /dev/null which triggers JSON parse warning)
export SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent

PASS=0; FAIL=0; TOTAL=0

run_test() {
    local name="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -qF "$expected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected to contain: $expected"
        echo "    got: $actual"
    fi
}

run_test_empty() {
    local name="$1" actual="$2"
    TOTAL=$((TOTAL + 1))
    if [ -z "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    expected empty output"
        echo "    got: $actual"
    fi
}

run_test_absent() {
    local name="$1" absent="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -qF "$absent"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $name"
        echo "    should NOT contain: $absent"
        echo "    got: $actual"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    fi
}

# Trap cleanup for temp dirs
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# ─── Helper: make a fake HOME for dispatch.sh so it doesn't read real global config ───
# dispatch.sh reads $HOME/.claude/skill-bus.json — we override HOME to isolate tests.
# We also need to ensure python3 is on PATH and dispatch.sh can find the plugin root.

make_dispatch_input() {
    # Usage: make_dispatch_input <skill_name> <cwd>
    local skill="$1" cwd="$2"
    printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$skill" "$cwd"
}

make_prompt_input() {
    # Usage: make_prompt_input <prompt> <cwd>
    local prompt="$1" cwd="$2"
    printf '{"prompt":"%s","cwd":"%s"}' "$prompt" "$cwd"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Group H: Bash Fast-Path (dispatch.sh) — 12 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Group H: Bash Fast-Path (dispatch.sh) ==="

# H1: No config files exist → first-run nudge emitted (then silent on second call)
TMPDIR_H1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H1")
FAKE_HOME_H1=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H1")
# No .claude/skill-bus.json in either location → nudge fires on first call
OUTPUT=$(HOME="$FAKE_HOME_H1" make_dispatch_input "test:skill" "$TMPDIR_H1" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H1: no config files → nudge emitted" "No subscriptions configured" "$OUTPUT"

# H2: Config exists, skill name in config → Python invoked, output returned
TMPDIR_H2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H2")
FAKE_HOME_H2=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H2")
mkdir -p "$TMPDIR_H2/.claude"
cat > "$TMPDIR_H2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h2-insert": {"text": "H2_DISPATCH_SH_WORKS"}},
  "subscriptions": [{"insert": "h2-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H2" make_dispatch_input "test:skill" "$TMPDIR_H2" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H2: config exists, skill matches → output" "H2_DISPATCH_SH_WORKS" "$OUTPUT"

# H3: Config exists, skill NOT in config → silent exit (fast rejection)
TMPDIR_H3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H3")
FAKE_HOME_H3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H3")
mkdir -p "$TMPDIR_H3/.claude"
cat > "$TMPDIR_H3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h3-insert": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "h3-insert", "on": "other:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H3" make_dispatch_input "test:skill" "$TMPDIR_H3" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test_empty "H3: skill not in config → silent exit" "$OUTPUT"

# H4: Wildcard pattern in config, skill not literal match → Python invoked
TMPDIR_H4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H4")
FAKE_HOME_H4=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H4")
mkdir -p "$TMPDIR_H4/.claude"
cat > "$TMPDIR_H4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h4-insert": {"text": "H4_WILDCARD_MATCH"}},
  "subscriptions": [{"insert": "h4-insert", "on": "test:*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H4" make_dispatch_input "test:anything" "$TMPDIR_H4" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H4: wildcard pattern → Python invoked" "H4_WILDCARD_MATCH" "$OUTPUT"

# H5: Missing skill field in JSON → warning JSON returned
TMPDIR_H5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H5")
FAKE_HOME_H5=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H5")
mkdir -p "$TMPDIR_H5/.claude"
cat > "$TMPDIR_H5/.claude/skill-bus.json" << 'EOFCFG'
{"inserts": {}, "subscriptions": []}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H5" printf '{"tool_name":"Skill","cwd":"%s"}' "$TMPDIR_H5" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H5: missing skill field → warning" "could not extract skill name" "$OUTPUT"

# H6: No skill field in JSON (with valid CWD) → warning JSON returned
# dispatch.sh extracts CWD first, checks config exists, then extracts skill name.
# To trigger the "could not extract skill name" warning, we need config to exist at the CWD path.
TMPDIR_H6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H6")
FAKE_HOME_H6=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H6")
mkdir -p "$TMPDIR_H6/.claude"
cat > "$TMPDIR_H6/.claude/skill-bus.json" << 'EOFCFG'
{"inserts": {}, "subscriptions": []}
EOFCFG
# Send JSON with CWD but NO skill field — config exists so we reach the skill extraction step
OUTPUT=$(HOME="$FAKE_HOME_H6" printf '{"cwd":"%s"}' "$TMPDIR_H6" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H6: no skill field in JSON → warning" "could not extract skill name" "$OUTPUT"

# H7: Pre timing → hookEventName is "PreToolUse"
TMPDIR_H7=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H7")
FAKE_HOME_H7=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H7")
mkdir -p "$TMPDIR_H7/.claude"
cat > "$TMPDIR_H7/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h7-insert": {"text": "H7_PRE_TEST"}},
  "subscriptions": [{"insert": "h7-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H7" make_dispatch_input "test:skill" "$TMPDIR_H7" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H7: pre timing → PreToolUse" "PreToolUse" "$OUTPUT"

# H8: Post timing → hookEventName is "PostToolUse"
TMPDIR_H8=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H8")
FAKE_HOME_H8=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H8")
mkdir -p "$TMPDIR_H8/.claude"
cat > "$TMPDIR_H8/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h8-insert": {"text": "H8_POST_TEST"}},
  "subscriptions": [{"insert": "h8-insert", "on": "test:skill", "when": "post"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H8" make_dispatch_input "test:skill" "$TMPDIR_H8" | bash "$DISPATCH_SH" post 2>/dev/null || true)
run_test "H8: post timing → PostToolUse" "PostToolUse" "$OUTPUT"

# H9: No timing argument → silent exit
TMPDIR_H9=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H9")
FAKE_HOME_H9=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H9")
mkdir -p "$TMPDIR_H9/.claude"
cat > "$TMPDIR_H9/.claude/skill-bus.json" << 'EOFCFG'
{"inserts": {"x": {"text": "y"}}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre"}]}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H9" make_dispatch_input "test:skill" "$TMPDIR_H9" | bash "$DISPATCH_SH" 2>/dev/null || true)
run_test_empty "H9: no timing argument → silent exit" "$OUTPUT"

# H10: Skill name with special chars (dots) → handled safely
TMPDIR_H10=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H10")
FAKE_HOME_H10=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H10")
mkdir -p "$TMPDIR_H10/.claude"
cat > "$TMPDIR_H10/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h10-insert": {"text": "H10_SPECIAL_CHARS"}},
  "subscriptions": [{"insert": "h10-insert", "on": "my.plugin:v2.0", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H10" make_dispatch_input "my.plugin:v2.0" "$TMPDIR_H10" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H10: special chars in skill name → handled" "H10_SPECIAL_CHARS" "$OUTPUT"

# H11: CWD in JSON used (not PWD) → correct project config loaded
TMPDIR_H11=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H11")
TMPDIR_H11_OTHER=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H11_OTHER")
FAKE_HOME_H11=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H11")
mkdir -p "$TMPDIR_H11/.claude"
cat > "$TMPDIR_H11/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h11-insert": {"text": "H11_CWD_USED"}},
  "subscriptions": [{"insert": "h11-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
# CWD in JSON points to TMPDIR_H11, but we run from a different directory
OUTPUT=$(HOME="$FAKE_HOME_H11" make_dispatch_input "test:skill" "$TMPDIR_H11" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H11: CWD from JSON used for project config" "H11_CWD_USED" "$OUTPUT"

# H12: Only one config scope exists → subs fire
# Note: dispatch.sh uses $HOME for global config, but Python's os.path.expanduser("~")
# may not respect $HOME on macOS. So we test this via project-only config instead,
# which verifies the same code path (single config, no merge needed).
TMPDIR_H12=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H12")
FAKE_HOME_H12=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_H12")
mkdir -p "$TMPDIR_H12/.claude"
cat > "$TMPDIR_H12/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"h12-insert": {"text": "H12_SINGLE_CONFIG"}},
  "subscriptions": [{"insert": "h12-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_H12" make_dispatch_input "test:skill" "$TMPDIR_H12" | bash "$DISPATCH_SH" pre 2>/dev/null || true)
run_test "H12: single config scope → subs fire" "H12_SINGLE_CONFIG" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group I: Prompt Monitor (prompt-monitor.sh) — 10 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group I: Prompt Monitor (prompt-monitor.sh) ==="

# I1: monitorSlashCommands=false → silent exit
TMPDIR_I1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I1")
FAKE_HOME_I1=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I1")
mkdir -p "$TMPDIR_I1/.claude"
cat > "$TMPDIR_I1/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": false},
  "inserts": {"i1": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i1", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I1" make_prompt_input "/test:skill" "$TMPDIR_I1" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I1: monitorSlashCommands=false → silent exit" "$OUTPUT"

# I2: monitorSlashCommands=true, slash command matches → output returned
TMPDIR_I2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I2")
FAKE_HOME_I2=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I2")
mkdir -p "$TMPDIR_I2/.claude"
cat > "$TMPDIR_I2/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i2": {"text": "I2_PROMPT_FIRES"}},
  "subscriptions": [{"insert": "i2", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I2" make_prompt_input "/writing-plans" "$TMPDIR_I2" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test "I2: monitor=true, slash match → fires" "I2_PROMPT_FIRES" "$OUTPUT"

# I3: Non-slash prompt → silent exit
TMPDIR_I3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I3")
FAKE_HOME_I3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I3")
mkdir -p "$TMPDIR_I3/.claude"
cat > "$TMPDIR_I3/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i3": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i3", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I3" make_prompt_input "just a normal prompt" "$TMPDIR_I3" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I3: non-slash prompt → silent exit" "$OUTPUT"

# I4: Built-in command (/help) → silent exit
TMPDIR_I4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I4")
FAKE_HOME_I4=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I4")
mkdir -p "$TMPDIR_I4/.claude"
cat > "$TMPDIR_I4/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i4": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i4", "on": "help", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I4" make_prompt_input "/help" "$TMPDIR_I4" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I4: built-in /help → silent exit" "$OUTPUT"

# I5: Built-in command (/clear) → silent exit
TMPDIR_I5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I5")
FAKE_HOME_I5=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I5")
mkdir -p "$TMPDIR_I5/.claude"
cat > "$TMPDIR_I5/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i5": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i5", "on": "clear", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I5" make_prompt_input "/clear" "$TMPDIR_I5" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I5: built-in /clear → silent exit" "$OUTPUT"

# I6: Empty prompt → silent exit
TMPDIR_I6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I6")
FAKE_HOME_I6=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I6")
mkdir -p "$TMPDIR_I6/.claude"
cat > "$TMPDIR_I6/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i6": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i6", "on": "*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I6" make_prompt_input "" "$TMPDIR_I6" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I6: empty prompt → silent exit" "$OUTPUT"

# I7: Prompt with args (/my-command arg1) → command name extracted correctly
TMPDIR_I7=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I7")
FAKE_HOME_I7=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I7")
mkdir -p "$TMPDIR_I7/.claude"
cat > "$TMPDIR_I7/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i7": {"text": "I7_ARGS_STRIPPED"}},
  "subscriptions": [{"insert": "i7", "on": "superpowers:my-command", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I7" make_prompt_input "/my-command arg1 arg2" "$TMPDIR_I7" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test "I7: prompt with args → command name extracted" "I7_ARGS_STRIPPED" "$OUTPUT"

# I8: Project overrides global monitorSlashCommands=true → project false wins
TMPDIR_I8=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I8")
FAKE_HOME_I8=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I8")
mkdir -p "$FAKE_HOME_I8/.claude"
cat > "$FAKE_HOME_I8/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i8": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "i8", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_I8/.claude"
cat > "$TMPDIR_I8/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": false}
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I8" make_prompt_input "/writing-plans" "$TMPDIR_I8" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I8: project overrides global monitorSlashCommands=false" "$OUTPUT"

# I9: Project sets monitorSlashCommands=true, global doesn't → fires
# Put both monitor setting AND inserts/subscriptions in project config to avoid HOME/~ mismatch
TMPDIR_I9=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I9")
FAKE_HOME_I9=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I9")
mkdir -p "$TMPDIR_I9/.claude"
cat > "$TMPDIR_I9/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i9": {"text": "I9_PROJECT_MONITOR_ON"}},
  "subscriptions": [{"insert": "i9", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I9" make_prompt_input "/writing-plans" "$TMPDIR_I9" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test "I9: project enables monitor → fires" "I9_PROJECT_MONITOR_ON" "$OUTPUT"

# I10: Bare command matches qualified subscription (e.g., "writing-plans" matches "superpowers:writing-plans")
TMPDIR_I10=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I10")
FAKE_HOME_I10=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I10")
mkdir -p "$TMPDIR_I10/.claude"
cat > "$TMPDIR_I10/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {"i10": {"text": "I10_BARE_QUALIFIED"}},
  "subscriptions": [{"insert": "i10", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I10" make_prompt_input "/writing-plans" "$TMPDIR_I10" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test "I10: bare command matches qualified subscription" "I10_BARE_QUALIFIED" "$OUTPUT"

# I11: /skill-bus:complete is blocked by prompt-monitor (treated as built-in)
TMPDIR_I11=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I11")
FAKE_HOME_I11=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_I11")
mkdir -p "$TMPDIR_I11/.claude"
cat > "$TMPDIR_I11/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true, "completionHooks": true},
  "inserts": {"i11": {"text": "I11_SHOULD_NOT_FIRE"}},
  "subscriptions": [{"insert": "i11", "on": "skill-bus:complete", "when": "pre"}]
}
EOFCFG
OUTPUT=$(HOME="$FAKE_HOME_I11" make_prompt_input "/skill-bus:complete superpowers:debugging" "$TMPDIR_I11" | bash "$PROMPT_MONITOR" 2>/dev/null || true)
run_test_empty "I11: /skill-bus:complete blocked by prompt-monitor" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group J: "not" Condition Wrapper — 6 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group J: not Condition Wrapper ==="

# J1: not(fileExists) where file missing → condition passes (true)
TMPDIR_J1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J1")
mkdir -p "$TMPDIR_J1/.claude"
cat > "$TMPDIR_J1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j1": {"text": "J1_NOT_PASSES"}},
  "subscriptions": [{"insert": "j1", "on": "test:skill", "when": "pre", "conditions": [{"not": {"fileExists": "nonexistent/"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J1" --source tool 2>/dev/null || true)
run_test "J1: not(fileExists) file missing → passes" "J1_NOT_PASSES" "$OUTPUT"

# J2: not(fileExists) where file exists → condition fails (false)
TMPDIR_J2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J2")
mkdir -p "$TMPDIR_J2/.claude" "$TMPDIR_J2/docs"
cat > "$TMPDIR_J2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j2": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "j2", "on": "test:skill", "when": "pre", "conditions": [{"not": {"fileExists": "docs/"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J2" --source tool 2>/dev/null || true)
run_test_empty "J2: not(fileExists) file exists → fails" "$OUTPUT"

# J3: not(envSet) where env not set → passes
TMPDIR_J3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J3")
mkdir -p "$TMPDIR_J3/.claude"
cat > "$TMPDIR_J3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j3": {"text": "J3_NOT_ENVSET_PASSES"}},
  "subscriptions": [{"insert": "j3", "on": "test:skill", "when": "pre", "conditions": [{"not": {"envSet": "NONEXISTENT_VAR_J3"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J3" --source tool 2>/dev/null || true)
run_test "J3: not(envSet) env not set → passes" "J3_NOT_ENVSET_PASSES" "$OUTPUT"

# J4: not(envSet) where env is set → fails
TMPDIR_J4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J4")
mkdir -p "$TMPDIR_J4/.claude"
cat > "$TMPDIR_J4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j4": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "j4", "on": "test:skill", "when": "pre", "conditions": [{"not": {"envSet": "J4_TEST_VAR"}}]}]
}
EOFCFG
OUTPUT=$(J4_TEST_VAR=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J4" --source tool 2>/dev/null || true)
run_test_empty "J4: not(envSet) env is set → fails" "$OUTPUT"

# J5: Double negation not(not(fileExists)) → warns + evaluates correctly
TMPDIR_J5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J5")
mkdir -p "$TMPDIR_J5/.claude" "$TMPDIR_J5/docs"
cat > "$TMPDIR_J5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j5": {"text": "J5_DOUBLE_NEG"}},
  "subscriptions": [{"insert": "j5", "on": "test:skill", "when": "pre", "conditions": [{"not": {"not": {"fileExists": "docs/"}}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_DEBUG=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J5" --source tool 2>/dev/null || true)
run_test "J5: double negation → fires (docs/ exists)" "J5_DOUBLE_NEG" "$OUTPUT"

# J6: not wrapping non-dict → warning, treated as false
TMPDIR_J6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J6")
mkdir -p "$TMPDIR_J6/.claude"
cat > "$TMPDIR_J6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"j6": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "j6", "on": "test:skill", "when": "pre", "conditions": [{"not": "just-a-string"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_J6" --source tool 2>/dev/null || true)
# Sub doesn't fire (correct), but dispatcher emits a warning in systemMessage explaining why
run_test "J6: not wrapping non-dict → warning" "must wrap a condition object" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group K: envEquals at Dispatch Level — 6 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group K: envEquals at Dispatch Level ==="

# K1: envEquals matches → subscription fires
TMPDIR_K1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K1")
mkdir -p "$TMPDIR_K1/.claude"
cat > "$TMPDIR_K1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k1": {"text": "K1_ENVEQUALS_MATCH"}},
  "subscriptions": [{"insert": "k1", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"var": "K1_VAR", "value": "hello"}}]}]
}
EOFCFG
OUTPUT=$(K1_VAR=hello SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K1" --source tool 2>/dev/null || true)
run_test "K1: envEquals matches → fires" "K1_ENVEQUALS_MATCH" "$OUTPUT"

# K2: envEquals doesn't match → subscription skipped
TMPDIR_K2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K2")
mkdir -p "$TMPDIR_K2/.claude"
cat > "$TMPDIR_K2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k2": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "k2", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"var": "K2_VAR", "value": "hello"}}]}]
}
EOFCFG
OUTPUT=$(K2_VAR=world SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K2" --source tool 2>/dev/null || true)
run_test_empty "K2: envEquals doesn't match → skipped" "$OUTPUT"

# K3: envEquals with missing var field → warning, skipped
TMPDIR_K3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K3")
mkdir -p "$TMPDIR_K3/.claude"
cat > "$TMPDIR_K3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k3": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "k3", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"value": "hello"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K3" --source tool 2>/dev/null || true)
run_test "K3: envEquals missing var → warning" "missing" "$OUTPUT"

# K4: envEquals with missing value → warning, skipped
TMPDIR_K4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K4")
mkdir -p "$TMPDIR_K4/.claude"
cat > "$TMPDIR_K4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k4": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "k4", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"var": "K4_VAR"}}]}]
}
EOFCFG
OUTPUT=$(K4_VAR=hello SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K4" --source tool 2>/dev/null || true)
run_test "K4: envEquals missing value → warning" "missing" "$OUTPUT"

# K5: envEquals with integer value (not string) → warning, skipped
TMPDIR_K5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K5")
mkdir -p "$TMPDIR_K5/.claude"
cat > "$TMPDIR_K5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k5": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "k5", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"var": "K5_VAR", "value": 3000}}]}]
}
EOFCFG
OUTPUT=$(K5_VAR=3000 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K5" --source tool 2>/dev/null || true)
run_test "K5: envEquals integer value → warning" "must be a string" "$OUTPUT"

# K6: envEquals var not set → skipped (empty string != expected)
TMPDIR_K6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_K6")
mkdir -p "$TMPDIR_K6/.claude"
cat > "$TMPDIR_K6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"k6": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "k6", "on": "test:skill", "when": "pre", "conditions": [{"envEquals": {"var": "NONEXISTENT_K6_VAR", "value": "hello"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_K6" --source tool 2>/dev/null || true)
run_test_empty "K6: envEquals var not set → skipped" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group L: gitBranch Condition — 5 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group L: gitBranch Condition ==="

# Create a temp git repo for gitBranch tests
TMPDIR_L=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_L")
git -C "$TMPDIR_L" init -b feature/my-branch >/dev/null 2>&1
# Minimal config to avoid git warnings
git -C "$TMPDIR_L" config user.email "test@test.com" >/dev/null 2>&1
git -C "$TMPDIR_L" config user.name "Test" >/dev/null 2>&1
# Need at least one commit for branch to exist
touch "$TMPDIR_L/dummy"
git -C "$TMPDIR_L" add dummy >/dev/null 2>&1
git -C "$TMPDIR_L" commit -m "init" >/dev/null 2>&1

# L1: gitBranch matches current branch → fires
mkdir -p "$TMPDIR_L/.claude"
cat > "$TMPDIR_L/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"l1": {"text": "L1_BRANCH_MATCH"}},
  "subscriptions": [{"insert": "l1", "on": "test:skill", "when": "pre", "conditions": [{"gitBranch": "feature/my-branch"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_L" --source tool 2>/dev/null || true)
run_test "L1: gitBranch matches current branch → fires" "L1_BRANCH_MATCH" "$OUTPUT"

# L2: gitBranch doesn't match → skipped
cat > "$TMPDIR_L/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"l2": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "l2", "on": "test:skill", "when": "pre", "conditions": [{"gitBranch": "main"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_L" --source tool 2>/dev/null || true)
run_test_empty "L2: gitBranch doesn't match → skipped" "$OUTPUT"

# L3: gitBranch with wildcard pattern → fires
cat > "$TMPDIR_L/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"l3": {"text": "L3_BRANCH_WILDCARD"}},
  "subscriptions": [{"insert": "l3", "on": "test:skill", "when": "pre", "conditions": [{"gitBranch": "feature/*"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_L" --source tool 2>/dev/null || true)
run_test "L3: gitBranch wildcard → fires" "L3_BRANCH_WILDCARD" "$OUTPUT"

# L4: Not a git repo → condition fails silently
TMPDIR_L4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_L4")
mkdir -p "$TMPDIR_L4/.claude"
cat > "$TMPDIR_L4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"l4": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "l4", "on": "test:skill", "when": "pre", "conditions": [{"gitBranch": "*"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_L4" --source tool 2>/dev/null || true)
run_test_empty "L4: not a git repo → condition fails silently" "$OUTPUT"

# L5: not(gitBranch("main")) on non-main branch → fires
cat > "$TMPDIR_L/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"l5": {"text": "L5_NOT_MAIN"}},
  "subscriptions": [{"insert": "l5", "on": "test:skill", "when": "pre", "conditions": [{"not": {"gitBranch": "main"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_L" --source tool 2>/dev/null || true)
run_test "L5: not(gitBranch(main)) on feature branch → fires" "L5_NOT_MAIN" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group M: maxMatchesPerSkill — 5 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group M: maxMatchesPerSkill ==="

# M1: 4 matching subs, maxMatchesPerSkill=3 → only 3 fire, warning logged
TMPDIR_M1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_M1")
mkdir -p "$TMPDIR_M1/.claude"
cat > "$TMPDIR_M1/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"maxMatchesPerSkill": 3},
  "inserts": {
    "m1a": {"text": "M1A"},
    "m1b": {"text": "M1B"},
    "m1c": {"text": "M1C"},
    "m1d": {"text": "M1D"}
  },
  "subscriptions": [
    {"insert": "m1a", "on": "test:skill", "when": "pre"},
    {"insert": "m1b", "on": "test:skill", "when": "pre"},
    {"insert": "m1c", "on": "test:skill", "when": "pre"},
    {"insert": "m1d", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_M1" --source tool 2>/dev/null || true)
run_test "M1: 4 subs, max=3 → warning" "maxMatchesPerSkill=3" "$OUTPUT"
run_test "M1: first 3 fire (M1A present)" "M1A" "$OUTPUT"
run_test_absent "M1: 4th blocked (M1D absent)" "M1D" "$OUTPUT"

# M2: 2 matching subs, maxMatchesPerSkill=5 → both fire, no warning
TMPDIR_M2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_M2")
mkdir -p "$TMPDIR_M2/.claude"
cat > "$TMPDIR_M2/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"maxMatchesPerSkill": 5},
  "inserts": {"m2a": {"text": "M2A"}, "m2b": {"text": "M2B"}},
  "subscriptions": [
    {"insert": "m2a", "on": "test:skill", "when": "pre"},
    {"insert": "m2b", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_M2" --source tool 2>/dev/null || true)
run_test "M2: both fire (M2A)" "M2A" "$OUTPUT"
run_test "M2: both fire (M2B)" "M2B" "$OUTPUT"
run_test_absent "M2: no warning" "maxMatchesPerSkill" "$OUTPUT"

# M3: maxMatchesPerSkill=1 → only first fires
TMPDIR_M3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_M3")
mkdir -p "$TMPDIR_M3/.claude"
cat > "$TMPDIR_M3/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"maxMatchesPerSkill": 1},
  "inserts": {"m3a": {"text": "M3A_FIRST"}, "m3b": {"text": "M3B_SECOND"}},
  "subscriptions": [
    {"insert": "m3a", "on": "test:skill", "when": "pre"},
    {"insert": "m3b", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_M3" --source tool 2>/dev/null || true)
run_test "M3: max=1, first fires" "M3A_FIRST" "$OUTPUT"
run_test_absent "M3: second blocked" "M3B_SECOND" "$OUTPUT"

# M4: Invalid maxMatchesPerSkill (string "3") → warning, default to 3
TMPDIR_M4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_M4")
mkdir -p "$TMPDIR_M4/.claude"
cat > "$TMPDIR_M4/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"maxMatchesPerSkill": "3"},
  "inserts": {"m4": {"text": "M4_FALLBACK"}},
  "subscriptions": [{"insert": "m4", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_M4" --source tool 2>/dev/null || true)
run_test "M4: string maxMatches → warning" "invalid maxMatchesPerSkill" "$OUTPUT"
run_test "M4: still fires with default" "M4_FALLBACK" "$OUTPUT"

# M5: maxMatchesPerSkill=0 → warning, default to 3
TMPDIR_M5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_M5")
mkdir -p "$TMPDIR_M5/.claude"
cat > "$TMPDIR_M5/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"maxMatchesPerSkill": 0},
  "inserts": {"m5": {"text": "M5_ZERO_FALLBACK"}},
  "subscriptions": [{"insert": "m5", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_M5" --source tool 2>/dev/null || true)
run_test "M5: maxMatches=0 → warning" "invalid maxMatchesPerSkill" "$OUTPUT"
run_test "M5: still fires with default" "M5_ZERO_FALLBACK" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group N: enabled:false at Dispatch Level — 6 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group N: enabled:false at Dispatch Level ==="

# N1: Global settings enabled=false → no output (entire plugin disabled)
TMPDIR_N1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_N1")
mkdir -p "$TMPDIR_N1/.claude"
cat > "$TMPDIR_N1/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"enabled": false},
  "inserts": {"n1": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "n1", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_N1" --source tool 2>/dev/null || true)
run_test "N1: enabled=false → disabled message" "Disabled via settings" "$OUTPUT"
run_test_absent "N1: enabled=false → insert not fired" "SHOULD_NOT_APPEAR" "$OUTPUT"

# N2: Project sub with enabled=false disables matching global sub
# Use cli.py list (supports SKILL_BUS_GLOBAL_CONFIG) which shows overridden subs as "disabled in project"
TMPDIR_N2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_N2")
FAKE_HOME_N2=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_N2")
FAKE_GLOBAL_N2="$FAKE_HOME_N2/skill-bus.json"
cat > "$FAKE_GLOBAL_N2" << 'EOFCFG'
{
  "inserts": {"n2-insert": {"text": "SHOULD_NOT_APPEAR_N2"}},
  "subscriptions": [{"insert": "n2-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_N2/.claude"
cat > "$TMPDIR_N2/.claude/skill-bus.json" << 'EOFCFG'
{
  "subscriptions": [{"insert": "n2-insert", "on": "test:skill", "when": "pre", "enabled": false}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_N2" python3 "$CLI" list --cwd "$TMPDIR_N2" 2>/dev/null || true)
run_test "N2: project enabled=false disables global sub" "disabled in project" "$OUTPUT"

# N3: Project insert-level override (enabled=false, no on/when) disables all global subs for that insert
TMPDIR_N3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_N3")
FAKE_HOME_N3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_N3")
FAKE_GLOBAL_N3="$FAKE_HOME_N3/skill-bus.json"
cat > "$FAKE_GLOBAL_N3" << 'EOFCFG'
{
  "inserts": {"n3-insert": {"text": "SHOULD_NOT_APPEAR_N3"}},
  "subscriptions": [
    {"insert": "n3-insert", "on": "test:skill", "when": "pre"},
    {"insert": "n3-insert", "on": "test:other", "when": "pre"}
  ]
}
EOFCFG
mkdir -p "$TMPDIR_N3/.claude"
cat > "$TMPDIR_N3/.claude/skill-bus.json" << 'EOFCFG'
{
  "subscriptions": [{"insert": "n3-insert", "enabled": false}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_N3" python3 "$CLI" list --cwd "$TMPDIR_N3" 2>/dev/null || true)
run_test "N3: insert-level override → disabled in project" "disabled in project" "$OUTPUT"

# N4: Project sub enabled=false but different on pattern → global sub still fires
TMPDIR_N4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_N4")
FAKE_HOME_N4=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_N4")
FAKE_GLOBAL_N4="$FAKE_HOME_N4/skill-bus.json"
cat > "$FAKE_GLOBAL_N4" << 'EOFCFG'
{
  "inserts": {"n4-insert": {"text": "N4_STILL_FIRES"}},
  "subscriptions": [
    {"insert": "n4-insert", "on": "test:skill", "when": "pre"},
    {"insert": "n4-insert", "on": "test:other", "when": "pre"}
  ]
}
EOFCFG
mkdir -p "$TMPDIR_N4/.claude"
cat > "$TMPDIR_N4/.claude/skill-bus.json" << 'EOFCFG'
{
  "subscriptions": [{"insert": "n4-insert", "on": "test:other", "when": "pre", "enabled": false}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_N4" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_N4" --timing pre 2>/dev/null || true)
run_test "N4: different pattern disabled → original still fires" "fires" "$OUTPUT"

# N5: disableGlobal=true → global subs skipped, project subs fire
TMPDIR_N5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_N5")
FAKE_HOME_N5=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_N5")
FAKE_GLOBAL_N5="$FAKE_HOME_N5/skill-bus.json"
cat > "$FAKE_GLOBAL_N5" << 'EOFCFG'
{
  "inserts": {"n5-global": {"text": "N5_GLOBAL_SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "n5-global", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_N5/.claude"
cat > "$TMPDIR_N5/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"disableGlobal": true},
  "inserts": {"n5-project": {"text": "N5_PROJECT_FIRES"}},
  "subscriptions": [{"insert": "n5-project", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_N5" SKILL_BUS_SKILL="test:skill" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_N5" --timing pre 2>/dev/null || true)
run_test "N5: disableGlobal → project fires" "fires" "$OUTPUT"
run_test_absent "N5: global skipped" "N5_GLOBAL_SHOULD_NOT_APPEAR" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group O: fileContains Edge Cases — 7 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group O: fileContains Edge Cases ==="

# O1: File >1MB → condition returns false (guard)
TMPDIR_O1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O1")
mkdir -p "$TMPDIR_O1/.claude"
# Create a file > 1MB
dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\0' 'A' > "$TMPDIR_O1/large.txt"
echo "needle" >> "$TMPDIR_O1/large.txt"
cat > "$TMPDIR_O1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o1": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "o1", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "large.txt", "pattern": "needle"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O1" --source tool 2>/dev/null || true)
run_test "O1: file >1MB → warning emitted" "fileContains skipped" "$OUTPUT"
run_test_absent "O1: file >1MB → insert not fired" "SHOULD_NOT_APPEAR" "$OUTPUT"

# O2: File doesn't exist → false (silent)
TMPDIR_O2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O2")
mkdir -p "$TMPDIR_O2/.claude"
cat > "$TMPDIR_O2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o2": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "o2", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "nonexistent.txt", "pattern": "hello"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O2" --source tool 2>/dev/null || true)
run_test_empty "O2: file doesn't exist → false" "$OUTPUT"

# O3: fileContains missing "pattern" field → warning, false
TMPDIR_O3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O3")
mkdir -p "$TMPDIR_O3/.claude"
echo "some content" > "$TMPDIR_O3/test.txt"
cat > "$TMPDIR_O3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o3": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "o3", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "test.txt"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O3" --source tool 2>/dev/null || true)
run_test "O3: fileContains missing pattern → warning" "missing" "$OUTPUT"

# O4: fileContains missing "file" field → warning, false
TMPDIR_O4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O4")
mkdir -p "$TMPDIR_O4/.claude"
cat > "$TMPDIR_O4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o4": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "o4", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"pattern": "hello"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O4" --source tool 2>/dev/null || true)
run_test "O4: fileContains missing file → warning" "missing" "$OUTPUT"

# O5: fileContains with non-dict value → warning, false
TMPDIR_O5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O5")
mkdir -p "$TMPDIR_O5/.claude"
cat > "$TMPDIR_O5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o5": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "o5", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": "just-a-string"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O5" --source tool 2>/dev/null || true)
run_test "O5: fileContains non-dict → warning" "WARNING" "$OUTPUT"

# O6: Binary file (non-UTF8) → errors="replace" handles gracefully
TMPDIR_O6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_O6")
mkdir -p "$TMPDIR_O6/.claude"
printf '\x80\x81\x82needle\x83\x84' > "$TMPDIR_O6/binary.bin"
cat > "$TMPDIR_O6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"o6": {"text": "O6_BINARY_OK"}},
  "subscriptions": [{"insert": "o6", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "binary.bin", "pattern": "needle"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_O6" --source tool 2>/dev/null || true)
run_test "O6: binary file → handled gracefully" "O6_BINARY_OK" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group P: Config Merge & Edge Cases — 8 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group P: Config Merge & Edge Cases ==="

# P1: Insert name collision → project wins (project-wins semantics)
TMPDIR_P1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P1")
FAKE_GLOBAL_P1=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P1")
cat > "$FAKE_GLOBAL_P1/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"conflict-insert": {"text": "GLOBAL_VERSION"}},
  "subscriptions": [{"insert": "conflict-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_P1/.claude"
cat > "$TMPDIR_P1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"conflict-insert": {"text": "PROJECT_VERSION"}},
  "subscriptions": [{"insert": "conflict-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P1/skill-bus.json" SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_P1" --source tool 2>/dev/null || true)
run_test "P1: insert collision → project version used" "PROJECT_VERSION" "$OUTPUT"
run_test_absent "P1: global version not used" "GLOBAL_VERSION" "$OUTPUT"

# P2: Global + project both have subs, no conflict → both fire
TMPDIR_P2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P2")
FAKE_GLOBAL_P2=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P2")
cat > "$FAKE_GLOBAL_P2/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p2-global": {"text": "P2_GLOBAL"}},
  "subscriptions": [{"insert": "p2-global", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_P2/.claude"
cat > "$TMPDIR_P2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p2-project": {"text": "P2_PROJECT"}},
  "subscriptions": [{"insert": "p2-project", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P2/skill-bus.json" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_P2" --timing pre 2>/dev/null || true)
run_test "P2: global sub fires" "p2-global" "$OUTPUT"
run_test "P2: project sub fires" "p2-project" "$OUTPUT"

# P3: Project overrides specific global sub (Level 1: exact tuple)
TMPDIR_P3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P3")
FAKE_GLOBAL_P3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P3")
cat > "$FAKE_GLOBAL_P3/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p3-insert": {"text": "P3_TEXT"}},
  "subscriptions": [
    {"insert": "p3-insert", "on": "test:skill", "when": "pre"},
    {"insert": "p3-insert", "on": "test:other", "when": "pre"}
  ]
}
EOFCFG
mkdir -p "$TMPDIR_P3/.claude"
cat > "$TMPDIR_P3/.claude/skill-bus.json" << 'EOFCFG'
{
  "subscriptions": [{"insert": "p3-insert", "on": "test:skill", "when": "pre", "enabled": false}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P3/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_P3" 2>/dev/null || true)
run_test "P3: specific override → disabled in project" "disabled in project" "$OUTPUT"
# test:other should still be listed
run_test "P3: other sub still active" "test:other" "$OUTPUT"

# P4: Project overrides all subs for insert (Level 2: insert-name only)
TMPDIR_P4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P4")
FAKE_GLOBAL_P4=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P4")
cat > "$FAKE_GLOBAL_P4/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p4-insert": {"text": "P4_TEXT"}},
  "subscriptions": [
    {"insert": "p4-insert", "on": "test:skill", "when": "pre"},
    {"insert": "p4-insert", "on": "test:other", "when": "post"}
  ]
}
EOFCFG
mkdir -p "$TMPDIR_P4/.claude"
cat > "$TMPDIR_P4/.claude/skill-bus.json" << 'EOFCFG'
{
  "subscriptions": [{"insert": "p4-insert", "enabled": false}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P4/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_P4" 2>/dev/null || true)
# Both global subs should be disabled
run_test "P4: all subs for insert disabled" "disabled in project" "$OUTPUT"

# P5: Malformed JSON in global config → warning, continues with project only
TMPDIR_P5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P5")
FAKE_GLOBAL_P5=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P5")
echo '{bad json!!!' > "$FAKE_GLOBAL_P5/skill-bus.json"
mkdir -p "$TMPDIR_P5/.claude"
cat > "$TMPDIR_P5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p5": {"text": "P5_PROJECT_ONLY"}},
  "subscriptions": [{"insert": "p5", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P5/skill-bus.json" SKILL_BUS_SKILL="test:skill" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_P5" --timing pre 2>&1 || true)
run_test "P5: malformed global → project still fires" "fires" "$OUTPUT"

# P6: Malformed JSON in project config → warning, continues with global only
TMPDIR_P6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P6")
FAKE_GLOBAL_P6=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_P6")
cat > "$FAKE_GLOBAL_P6/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"p6": {"text": "P6_GLOBAL_ONLY"}},
  "subscriptions": [{"insert": "p6", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_P6/.claude"
echo '{bad project json!!!' > "$TMPDIR_P6/.claude/skill-bus.json"
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_P6/skill-bus.json" SKILL_BUS_SKILL="test:skill" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_P6" --timing pre 2>&1 || true)
run_test "P6: malformed project → global still fires" "fires" "$OUTPUT"

# P7: Empty inserts/subscriptions keys → no crash
TMPDIR_P7=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P7")
mkdir -p "$TMPDIR_P7/.claude"
cat > "$TMPDIR_P7/.claude/skill-bus.json" << 'EOFCFG'
{"inserts": {}, "subscriptions": []}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_P7" --source tool 2>/dev/null || true)
run_test_empty "P7: empty inserts/subscriptions → no crash" "$OUTPUT"

# P8: Config with extra unknown keys → ignored gracefully
TMPDIR_P8=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_P8")
mkdir -p "$TMPDIR_P8/.claude"
cat > "$TMPDIR_P8/.claude/skill-bus.json" << 'EOFCFG'
{
  "futureKey": true,
  "anotherUnknown": {"nested": "data"},
  "inserts": {"p8": {"text": "P8_EXTRA_KEYS_OK"}},
  "subscriptions": [{"insert": "p8", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_P8" --source tool 2>/dev/null || true)
run_test "P8: extra unknown keys → ignored gracefully" "P8_EXTRA_KEYS_OK" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group Q: Wildcard Pattern Matching — 6 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group Q: Wildcard Pattern Matching ==="

# Q1: Pattern `*` matches any skill
TMPDIR_Q1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q1")
mkdir -p "$TMPDIR_Q1/.claude"
cat > "$TMPDIR_Q1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q1": {"text": "Q1_STAR_MATCH"}},
  "subscriptions": [{"insert": "q1", "on": "*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="anything:at-all" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q1" --source tool 2>/dev/null || true)
run_test "Q1: pattern * matches any skill" "Q1_STAR_MATCH" "$OUTPUT"

# Q2: Pattern `superpowers:*` matches `superpowers:writing-plans`
TMPDIR_Q2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q2")
mkdir -p "$TMPDIR_Q2/.claude"
cat > "$TMPDIR_Q2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q2": {"text": "Q2_PREFIX_MATCH"}},
  "subscriptions": [{"insert": "q2", "on": "superpowers:*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="superpowers:writing-plans" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q2" --source tool 2>/dev/null || true)
run_test "Q2: superpowers:* matches superpowers:writing-plans" "Q2_PREFIX_MATCH" "$OUTPUT"

# Q3: Pattern `superpowers:*` does NOT match `other:skill`
TMPDIR_Q3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q3")
mkdir -p "$TMPDIR_Q3/.claude"
cat > "$TMPDIR_Q3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q3": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "q3", "on": "superpowers:*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="other:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q3" --source tool 2>/dev/null || true)
run_test_empty "Q3: superpowers:* does NOT match other:skill" "$OUTPUT"

# Q4: Pattern `*:writing-*` matches `superpowers:writing-plans`
TMPDIR_Q4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q4")
mkdir -p "$TMPDIR_Q4/.claude"
cat > "$TMPDIR_Q4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q4": {"text": "Q4_MULTI_WILD"}},
  "subscriptions": [{"insert": "q4", "on": "*:writing-*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="superpowers:writing-plans" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q4" --source tool 2>/dev/null || true)
run_test "Q4: *:writing-* matches superpowers:writing-plans" "Q4_MULTI_WILD" "$OUTPUT"

# Q5: Pattern with `?` single-char wildcard
TMPDIR_Q5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q5")
mkdir -p "$TMPDIR_Q5/.claude"
cat > "$TMPDIR_Q5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q5": {"text": "Q5_QUESTION_WILD"}},
  "subscriptions": [{"insert": "q5", "on": "test:sk?ll", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q5" --source tool 2>/dev/null || true)
run_test "Q5: ? wildcard matches single char" "Q5_QUESTION_WILD" "$OUTPUT"

# Q6: Exact pattern match (no wildcards)
TMPDIR_Q6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_Q6")
mkdir -p "$TMPDIR_Q6/.claude"
cat > "$TMPDIR_Q6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"q6": {"text": "Q6_EXACT_MATCH"}},
  "subscriptions": [{"insert": "q6", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="superpowers:writing-plans" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_Q6" --source tool 2>/dev/null || true)
run_test "Q6: exact match" "Q6_EXACT_MATCH" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group R: Multi-Subscription & Output — 6 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group R: Multi-Subscription & Output ==="

# R1: 3 different inserts fire → combined context has all 3 texts
TMPDIR_R1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R1")
mkdir -p "$TMPDIR_R1/.claude"
cat > "$TMPDIR_R1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "r1a": {"text": "R1_FIRST_TEXT"},
    "r1b": {"text": "R1_SECOND_TEXT"},
    "r1c": {"text": "R1_THIRD_TEXT"}
  },
  "subscriptions": [
    {"insert": "r1a", "on": "test:skill", "when": "pre"},
    {"insert": "r1b", "on": "test:skill", "when": "pre"},
    {"insert": "r1c", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R1" --source tool 2>/dev/null || true)
run_test "R1: 3 inserts, first present" "R1_FIRST_TEXT" "$OUTPUT"
run_test "R1: 3 inserts, second present" "R1_SECOND_TEXT" "$OUTPUT"
run_test "R1: 3 inserts, third present" "R1_THIRD_TEXT" "$OUTPUT"

# R2: Sub 1 fires, Sub 2 fails condition → only Sub 1 text in output
TMPDIR_R2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R2")
mkdir -p "$TMPDIR_R2/.claude"
cat > "$TMPDIR_R2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "r2a": {"text": "R2_FIRES"},
    "r2b": {"text": "R2_SHOULD_NOT_APPEAR"}
  },
  "subscriptions": [
    {"insert": "r2a", "on": "test:skill", "when": "pre"},
    {"insert": "r2b", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "NONEXISTENT_R2_VAR"}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R2" --source tool 2>/dev/null || true)
run_test "R2: sub 1 fires" "R2_FIRES" "$OUTPUT"
run_test_absent "R2: sub 2 condition fails" "R2_SHOULD_NOT_APPEAR" "$OUTPUT"

# R3: Same insert subscribed to 2 different skills → only matching skill fires
TMPDIR_R3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R3")
mkdir -p "$TMPDIR_R3/.claude"
cat > "$TMPDIR_R3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"r3": {"text": "R3_SHARED_INSERT"}},
  "subscriptions": [
    {"insert": "r3", "on": "test:skill-a", "when": "pre"},
    {"insert": "r3", "on": "test:skill-b", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill-a" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R3" --source tool 2>/dev/null || true)
run_test "R3: shared insert, matching skill fires" "R3_SHARED_INSERT" "$OUTPUT"
# Verify only 1 sub matched (check the console echo)
run_test "R3: only 1 sub matched" "1 sub(s)" "$OUTPUT"

# R4: Pre and post subs for same skill → only correct timing fires
TMPDIR_R4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R4")
mkdir -p "$TMPDIR_R4/.claude"
cat > "$TMPDIR_R4/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "r4-pre": {"text": "R4_PRE_ONLY"},
    "r4-post": {"text": "R4_POST_ONLY"}
  },
  "subscriptions": [
    {"insert": "r4-pre", "on": "test:skill", "when": "pre"},
    {"insert": "r4-post", "on": "test:skill", "when": "post"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R4" --source tool 2>/dev/null || true)
run_test "R4: pre timing → pre text" "R4_PRE_ONLY" "$OUTPUT"
run_test_absent "R4: pre timing → no post text" "R4_POST_ONLY" "$OUTPUT"

# R5: Dangling insert reference → warning in systemMessage
TMPDIR_R5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R5")
mkdir -p "$TMPDIR_R5/.claude"
cat > "$TMPDIR_R5/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {},
  "subscriptions": [{"insert": "nonexistent-insert", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R5" --source tool 2>/dev/null || true)
run_test "R5: dangling insert → warning" "dangling insert reference" "$OUTPUT"

# R6: Empty insert text ("") → skipped, not included in output
TMPDIR_R6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_R6")
mkdir -p "$TMPDIR_R6/.claude"
cat > "$TMPDIR_R6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "r6-empty": {"text": ""},
    "r6-real": {"text": "R6_REAL_TEXT"}
  },
  "subscriptions": [
    {"insert": "r6-empty", "on": "test:skill", "when": "pre"},
    {"insert": "r6-real", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_R6" --source tool 2>/dev/null || true)
run_test "R6: real insert fires" "R6_REAL_TEXT" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group S: Edge Cases & Error Handling — 7 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group S: Edge Cases & Error Handling ==="

# S1: Skill name empty (no SKILL_BUS_SKILL env var) → silent exit
TMPDIR_S1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S1")
mkdir -p "$TMPDIR_S1/.claude"
cat > "$TMPDIR_S1/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"s1": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "s1", "on": "*", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S1" --source tool 2>/dev/null || true)
run_test_empty "S1: empty skill name → silent exit" "$OUTPUT"

# S2: Empty conditions array `"conditions": []` → treated as no conditions (fires)
TMPDIR_S2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S2")
mkdir -p "$TMPDIR_S2/.claude"
cat > "$TMPDIR_S2/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"s2": {"text": "S2_EMPTY_CONDS_FIRES"}},
  "subscriptions": [{"insert": "s2", "on": "test:skill", "when": "pre", "conditions": []}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S2" --source tool 2>/dev/null || true)
run_test "S2: empty conditions array → fires" "S2_EMPTY_CONDS_FIRES" "$OUTPUT"

# S3: Condition with unknown type → warning, treated as false
TMPDIR_S3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S3")
mkdir -p "$TMPDIR_S3/.claude"
cat > "$TMPDIR_S3/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"s3": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "s3", "on": "test:skill", "when": "pre", "conditions": [{"futureType": "value"}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S3" --source tool 2>/dev/null || true)
run_test "S3: unknown condition type → warning" "unknown condition type" "$OUTPUT"

# S4: showConsoleEcho=false → no console echo in systemMessage
TMPDIR_S4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S4")
mkdir -p "$TMPDIR_S4/.claude"
cat > "$TMPDIR_S4/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"showConsoleEcho": false},
  "inserts": {"s4": {"text": "S4_NO_ECHO"}},
  "subscriptions": [{"insert": "s4", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S4" --source tool 2>/dev/null || true)
run_test "S4: showConsoleEcho=false → context still present" "S4_NO_ECHO" "$OUTPUT"
run_test_absent "S4: no console echo label" "sub(s) matched" "$OUTPUT"

# S5: showConditionSkips=true → skipped sub names in systemMessage
TMPDIR_S5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S5")
mkdir -p "$TMPDIR_S5/.claude"
cat > "$TMPDIR_S5/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"showConditionSkips": true},
  "inserts": {
    "s5-pass": {"text": "S5_PASSES"},
    "s5-fail": {"text": "SHOULD_NOT_APPEAR"}
  },
  "subscriptions": [
    {"insert": "s5-pass", "on": "test:skill", "when": "pre"},
    {"insert": "s5-fail", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "NONEXISTENT_S5_VAR"}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S5" --source tool 2>/dev/null || true)
run_test "S5: showConditionSkips → skipped names shown" "skipped: s5-fail" "$OUTPUT"

# S6: Old "inject" format → error warning
TMPDIR_S6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S6")
mkdir -p "$TMPDIR_S6/.claude"
cat > "$TMPDIR_S6/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {},
  "subscriptions": [{"inject": "old format text", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S6" --source tool 2>/dev/null || true)
run_test "S6: old inject format → error warning" "old 'inject' format" "$OUTPUT"

# S7: Subscription missing "insert" field → skipped gracefully
TMPDIR_S7=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_S7")
mkdir -p "$TMPDIR_S7/.claude"
cat > "$TMPDIR_S7/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"s7": {"text": "S7_GOOD_SUB"}},
  "subscriptions": [
    {"on": "test:skill", "when": "pre"},
    {"insert": "s7", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_S7" --source tool 2>/dev/null || true)
run_test "S7: good sub still fires" "S7_GOOD_SUB" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group T: First-run nudge — 4 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group T: First-run nudge ==="

# T1: No config files, no nudge flag → nudge emitted
TMPDIR_T1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_T1")
FAKE_HOME_T1=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_T1")
mkdir -p "$TMPDIR_T1/.claude"
RESULT=$(make_dispatch_input "superpowers:writing-plans" "$TMPDIR_T1" | \
    HOME="$FAKE_HOME_T1" bash "$DISPATCH_SH" pre 2>&1)
run_test "T1: no config nudge emitted" "No subscriptions configured" "$RESULT"

# T2: Nudge flag exists → no nudge on second invocation
# (The first call in T1 created .claude/.sb-nudged in TMPDIR_T1)
RESULT2=$(make_dispatch_input "superpowers:brainstorming" "$TMPDIR_T1" | \
    HOME="$FAKE_HOME_T1" bash "$DISPATCH_SH" pre 2>&1)
run_test_absent "T2: no nudge when flag exists" "No subscriptions configured" "$RESULT2"

# T3: Config exists → no nudge (config check is first, never reaches nudge logic)
TMPDIR_T3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_T3")
FAKE_HOME_T3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_T3")
mkdir -p "$TMPDIR_T3/.claude"
cat > "$TMPDIR_T3/.claude/skill-bus.json" << 'TEOF'
{"inserts": {}, "subscriptions": []}
TEOF
RESULT=$(make_dispatch_input "superpowers:writing-plans" "$TMPDIR_T3" | \
    HOME="$FAKE_HOME_T3" bash "$DISPATCH_SH" pre 2>&1)
run_test_absent "T3: config exists no nudge" "No subscriptions configured" "$RESULT"

# T4: No .claude/ dir at all → nudge still fires (mkdir -p creates it)
TMPDIR_T4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_T4")
FAKE_HOME_T4=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_T4")
RESULT=$(make_dispatch_input "test:skill" "$TMPDIR_T4" | \
    HOME="$FAKE_HOME_T4" bash "$DISPATCH_SH" pre 2>&1)
run_test "T4: no .claude dir nudge fires" "No subscriptions configured" "$RESULT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group U: Dynamic inserts — 4 tests
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group U: Dynamic inserts ==="

# U1: Dynamic insert with telemetry data → dynamic text replaces static
TMPDIR_U1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_U1")
mkdir -p "$TMPDIR_U1/.claude"
cat > "$TMPDIR_U1/.claude/skill-bus-telemetry.jsonl" << 'UEOF'
{"ts":"2026-02-10T12:00:00+0000","sessionId":"abc123","event":"match","skill":"superpowers:writing-plans","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-10T12:01:00+0000","sessionId":"abc123","event":"match","skill":"superpowers:brainstorming","insert":"compound-knowledge","timing":"pre","source":"tool"}
UEOF
cat > "$TMPDIR_U1/.claude/skill-bus.json" << 'UEOF2'
{
  "settings": {"telemetry": true},
  "inserts": {
    "session-gaps": {
      "text": "No telemetry data available yet.",
      "dynamic": "session-stats"
    }
  },
  "subscriptions": [
    {"insert": "session-gaps", "on": "superpowers:finishing-*", "when": "pre"}
  ]
}
UEOF2
RESULT=$(SKILL_BUS_SKILL="superpowers:finishing-a-development-branch" \
    python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_U1" --source tool 2>/dev/null || true)
run_test "U1: dynamic session-stats fires" "Skills intercepted" "$RESULT"

# U2: Dynamic insert with no telemetry data → falls back to static text
TMPDIR_U2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_U2")
mkdir -p "$TMPDIR_U2/.claude"
cat > "$TMPDIR_U2/.claude/skill-bus.json" << 'UEOF3'
{
  "settings": {"telemetry": false},
  "inserts": {
    "session-gaps": {
      "text": "No telemetry data available yet.",
      "dynamic": "session-stats"
    }
  },
  "subscriptions": [
    {"insert": "session-gaps", "on": "*", "when": "pre"}
  ]
}
UEOF3
RESULT=$(SKILL_BUS_SKILL="superpowers:finishing-a-development-branch" \
    python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_U2" --source tool 2>/dev/null || true)
run_test "U2: dynamic fallback to static" "No telemetry data available yet" "$RESULT"

# U3: Unknown dynamic handler → falls back to static text + warning
TMPDIR_U3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_U3")
mkdir -p "$TMPDIR_U3/.claude"
cat > "$TMPDIR_U3/.claude/skill-bus.json" << 'UEOF4'
{
  "inserts": {
    "test-dynamic": {
      "text": "Static fallback text",
      "dynamic": "unknown-handler"
    }
  },
  "subscriptions": [
    {"insert": "test-dynamic", "on": "*", "when": "pre"}
  ]
}
UEOF4
RESULT=$(SKILL_BUS_SKILL="test:skill" \
    python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_U3" --source tool 2>/dev/null || true)
run_test "U3: unknown dynamic handler fallback" "Static fallback text" "$RESULT"

# U4: Only malformed lines in telemetry + telemetry off → handler returns None, static text used
TMPDIR_U4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_U4")
mkdir -p "$TMPDIR_U4/.claude"
cat > "$TMPDIR_U4/.claude/skill-bus-telemetry.jsonl" << 'UEOF5'
THIS IS NOT VALID JSON
UEOF5
cat > "$TMPDIR_U4/.claude/skill-bus.json" << 'UEOF6'
{
  "settings": {"telemetry": false},
  "inserts": {
    "session-gaps": {
      "text": "Fallback when handler errors",
      "dynamic": "session-stats"
    }
  },
  "subscriptions": [
    {"insert": "session-gaps", "on": "*", "when": "pre"}
  ]
}
UEOF6
RESULT=$(SKILL_BUS_SKILL="test:skill" \
    python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_U4" --source tool 2>/dev/null || true)
run_test "U4: malformed telemetry falls back to static" "Fallback when handler errors" "$RESULT"

# ═══════════════════════════════════════════════════════════════════════════════
# Group V: Onboard integration
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group V: Onboard integration ==="

# V1: scan → set → add-insert → simulate roundtrip
TMPDIR_V1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_V1")
mkdir -p "$TMPDIR_V1/.claude" "$TMPDIR_V1/docs/decisions"
echo "# Test Project" > "$TMPDIR_V1/.claude/CLAUDE.md"
echo "Decision 1" > "$TMPDIR_V1/docs/decisions/adr-001.md"

# Scan finds knowledge
SCAN=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --json --cwd "$TMPDIR_V1")
run_test "V1a: scan finds knowledge" '"knowledge":' "$SCAN"

# Set telemetry
SET_RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set telemetry true --scope project --cwd "$TMPDIR_V1")
run_test "V1b: set telemetry" "Set telemetry = true" "$SET_RESULT"

# Create a subscription via add-insert CLI (simulating what onboard would do)
SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "prior-decisions" \
    --text "Check docs/decisions/ for prior context" \
    --conditions '[{"fileExists": "docs/decisions/"}]' \
    --on "*:writing-plans" \
    --when pre \
    --scope project \
    --cwd "$TMPDIR_V1"

# Simulate matches
SIM=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "superpowers:writing-plans" --cwd "$TMPDIR_V1")
run_test "V1c: simulate after onboard setup" "prior-decisions" "$SIM"
run_test "V1d: condition passes" "fires" "$SIM"

# V2: Dynamic session-gaps insert fires in dispatch
TMPDIR_V2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_V2")
mkdir -p "$TMPDIR_V2/.claude"

# Create telemetry data
cat > "$TMPDIR_V2/.claude/skill-bus-telemetry.jsonl" << 'VEOF'
{"ts":"2026-02-10T12:00:00+0000","sessionId":"test1","event":"match","skill":"superpowers:writing-plans","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-10T12:01:00+0000","sessionId":"test1","event":"no_match","skill":"superpowers:systematic-debugging","timing":"pre","source":"tool"}
{"ts":"2026-02-10T12:02:00+0000","sessionId":"test1","event":"no_match","skill":"superpowers:systematic-debugging","timing":"pre","source":"tool"}
{"ts":"2026-02-10T12:03:00+0000","sessionId":"test1","event":"no_match","skill":"superpowers:systematic-debugging","timing":"pre","source":"tool"}
VEOF

cat > "$TMPDIR_V2/.claude/skill-bus.json" << 'VEOF2'
{
  "settings": {"telemetry": true},
  "inserts": {
    "session-gaps": {
      "text": "No telemetry data available yet.",
      "dynamic": "session-stats"
    }
  },
  "subscriptions": [
    {"insert": "session-gaps", "on": "*:finishing-*", "when": "pre"}
  ]
}
VEOF2

# Dispatch should resolve dynamic insert with stats
V2_RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" \
    SKILL_BUS_SKILL="superpowers:finishing-a-development-branch" \
    python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_V2" --source tool 2>/dev/null || true)
run_test "V2a: dynamic insert resolves" "Skills intercepted" "$V2_RESULT"
run_test "V2b: gaps detected" "systematic-debugging" "$V2_RESULT"

# V3: Nudge + config creation flow
TMPDIR_V3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_V3")
FAKE_HOME_V3=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_HOME_V3")

# No config, no .claude/ dir → nudge fires (mkdir -p creates .claude/)
NUDGE=$(make_dispatch_input "test:skill" "$TMPDIR_V3" | \
    HOME="$FAKE_HOME_V3" bash "$DISPATCH_SH" pre 2>&1)
run_test "V3a: nudge before config" "No subscriptions configured" "$NUDGE"

# Create config via set (creates .claude/skill-bus.json)
SET=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set telemetry true --scope project --cwd "$TMPDIR_V3")
run_test "V3b: set creates config" "Set telemetry = true" "$SET"

# Config exists → no nudge (config check exits before nudge logic)
NUDGE2=$(make_dispatch_input "test:skill" "$TMPDIR_V3" | \
    HOME="$FAKE_HOME_V3" bash "$DISPATCH_SH" pre 2>&1)
run_test_absent "V3c: no nudge after config created" "No subscriptions configured" "$NUDGE2"

# ═══════════════════════════════════════════════════════════════════════════════
# Group W: Complete timing support — synthetic completion hook
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Group W: Complete timing support ==="

# W1: dispatcher.py accepts --timing complete
W_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W_DIR")
mkdir -p "$W_DIR/.claude"
cat > "$W_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"post-debug": {"text": "Run compounding-solutions now."}},
  "subscriptions": [
    {"insert": "post-debug", "on": "superpowers:systematic-debugging", "when": "complete"}
  ]
}
EOF

W1_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:systematic-debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W_DIR" 2>&1)
run_test "W1: --timing complete matches when:complete sub" "Run compounding-solutions now" "$W1_OUT"

# W2: --timing pre does NOT fire complete sub's TEXT, but DOES inject completion instruction
W2_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:systematic-debugging" \
    python3 "$DISPATCHER" --timing pre --cwd "$W_DIR" 2>&1)
run_test_absent "W2a: pre timing doesn't inject complete sub text" "Run compounding-solutions now" "$W2_OUT"
run_test "W2b: pre timing injects completion instruction" "you MUST run" "$W2_OUT"

# W3: --timing post does NOT match when:complete sub
W3_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:systematic-debugging" \
    python3 "$DISPATCHER" --timing post --cwd "$W_DIR" 2>&1)
run_test_empty "W3: --timing post skips when:complete sub" "$W3_OUT"

# W4: invalid when value still warns
W4_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W4_DIR")
mkdir -p "$W4_DIR/.claude"
cat > "$W4_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"bad-timing": {"text": "should not fire"}},
  "subscriptions": [
    {"insert": "bad-timing", "on": "some:skill", "when": "bogus"}
  ]
}
EOF
W4_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="some:skill" \
    python3 "$DISPATCHER" --timing complete --cwd "$W4_DIR" 2>&1)
run_test "W4: invalid when value warns" "invalid 'when' value" "$W4_OUT"

# W5: dispatch.sh routes skill-bus:complete to Python with --timing complete
W5_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W5_DIR")
mkdir -p "$W5_DIR/.claude"
cat > "$W5_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"capture-sol": {"text": "Use compounding-solutions to capture what you learned."}},
  "subscriptions": [
    {"insert": "capture-sol", "on": "superpowers:systematic-debugging", "when": "complete"}
  ]
}
EOF

W5_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:complete","args":"superpowers:systematic-debugging"},"cwd":"%s"}' "$W5_DIR")
W5_OUT=$(echo "$W5_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test "W5: dispatch.sh routes complete to downstream subs" "Use compounding-solutions to capture" "$W5_OUT"

# W6: dispatch.sh handles missing args in complete gracefully
W6_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:complete"},"cwd":"%s"}' "$W5_DIR")
W6_OUT=$(echo "$W6_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test_empty "W6: complete with no args produces no output" "$W6_OUT"

# W6b: args with only --depth flag (no skill name before it)
W6B_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:complete","args":"--depth 2"},"cwd":"%s"}' "$W5_DIR")
W6B_OUT=$(echo "$W6B_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test_empty "W6b: complete with only --depth (no skill) produces no output" "$W6B_OUT"

# W7: chain depth guard — --depth 5 in args stops recursion
W7_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:complete","args":"superpowers:systematic-debugging --depth 5"},"cwd":"%s"}' "$W5_DIR")
W7_OUT=$(echo "$W7_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test "W7: chain depth >= 5 stops with warning" "chain depth limit" "$W7_OUT"

# W8: non-complete skill-bus commands pass through normally
W8_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:help"},"cwd":"%s"}' "$W5_DIR")
W8_OUT=$(echo "$W8_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test_empty "W8: skill-bus:help not intercepted as complete" "$W8_OUT"

# W9: pre-timing auto-injects "you MUST run /skill-bus:complete" when complete subs exist
W9_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W9_DIR")
mkdir -p "$W9_DIR/.claude"
cat > "$W9_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {
    "pre-context": {"text": "Here is some context for writing plans."},
    "post-complete": {"text": "Capture decisions now."}
  },
  "subscriptions": [
    {"insert": "pre-context", "on": "superpowers:writing-plans", "when": "pre"},
    {"insert": "post-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

W9_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --cwd "$W9_DIR" 2>&1)
run_test "W9a: pre-output includes completion instruction" "you MUST run" "$W9_OUT"
run_test "W9b: completion instruction includes full skill name" "skill-bus:complete superpowers:writing-plans" "$W9_OUT"
run_test "W9c: pre-output still includes normal pre-context" "Here is some context" "$W9_OUT"

# W10: no complete subs = no completion instruction injected
W10_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W10_DIR")
mkdir -p "$W10_DIR/.claude"
cat > "$W10_DIR/.claude/skill-bus.json" <<'EOF'
{
  "inserts": {"pre-only": {"text": "Pre context only."}},
  "subscriptions": [
    {"insert": "pre-only", "on": "superpowers:writing-plans", "when": "pre"}
  ]
}
EOF

W10_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --cwd "$W10_DIR" 2>&1)
run_test "W10a: no complete subs = normal output" "Pre context only" "$W10_OUT"
run_test_absent "W10b: no 'you MUST run' when no complete subs" "you MUST run" "$W10_OUT"

# W11: complete subs with conditions — instruction still injected (conditions evaluated at completion time)
W11_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W11_DIR")
mkdir -p "$W11_DIR/.claude"
cat > "$W11_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"conditional-complete": {"text": "Conditional downstream.", "conditions": [{"fileExists": "nonexistent-file"}]}},
  "subscriptions": [
    {"insert": "conditional-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

W11_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --cwd "$W11_DIR" 2>&1)
run_test "W11: complete sub with conditions still injects instruction" "you MUST run" "$W11_OUT"

# W12: complete instruction not injected during post timing
W12_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing post --cwd "$W9_DIR" 2>&1)
run_test_absent "W12: post timing does not inject completion instruction" "you MUST run" "$W12_OUT"

# W13: CRITICAL — skill with ONLY complete subs (no pre subs) still gets completion instruction
# This tests the early-exit fix: _main() must not exit at "if not matched" when complete subs exist
W13_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W13_DIR")
mkdir -p "$W13_DIR/.claude"
cat > "$W13_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"only-on-complete": {"text": "Downstream only."}},
  "subscriptions": [
    {"insert": "only-on-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

W13_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --cwd "$W13_DIR" 2>&1)
run_test "W13a: only-complete skill still gets instruction" "you MUST run" "$W13_OUT"
run_test "W13b: instruction includes skill name" "skill-bus:complete superpowers:writing-plans" "$W13_OUT"

# W14: Full chain — pre injects context + completion instruction, then complete fires downstream
W14_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W14_DIR")
mkdir -p "$W14_DIR/.claude"
cat > "$W14_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"telemetry": true, "completionHooks": true},
  "inserts": {
    "plan-context": {"text": "Search for prior decisions before planning."},
    "capture-decisions": {"text": "Use capturing-decisions to record what was decided."}
  },
  "subscriptions": [
    {"insert": "plan-context", "on": "superpowers:writing-plans", "when": "pre"},
    {"insert": "capture-decisions", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

# Phase 1: Pre-hook fires for writing-plans
W14_PRE_INPUT=$(make_dispatch_input "superpowers:writing-plans" "$W14_DIR")
W14_PRE=$(echo "$W14_PRE_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test "W14a: pre-hook injects plan-context" "Search for prior decisions" "$W14_PRE"
run_test "W14b: pre-hook injects completion instruction" "skill-bus:complete superpowers:writing-plans" "$W14_PRE"

# Phase 2: Complete signal fires downstream
W14_COMPLETE_INPUT=$(printf '{"tool_name":"Skill","tool_input":{"skill":"skill-bus:complete","args":"superpowers:writing-plans"},"cwd":"%s"}' "$W14_DIR")
W14_COMPLETE=$(echo "$W14_COMPLETE_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$DISPATCH_SH" pre 2>&1)
run_test "W14c: complete signal fires capture-decisions" "Use capturing-decisions" "$W14_COMPLETE"

# W15: Fan-out — multiple complete subs on same skill all fire
W15_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W15_DIR")
mkdir -p "$W15_DIR/.claude"
cat > "$W15_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {
    "action-a": {"text": "First downstream action."},
    "action-b": {"text": "Second downstream action."}
  },
  "subscriptions": [
    {"insert": "action-a", "on": "superpowers:debugging", "when": "complete"},
    {"insert": "action-b", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF

W15_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W15_DIR" 2>&1)
run_test "W15a: fan-out — first action fires" "First downstream action" "$W15_OUT"
run_test "W15b: fan-out — second action fires" "Second downstream action" "$W15_OUT"

# W16: Wildcard complete sub matches multiple skills
W16_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W16_DIR")
mkdir -p "$W16_DIR/.claude"
cat > "$W16_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"log-all": {"text": "Log this skill completion."}},
  "subscriptions": [
    {"insert": "log-all", "on": "superpowers:*", "when": "complete"}
  ]
}
EOF

W16_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing complete --cwd "$W16_DIR" 2>&1)
run_test "W16: wildcard complete sub matches" "Log this skill completion" "$W16_OUT"

# W17: Complete sub in global config (not just project)
W17_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W17_DIR")
W17_GLOBAL=$(mktemp)
CLEANUP_DIRS+=("$W17_GLOBAL")
cat > "$W17_GLOBAL" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"global-complete": {"text": "Global downstream triggered."}},
  "subscriptions": [
    {"insert": "global-complete", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF
mkdir -p "$W17_DIR/.claude"

W17_OUT=$(SKILL_BUS_GLOBAL_CONFIG="$W17_GLOBAL" SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W17_DIR" 2>&1)
run_test "W17: global config complete sub fires" "Global downstream triggered" "$W17_OUT"

# W18: Complete sub whose conditions ALL fail at completion time — graceful no-output
W18_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W18_DIR")
mkdir -p "$W18_DIR/.claude"
cat > "$W18_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {"gated": {"text": "Should not appear.", "conditions": [{"fileExists": "does-not-exist"}]}},
  "subscriptions": [
    {"insert": "gated", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF

W18_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W18_DIR" 2>&1)
run_test_absent "W18: conditions fail at complete time — no text injected" "Should not appear" "$W18_OUT"

# W19: Chain depth increments in completion instruction
W19_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W19_DIR")
mkdir -p "$W19_DIR/.claude"
cat > "$W19_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": true},
  "inserts": {
    "chain-context": {"text": "Chained downstream."},
    "further-chain": {"text": "Further chain."}
  },
  "subscriptions": [
    {"insert": "chain-context", "on": "superpowers:debugging", "when": "complete"},
    {"insert": "further-chain", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF
# Simulate depth=2 arriving from dispatch.sh (via _SB_CHAIN_DEPTH env var)
W19_OUT=$(_SB_CHAIN_DEPTH=2 SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing pre --cwd "$W19_DIR" 2>&1)
run_test "W19: completion instruction includes depth arg" "skill-bus:complete superpowers:debugging --depth 2" "$W19_OUT"

# W20: completionHooks=false — complete timing produces no output (feature gate)
W20_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W20_DIR")
mkdir -p "$W20_DIR/.claude"
cat > "$W20_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"completionHooks": false},
  "inserts": {"gated-complete": {"text": "Should not fire."}},
  "subscriptions": [
    {"insert": "gated-complete", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF

W20_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W20_DIR" 2>&1)
run_test_empty "W20a: completionHooks=false blocks complete timing" "$W20_OUT"

# W20b: completionHooks absent (default false) — same behavior
W20B_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W20B_DIR")
mkdir -p "$W20B_DIR/.claude"
cat > "$W20B_DIR/.claude/skill-bus.json" <<'EOF'
{
  "inserts": {"gated-complete": {"text": "Should not fire."}},
  "subscriptions": [
    {"insert": "gated-complete", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF

W20B_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing complete --cwd "$W20B_DIR" 2>&1)
run_test_empty "W20b: completionHooks absent blocks complete timing" "$W20B_OUT"

# W20c: completionHooks=false — pre timing does NOT inject "you MUST run" instruction
W20C_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$DISPATCHER" --timing pre --cwd "$W20_DIR" 2>&1)
run_test_absent "W20c: completionHooks=false suppresses instruction injection" "you MUST run" "$W20C_OUT"

# W21: prompt source with complete subs — completion instruction injected via prompt-bridge
W21_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W21_DIR")
mkdir -p "$W21_DIR/.claude"
cat > "$W21_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"monitorSlashCommands": true, "completionHooks": true},
  "inserts": {
    "prompt-pre": {"text": "Prompt pre context."},
    "prompt-complete": {"text": "Prompt downstream."}
  },
  "subscriptions": [
    {"insert": "prompt-pre", "on": "superpowers:writing-plans", "when": "pre"},
    {"insert": "prompt-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

W21_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --source prompt --cwd "$W21_DIR" 2>&1)
run_test "W21a: prompt source injects completion instruction" "you MUST run" "$W21_OUT"
run_test "W21b: prompt source hookEventName is UserPromptSubmit" "UserPromptSubmit" "$W21_OUT"
run_test "W21c: prompt source still includes pre context" "Prompt pre context" "$W21_OUT"

# W22: prompt source with only-complete subs — completion-only output uses UserPromptSubmit
W22_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$W22_DIR")
mkdir -p "$W22_DIR/.claude"
cat > "$W22_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"monitorSlashCommands": true, "completionHooks": true},
  "inserts": {"only-complete": {"text": "Only downstream."}},
  "subscriptions": [
    {"insert": "only-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

W22_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:writing-plans" \
    python3 "$DISPATCHER" --timing pre --source prompt --cwd "$W22_DIR" 2>&1)
run_test "W22a: prompt-only-complete gets instruction" "you MUST run" "$W22_OUT"
run_test "W22b: prompt-only-complete uses UserPromptSubmit" "UserPromptSubmit" "$W22_OUT"

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Results ==="
echo "  Total: $TOTAL | Pass: $PASS | Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  SOME TESTS FAILED"
    exit 1
else
    echo "  ALL TESTS PASSED"
fi
