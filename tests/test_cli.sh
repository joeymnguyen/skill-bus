#!/bin/bash
set -euo pipefail
CLI="$(cd "$(dirname "$0")/../lib" && pwd)/cli.py"
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

# Trap cleanup for temp dirs on early exit
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# --- Group A: format_condition ---
echo "=== Group A: format_condition ==="

RESULT=$(python3 "$CLI" test-format-condition '{"fileExists": "docs/"}')
run_test "A1: fileExists" 'fileExists("docs/")' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"gitBranch": "feature/*"}')
run_test "A2: gitBranch" 'gitBranch("feature/*")' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"envSet": "CI"}')
run_test "A3: envSet" 'envSet("CI")' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"envEquals": {"var": "NODE_ENV", "value": "development"}}')
run_test "A4: envEquals" 'envEquals(NODE_ENV, "development")' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"fileContains": {"file": "package.json", "pattern": "prisma"}}')
run_test "A5: fileContains literal" 'fileContains("package.json", "prisma")' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"fileContains": {"file": "package.json", "pattern": "prisma.*\\d+", "regex": true}}')
run_test "A6: fileContains regex" 'fileContains("package.json", /prisma.*\d+/)' "$RESULT"

RESULT=$(python3 "$CLI" test-format-condition '{"not": {"gitBranch": "main"}}')
run_test "A7: not wrapper" 'not(gitBranch("main"))' "$RESULT"

# A8: unknown condition type falls through gracefully
RESULT=$(python3 "$CLI" test-format-condition '{"futureType": "value"}')
run_test "A8: unknown type" "futureType(" "$RESULT"

# --- Group B: list subcommand ---
echo "=== Group B: list ==="

# B1: Basic listing with global subs
TMPDIR_B1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_B1")
TMPGLOBAL_B1=$(mktemp -d); CLEANUP_DIRS+=("$TMPGLOBAL_B1")
mkdir -p "$TMPDIR_B1/.claude"
cat > "$TMPDIR_B1/.claude/skill-bus.json" << 'EOF'
{"settings": {"monitorSlashCommands": true}, "inserts": {}, "subscriptions": []}
EOF
cat > "$TMPGLOBAL_B1/skill-bus.json" << 'EOF'
{"inserts": {"test-insert": {"text": "test context"}}, "subscriptions": [{"insert": "test-insert", "on": "superpowers:brainstorming", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$TMPGLOBAL_B1/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_B1")
run_test "B1: shows global enabled" "Global:  enabled" "$RESULT"
run_test "B1: shows sub" "superpowers:brainstorming" "$RESULT"
run_test "B1: shows insert" "test-insert" "$RESULT"
run_test "B1: scope global" "global" "$RESULT"

# B2: Insert-level conditions + effective stacking
TMPDIR_B2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_B2")
mkdir -p "$TMPDIR_B2/.claude"
cat > "$TMPDIR_B2/.claude/skill-bus.json" << 'EOF'
{"inserts": {"guarded": {"text": "x", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [
  {"insert": "guarded", "on": "superpowers:writing-plans", "when": "pre"},
  {"insert": "guarded", "on": "superpowers:brainstorming", "when": "pre", "conditions": [{"gitBranch": "feature/*"}]}
]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" list --cwd "$TMPDIR_B2")
run_test "B2: insert conditions" 'insert conditions: fileExists("docs/")' "$RESULT"
run_test "B2: sub conditions" 'gitBranch("feature/*")' "$RESULT"
run_test "B2: effective AND" "AND" "$RESULT"

# B3: Orphan insert
TMPDIR_B3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_B3")
mkdir -p "$TMPDIR_B3/.claude"
cat > "$TMPDIR_B3/.claude/skill-bus.json" << 'EOF'
{"inserts": {"used": {"text": "used"}, "orphan": {"text": "orphan text"}}, "subscriptions": [{"insert": "used", "on": "test:skill", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" list --cwd "$TMPDIR_B3")
run_test "B3: orphan detected" "Orphan inserts (no subscriptions): orphan" "$RESULT"

# --- Group C: simulate ---
echo "=== Group C: simulate ==="

# C1: Passing condition
TMPDIR_C1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C1")
mkdir -p "$TMPDIR_C1/.claude" "$TMPDIR_C1/docs"
cat > "$TMPDIR_C1/.claude/skill-bus.json" << 'EOF'
{"inserts": {"guard": {"text": "guarded", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [{"insert": "guard", "on": "superpowers:writing-plans", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "superpowers:writing-plans" --cwd "$TMPDIR_C1" --timing pre)
run_test "C1: pass checkmark" "✓" "$RESULT"
run_test "C1: fires" "fires" "$RESULT"

# C2: Failing condition
TMPDIR_C2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C2")
mkdir -p "$TMPDIR_C2/.claude"
cat > "$TMPDIR_C2/.claude/skill-bus.json" << 'EOF'
{"inserts": {"guard": {"text": "guarded", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [{"insert": "guard", "on": "superpowers:writing-plans", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "superpowers:writing-plans" --cwd "$TMPDIR_C2" --timing pre)
run_test "C2: fail X" "✗" "$RESULT"

# C3: No match
TMPDIR_C3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C3")
mkdir -p "$TMPDIR_C3/.claude"
cat > "$TMPDIR_C3/.claude/skill-bus.json" << 'EOF'
{"inserts": {"x": {"text": "x"}}, "subscriptions": [{"insert": "x", "on": "other:skill", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "superpowers:writing-plans" --cwd "$TMPDIR_C3" --timing pre)
run_test "C3: no match" "No subscriptions match" "$RESULT"

# C4: Post timing simulation
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "other:skill" --cwd "$TMPDIR_C3" --timing post)
run_test "C4: no match post timing" "No subscriptions match" "$RESULT"

# --- Group D: scope derivation + overrides ---
echo "=== Group D: scope + overrides ==="

# D1: Project sub correctly identified (not misclassified as global even if same tuple exists)
TMPDIR_D1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_D1")
TMPGLOBAL_D1=$(mktemp -d); CLEANUP_DIRS+=("$TMPGLOBAL_D1")
mkdir -p "$TMPDIR_D1/.claude"
cat > "$TMPGLOBAL_D1/skill-bus.json" << 'EOF'
{"inserts": {"x": {"text": "x"}}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre"}]}
EOF
cat > "$TMPDIR_D1/.claude/skill-bus.json" << 'EOF'
{"inserts": {}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "CI"}]}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$TMPGLOBAL_D1/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_D1")
# After dedup, project wins. Should show "project" scope, not "global"
run_test "D1: dedup winner is project" "project" "$RESULT"

# D2: Override shows "disabled in project"
TMPDIR_D2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_D2")
TMPGLOBAL_D2=$(mktemp -d); CLEANUP_DIRS+=("$TMPGLOBAL_D2")
mkdir -p "$TMPDIR_D2/.claude"
cat > "$TMPGLOBAL_D2/skill-bus.json" << 'EOF'
{"inserts": {"x": {"text": "x"}}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre"}]}
EOF
cat > "$TMPDIR_D2/.claude/skill-bus.json" << 'EOF'
{"inserts": {}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre", "enabled": false}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$TMPGLOBAL_D2/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_D2")
run_test "D2: shows disabled" "disabled in project" "$RESULT"

# D3: Both configs empty
TMPDIR_D3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_D3")
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" list --cwd "$TMPDIR_D3")
run_test "D3: empty shows no config" "no config" "$RESULT"

# --- Group E: skills with fixture ---
echo "=== Group E: skills (fixture-based) ==="

TMPDIR_E=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_E")
TMPCACHE_E=$(mktemp -d); CLEANUP_DIRS+=("$TMPCACHE_E")
mkdir -p "$TMPDIR_E/.claude/skills/proj-skill"
echo -e "---\nname: proj-skill\ndescription: test\n---" > "$TMPDIR_E/.claude/skills/proj-skill/SKILL.md"
mkdir -p "$TMPDIR_E/.claude/commands"
echo -e "---\ndescription: test cmd\n---" > "$TMPDIR_E/.claude/commands/test-cmd.md"

# Create mock plugin in cache
mkdir -p "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/.claude-plugin"
echo '{"name": "mock-plugin", "version": "1.0.0"}' > "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/.claude-plugin/plugin.json"
mkdir -p "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/skills/mock-skill"
echo -e "---\nname: mock-skill\ndescription: mock\n---" > "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/skills/mock-skill/SKILL.md"
mkdir -p "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/commands"
echo -e "---\ndescription: mock cmd\n---" > "$TMPCACHE_E/mock-source/mock-plugin/1.0.0/commands/mock-cmd.md"

# Also create a temp_git_ dir that should be skipped
mkdir -p "$TMPCACHE_E/temp_git_12345_abc/some-plugin/1.0.0/skills/should-skip"
echo -e "---\nname: should-skip\n---" > "$TMPCACHE_E/temp_git_12345_abc/some-plugin/1.0.0/skills/should-skip/SKILL.md"

# Semver test: add 0.9.0 and 0.10.0 versions
mkdir -p "$TMPCACHE_E/ver-source/ver-plugin/0.9.0/.claude-plugin"
echo '{"name": "ver-plugin", "version": "0.9.0"}' > "$TMPCACHE_E/ver-source/ver-plugin/0.9.0/.claude-plugin/plugin.json"
mkdir -p "$TMPCACHE_E/ver-source/ver-plugin/0.9.0/skills/old-skill"
echo -e "---\nname: old-skill\n---" > "$TMPCACHE_E/ver-source/ver-plugin/0.9.0/skills/old-skill/SKILL.md"
mkdir -p "$TMPCACHE_E/ver-source/ver-plugin/0.10.0/.claude-plugin"
echo '{"name": "ver-plugin", "version": "0.10.0"}' > "$TMPCACHE_E/ver-source/ver-plugin/0.10.0/.claude-plugin/plugin.json"
mkdir -p "$TMPCACHE_E/ver-source/ver-plugin/0.10.0/skills/new-skill"
echo -e "---\nname: new-skill\n---" > "$TMPCACHE_E/ver-source/ver-plugin/0.10.0/skills/new-skill/SKILL.md"

RESULT=$(python3 "$CLI" skills --cwd "$TMPDIR_E" --cache-dir "$TMPCACHE_E")
run_test "E1: discovers mock plugin" "mock-plugin" "$RESULT"
run_test "E2: discovers mock skill" "mock-skill" "$RESULT"
run_test "E3: discovers mock command" "mock-cmd" "$RESULT"
run_test "E4: discovers project skills" "proj-skill" "$RESULT"
run_test "E5: discovers project commands" "test-cmd" "$RESULT"
run_test_absent "E6: skips temp_git" "should-skip" "$RESULT"
run_test "E7: semver picks 0.10.0 not 0.9.0" "new-skill" "$RESULT"
run_test_absent "E8: semver skips 0.9.0 skill" "old-skill" "$RESULT"

# --- Group F: inserts + status ---
echo "=== Group F: inserts + status ==="

TMPDIR_F=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_F")
mkdir -p "$TMPDIR_F/.claude"
cat > "$TMPDIR_F/.claude/skill-bus.json" << 'EOF'
{"inserts": {"my-insert": {"text": "hello world", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [{"insert": "my-insert", "on": "test:skill", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" inserts --scope project --cwd "$TMPDIR_F")
run_test "F1: inserts shows name" "my-insert" "$RESULT"
run_test "F1: inserts shows conditions" "fileExists" "$RESULT"
run_test "F1: inserts shows create option" "Create new insert" "$RESULT"

RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" status --cwd "$TMPDIR_F")
run_test "F2: status shows version" "Skill Bus" "$RESULT"
run_test "F2: status shows sub count" "1 subs" "$RESULT"

# F3: status shows telemetry status
TMPDIR_F3=$(mktemp -d)
mkdir -p "$TMPDIR_F3/.claude"
cat > "$TMPDIR_F3/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true, "observeUnmatched": true},
  "inserts": {"x": {"text": "ctx"}},
  "subscriptions": [{"insert": "x", "on": "test:s", "when": "pre"}]
}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" status --cwd "$TMPDIR_F3")
run_test "F3: status shows telemetry on" "telemetry: on" "$RESULT"
rm -rf "$TMPDIR_F3"

# --- Group G: review fixes - missing coverage ---
echo "=== Group G: review fixes ==="

# G1: Insert name conflict (global + project same name)
TMPDIR_G1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G1")
TMPGLOBAL_G1=$(mktemp -d); CLEANUP_DIRS+=("$TMPGLOBAL_G1")
mkdir -p "$TMPDIR_G1/.claude"
cat > "$TMPGLOBAL_G1/skill-bus.json" << 'EOF'
{"inserts": {"shared-ctx": {"text": "global version"}}, "subscriptions": [{"insert": "shared-ctx", "on": "test:skill", "when": "pre"}]}
EOF
cat > "$TMPDIR_G1/.claude/skill-bus.json" << 'EOF'
{"inserts": {"shared-ctx": {"text": "project version"}}, "subscriptions": [{"insert": "shared-ctx", "on": "test:skill", "when": "pre"}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$TMPGLOBAL_G1/skill-bus.json" python3 "$CLI" list --cwd "$TMPDIR_G1" 2>&1)
run_test "G1: collision info message" "INFO" "$RESULT"
run_test "G1: uses project version" "using project version" "$RESULT"
run_test "G1: conflict names insert" "shared-ctx" "$RESULT"

# G2: inheritConditions: false in list display
TMPDIR_G2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G2")
mkdir -p "$TMPDIR_G2/.claude"
cat > "$TMPDIR_G2/.claude/skill-bus.json" << 'EOF'
{"inserts": {"guarded": {"text": "x", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [
  {"insert": "guarded", "on": "test:skill", "when": "pre", "inheritConditions": false}
]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" list --cwd "$TMPDIR_G2")
run_test "G2: shows opt-out" "inheritConditions: false" "$RESULT"
run_test "G2: shows opts out text" "opts out of insert conditions" "$RESULT"
run_test "G2: effective is none" "effective: (none)" "$RESULT"

# G3: inheritConditions: false with own sub conditions
TMPDIR_G3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G3")
mkdir -p "$TMPDIR_G3/.claude"
cat > "$TMPDIR_G3/.claude/skill-bus.json" << 'EOF'
{"inserts": {"guarded": {"text": "x", "conditions": [{"fileExists": "docs/"}]}}, "subscriptions": [
  {"insert": "guarded", "on": "test:skill", "when": "pre", "inheritConditions": false, "conditions": [{"gitBranch": "feature/*"}]}
]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" list --cwd "$TMPDIR_G3")
run_test "G3: opt-out with own conditions" "opts out of insert conditions" "$RESULT"
run_test "G3: shows sub conditions" 'gitBranch("feature/*")' "$RESULT"
run_test_absent "G3: effective excludes insert cond" 'fileExists("docs/") AND' "$RESULT"

# G4: Simulate with multiple matching subscriptions
TMPDIR_G4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G4")
mkdir -p "$TMPDIR_G4/.claude" "$TMPDIR_G4/docs"
cat > "$TMPDIR_G4/.claude/skill-bus.json" << 'EOF'
{"inserts": {"first": {"text": "first ctx"}, "second": {"text": "second ctx"}}, "subscriptions": [
  {"insert": "first", "on": "test:*", "when": "pre"},
  {"insert": "second", "on": "test:skill", "when": "pre"}
]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_G4" --timing pre)
run_test "G4: first match fires" "first -> test:*" "$RESULT"
run_test "G4: second match fires" "second -> test:skill" "$RESULT"
run_test "G4: both fire" "fires" "$RESULT"

# G5: Inserts --scope global
TMPDIR_G5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G5")
TMPGLOBAL_G5=$(mktemp -d); CLEANUP_DIRS+=("$TMPGLOBAL_G5")
cat > "$TMPGLOBAL_G5/skill-bus.json" << 'EOF'
{"inserts": {"global-insert": {"text": "global content", "conditions": [{"envSet": "CI"}]}}, "subscriptions": []}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$TMPGLOBAL_G5/skill-bus.json" python3 "$CLI" inserts --scope global --cwd "$TMPDIR_G5")
run_test "G5: global inserts shows name" "global-insert" "$RESULT"
run_test "G5: global inserts shows conditions" "envSet" "$RESULT"
run_test "G5: global inserts shows create option" "Create new insert" "$RESULT"

# G6: Simulate sub-condition short-circuit (matches runtime behavior)
TMPDIR_G6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_G6")
mkdir -p "$TMPDIR_G6/.claude"
cat > "$TMPDIR_G6/.claude/skill-bus.json" << 'EOF'
{"inserts": {"x": {"text": "hello"}}, "subscriptions": [{"insert": "x", "on": "test:skill", "when": "pre", "conditions": [{"fileExists": "nope/"}, {"envSet": "CI"}]}]}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" simulate "test:skill" --cwd "$TMPDIR_G6" --timing pre)
run_test "G6: first sub cond fails" "fileExists" "$RESULT"
run_test "G6: short-circuit message" "short-circuit: sub condition failed" "$RESULT"
run_test_absent "G6: second cond not evaluated" "envSet" "$RESULT"

# --- Group H: scan subcommand ---
echo "=== Group H: scan ==="

# H1: Scan finds CLAUDE.md
TMPDIR_H1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H1")
mkdir -p "$TMPDIR_H1/.claude"
echo "# My Project" > "$TMPDIR_H1/.claude/CLAUDE.md"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H1: scan finds CLAUDE.md" "CLAUDE.md" "$RESULT"

# H2: Scan finds docs/ directory
mkdir -p "$TMPDIR_H1/docs/decisions"
echo "Decision 1" > "$TMPDIR_H1/docs/decisions/adr-001.md"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H2: scan finds docs/" "docs/" "$RESULT"

# H3: Scan finds README.md
echo "# README" > "$TMPDIR_H1/README.md"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H3: scan finds README" "README.md" "$RESULT"

# H4: Scan finds package.json
echo '{"name": "test"}' > "$TMPDIR_H1/package.json"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H4: scan finds package.json" "package.json" "$RESULT"

# H5: Scan finds pyproject.toml
echo '[tool.poetry]' > "$TMPDIR_H1/pyproject.toml"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H5: scan finds pyproject.toml" "pyproject.toml" "$RESULT"

# H6: Scan on empty project → no knowledge files
TMPDIR_H6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_H6")
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H6")
run_test "H6: empty project no knowledge" "No knowledge files found" "$RESULT"

# H7: Scan finds .git/config (remote)
mkdir -p "$TMPDIR_H1/.git"
printf '[remote "origin"]\n\turl = https://github.com/acme-corp/project.git\n' > "$TMPDIR_H1/.git/config"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H7: scan finds git remote" "acme-corp/project" "$RESULT"

# H8: Scan with --json flag
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --json --cwd "$TMPDIR_H1")
run_test "H8: scan --json" '"knowledge":' "$RESULT"

# H9: Scan includes existing config status
mkdir -p "$TMPDIR_H1/.claude"
cat > "$TMPDIR_H1/.claude/skill-bus.json" << 'HEOF'
{"inserts": {"test": {"text": "x"}}, "subscriptions": [{"insert": "test", "on": "*", "when": "pre"}]}
HEOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" scan --cwd "$TMPDIR_H1")
run_test "H9: scan shows existing subs" "1 existing subscription" "$RESULT"

# --- Group I: set subcommand ---
echo "=== Group I: set ==="

# I1: Set telemetry=true in project scope
TMPDIR_I1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I1")
mkdir -p "$TMPDIR_I1/.claude"
echo '{"inserts": {}, "subscriptions": []}' > "$TMPDIR_I1/.claude/skill-bus.json"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set telemetry true --scope project --cwd "$TMPDIR_I1")
run_test "I1: set telemetry true" "Set telemetry = true" "$RESULT"
# Verify it was written
WRITTEN=$(python3 -c "import json; c=json.load(open('$TMPDIR_I1/.claude/skill-bus.json')); print(c.get('settings',{}).get('telemetry','MISSING'))")
run_test "I1b: telemetry persisted" "True" "$WRITTEN"

# I2: Set monitorSlashCommands=true in global scope
TMPDIR_I2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I2")
GLOBAL_I2="$TMPDIR_I2/global-config.json"
echo '{"inserts": {}, "subscriptions": []}' > "$GLOBAL_I2"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$GLOBAL_I2" python3 "$CLI" set monitorSlashCommands true --scope global --cwd "$TMPDIR_I2")
run_test "I2: set monitor in global" "Set monitorSlashCommands = true" "$RESULT"

# I3: Set creates config file if it doesn't exist (project scope)
TMPDIR_I3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I3")
mkdir -p "$TMPDIR_I3/.claude"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set telemetry true --scope project --cwd "$TMPDIR_I3")
run_test "I3: set creates config" "Set telemetry = true" "$RESULT"
run_test "I3b: config file created" '"settings"' "$(cat "$TMPDIR_I3/.claude/skill-bus.json")"

# I4: Set observeUnmatched=true (requires telemetry to be on — just warns)
TMPDIR_I4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_I4")
mkdir -p "$TMPDIR_I4/.claude"
echo '{"settings": {"telemetry": false}, "inserts": {}, "subscriptions": []}' > "$TMPDIR_I4/.claude/skill-bus.json"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set observeUnmatched true --scope project --cwd "$TMPDIR_I4" 2>&1)
run_test "I4: observeUnmatched warns about telemetry" "telemetry" "$RESULT"

# I5: Invalid setting name → error
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set fakeField true --scope project --cwd "$TMPDIR_I3" 2>&1 || true)
run_test "I5: invalid setting name" "Unknown setting" "$RESULT"

# I6: Set boolean false
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set showConsoleEcho false --scope project --cwd "$TMPDIR_I3")
run_test "I6: set false" "Set showConsoleEcho = false" "$RESULT"

# I7: Set integer value (maxMatchesPerSkill)
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set maxMatchesPerSkill 5 --scope project --cwd "$TMPDIR_I3")
run_test "I7: set integer" "Set maxMatchesPerSkill = 5" "$RESULT"

# I8: Negative integer → error
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set maxMatchesPerSkill -1 --scope project --cwd "$TMPDIR_I3" 2>&1 || true)
run_test "I8: negative integer rejected" "must be >= 1" "$RESULT"

# I9: maxLogSizeKB=0 is valid (disables rotation)
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" set maxLogSizeKB 0 --scope project --cwd "$TMPDIR_I3")
run_test "I9: maxLogSizeKB 0 accepted" "Set maxLogSizeKB = 0" "$RESULT"

# --- Group J: add-insert subcommand ---
echo "=== Group J: add-insert ==="

# J1: Add insert + subscription to new config
TMPDIR_J1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J1")
mkdir -p "$TMPDIR_J1/.claude"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "prior-decisions" \
    --text "Check docs/decisions/ for prior context before starting" \
    --on "*:writing-plans" \
    --when pre \
    --scope project \
    --cwd "$TMPDIR_J1")
run_test "J1: add-insert creates sub" "Created" "$RESULT"
# Verify config structure
WRITTEN=$(python3 -c "
import json
c = json.load(open('$TMPDIR_J1/.claude/skill-bus.json'))
ins = c.get('inserts', {}).get('prior-decisions', {})
subs = c.get('subscriptions', [])
print(f'text={bool(ins.get(\"text\"))} subs={len(subs)}')
")
run_test "J1b: config has insert+sub" "text=True subs=1" "$WRITTEN"

# J2: Add insert with conditions
TMPDIR_J2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J2")
mkdir -p "$TMPDIR_J2/.claude"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "build-check" \
    --text "Run build before claiming done" \
    --conditions '[{"fileExists": "package.json"}]' \
    --on "*:finishing-*" \
    --when pre \
    --scope project \
    --cwd "$TMPDIR_J2")
run_test "J2: add-insert with conditions" "Created" "$RESULT"
CONDS=$(python3 -c "
import json
c = json.load(open('$TMPDIR_J2/.claude/skill-bus.json'))
ins = c.get('inserts', {}).get('build-check', {})
print(len(ins.get('conditions', [])))
")
run_test "J2b: conditions persisted" "1" "$CONDS"

# J3: Duplicate detection — same insert+on+when doesn't add second sub
RESULT2=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "build-check" \
    --text "Run build before claiming done" \
    --on "*:finishing-*" \
    --when pre \
    --scope project \
    --cwd "$TMPDIR_J2" 2>&1)
run_test "J3: duplicate detected" "already exists" "$RESULT2"
SUB_COUNT=$(python3 -c "
import json
c = json.load(open('$TMPDIR_J2/.claude/skill-bus.json'))
print(len(c.get('subscriptions', [])))
")
run_test "J3b: still 1 sub" "1" "$SUB_COUNT"

# J4: Add insert with dynamic field
TMPDIR_J4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J4")
mkdir -p "$TMPDIR_J4/.claude"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "session-gaps" \
    --text "No telemetry data available yet." \
    --dynamic "session-stats" \
    --on "*:finishing-*" \
    --when pre \
    --scope project \
    --cwd "$TMPDIR_J4")
run_test "J4: add-insert with dynamic" "Created" "$RESULT"
DYN=$(python3 -c "
import json
c = json.load(open('$TMPDIR_J4/.claude/skill-bus.json'))
ins = c.get('inserts', {}).get('session-gaps', {})
print(ins.get('dynamic', 'MISSING'))
")
run_test "J4b: dynamic field persisted" "session-stats" "$DYN"

# J5: Global scope writes to global config
TMPDIR_J5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_J5")
GLOBAL_J5="$TMPDIR_J5/global-config.json"
echo '{"inserts": {}, "subscriptions": []}' > "$GLOBAL_J5"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="$GLOBAL_J5" python3 "$CLI" add-insert \
    --name "test-global" \
    --text "Global insert" \
    --on "*" \
    --when pre \
    --scope global \
    --cwd "$TMPDIR_J5")
run_test "J5: global scope" "Created" "$RESULT"
run_test "J5b: written to global" "test-global" "$(cat "$GLOBAL_J5")"

# J6: Invalid conditions JSON → error
RESULT=$(SKILL_BUS_GLOBAL_CONFIG="/dev/null/nonexistent" python3 "$CLI" add-insert \
    --name "bad-conds" --text "test" --conditions 'NOT VALID JSON' \
    --on "*" --when pre --scope project --cwd "$TMPDIR_J1" 2>&1 || true)
run_test "J6: invalid conditions JSON" "Invalid conditions JSON" "$RESULT"

# --- Group K: Complete timing in CLI ---
echo ""
echo "=== Group K: Complete timing in CLI ==="

K_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$K_DIR")
mkdir -p "$K_DIR/.claude"
cat > "$K_DIR/.claude/skill-bus.json" <<'EOF'
{
  "inserts": {
    "pre-context": {"text": "Pre context."},
    "on-complete": {"text": "Run follow-up."}
  },
  "subscriptions": [
    {"insert": "pre-context", "on": "superpowers:writing-plans", "when": "pre"},
    {"insert": "on-complete", "on": "superpowers:writing-plans", "when": "complete"}
  ]
}
EOF

# K1: simulate --timing complete shows complete sub
K1_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" simulate "superpowers:writing-plans" --timing complete --cwd "$K_DIR" 2>&1)
run_test "K1a: simulate --timing complete shows complete sub" "on-complete" "$K1_OUT"
run_test "K1b: simulate shows complete timing" "complete" "$K1_OUT"

# K2: list shows complete sub (list shows ALL subs regardless of timing)
K2_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" list --cwd "$K_DIR" 2>&1)
run_test "K2: list shows complete sub" "on-complete" "$K2_OUT"

# K3: simulate --timing pre does NOT show complete sub
K3_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" simulate "superpowers:writing-plans" --timing pre --cwd "$K_DIR" 2>&1)
run_test_absent "K3: simulate --timing pre hides complete sub" "on-complete" "$K3_OUT"

# K4: add-insert with --when complete creates subscription
K4_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$K4_DIR")
mkdir -p "$K4_DIR/.claude"
K4_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "on-done" --text "Follow-up action." \
    --on "superpowers:*" --when complete --scope project \
    --cwd "$K4_DIR" 2>&1)
run_test "K4a: add-insert --when complete succeeds" "Created" "$K4_OUT"
K4_CONFIG=$(cat "$K4_DIR/.claude/skill-bus.json")
run_test "K4b: complete timing persisted" '"when": "complete"' "$K4_CONFIG"

# --- Group K5: add-insert --text optional for existing inserts ---

echo ""
echo "=== Group K5: add-insert --text optional ==="

K5_DIR=$(mktemp -d)
# K5a: Create insert with --text, then add second sub without --text
K5a_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "reuse-test" --text "Original text" --on "foo:bar" \
    --scope project --cwd "$K5_DIR" 2>&1)
run_test "K5a: initial insert created" "Created: reuse-test -> foo:bar" "$K5a_OUT"

K5b_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "reuse-test" --on "foo:baz" \
    --scope project --cwd "$K5_DIR" 2>&1)
run_test "K5b: second sub reuses existing insert" "Created: reuse-test -> foo:baz" "$K5b_OUT"

K5b_CONFIG=$(cat "$K5_DIR/.claude/skill-bus.json")
run_test "K5c: original text preserved" "Original text" "$K5b_CONFIG"

# K5d: Error when --text omitted for non-existing insert
K5d_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "nonexistent-insert" --on "foo:bar" \
    --scope project --cwd "$K5_DIR" 2>&1 || true)
run_test "K5d: error on missing --text for new insert" "Error: --text is required" "$K5d_OUT"

rm -rf "$K5_DIR"

# --- Group L: Hardening guards ---
echo ""
echo "=== Group L: Hardening guards (8 tests) ==="

# L1: cmd_set refuses to write when config has malformed JSON
L1_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$L1_DIR")
mkdir -p "$L1_DIR/.claude"
echo '{bad json' > "$L1_DIR/.claude/skill-bus.json"
L1_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" set telemetry true --scope project --cwd "$L1_DIR" 2>&1 || true)
run_test "L1a: cmd_set refuses malformed config" "Fix the JSON syntax" "$L1_OUT"
# Verify original file is untouched
L1_CONTENT=$(cat "$L1_DIR/.claude/skill-bus.json")
run_test "L1b: malformed config not overwritten by set" "{bad json" "$L1_CONTENT"

# L2: cmd_add_insert refuses to write when config has malformed JSON
L2_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$L2_DIR")
mkdir -p "$L2_DIR/.claude"
echo '{bad json' > "$L2_DIR/.claude/skill-bus.json"
L2_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "test" --text "hello" --on "foo:bar" \
    --scope project --cwd "$L2_DIR" 2>&1 || true)
run_test "L2a: add-insert refuses malformed config" "Fix the JSON syntax" "$L2_OUT"
L2_CONTENT=$(cat "$L2_DIR/.claude/skill-bus.json")
run_test "L2b: malformed config not overwritten by add-insert" "{bad json" "$L2_CONTENT"

# L3: add-insert --text preserves existing conditions on insert
L3_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$L3_DIR")
mkdir -p "$L3_DIR/.claude"
cat > "$L3_DIR/.claude/skill-bus.json" <<'EOF'
{
  "inserts": {
    "guarded": {
      "text": "Original",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "guarded", "on": "foo:bar", "when": "pre"}
  ]
}
EOF
L3_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "guarded" --text "Updated text" --on "foo:baz" \
    --scope project --cwd "$L3_DIR" 2>&1)
run_test "L3a: add-insert with --text on existing insert" "Created: guarded -> foo:baz" "$L3_OUT"
L3_CONFIG=$(cat "$L3_DIR/.claude/skill-bus.json")
run_test "L3b: conditions preserved after --text update" "fileExists" "$L3_CONFIG"
run_test "L3c: text updated" "Updated text" "$L3_CONFIG"

# L4: add-insert --text preserves existing dynamic field
L4_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$L4_DIR")
mkdir -p "$L4_DIR/.claude"
cat > "$L4_DIR/.claude/skill-bus.json" <<'EOF'
{
  "inserts": {
    "dyn": {
      "text": "Fallback",
      "dynamic": "session-stats"
    }
  },
  "subscriptions": [
    {"insert": "dyn", "on": "foo:bar", "when": "pre"}
  ]
}
EOF
L4_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$CLI" add-insert \
    --name "dyn" --text "New fallback" --on "foo:baz" \
    --scope project --cwd "$L4_DIR" 2>&1)
run_test "L4a: add-insert updates text on dynamic insert" "Created: dyn -> foo:baz" "$L4_OUT"
L4_CONFIG=$(cat "$L4_DIR/.claude/skill-bus.json")
run_test "L4b: dynamic field preserved" "session-stats" "$L4_CONFIG"

# --- Results ---
echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
