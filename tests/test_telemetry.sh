#!/bin/bash
set -euo pipefail
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

# Trap cleanup
CLEANUP_DIRS=()
cleanup() { for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"

echo "=== Group A: telemetry module ==="

# A1: log_event writes valid JSONL with required fields
TMPDIR_A1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A1")
mkdir -p "$TMPDIR_A1/.claude"
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
log_event('match', '$TMPDIR_A1', skill='test:skill', insert='my-insert')
import json
with open('$TMPDIR_A1/.claude/skill-bus-telemetry.jsonl') as f:
    line = f.readline()
    d = json.loads(line)
    assert d['event'] == 'match'
    assert d['skill'] == 'test:skill'
    assert d['insert'] == 'my-insert'
    assert 'ts' in d
    assert 'sessionId' in d
    print('VALID_JSONL')
" 2>&1)
run_test "A1: log_event writes valid JSONL" "VALID_JSONL" "$RESULT"

# A2: telemetry disabled by default — explicit setting
TMPDIR_A2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A2")
mkdir -p "$TMPDIR_A2/.claude"
cat > "$TMPDIR_A2/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": false},
  "inserts": {"x": {"text": "ctx"}},
  "subscriptions": [{"insert": "x", "on": "test:s", "when": "pre"}]
}
EOF
SKILL_BUS_SKILL="test:s" SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$TMPDIR_A2" > /dev/null 2>&1
if [ ! -f "$TMPDIR_A2/.claude/skill-bus-telemetry.jsonl" ]; then
    run_test "A2: telemetry disabled — no file" "PASS" "PASS"
else
    run_test "A2: telemetry disabled — no file" "NO_FILE" "FILE_EXISTS"
fi

# A1b: custom telemetryPath works (relative path)
TMPDIR_A1b=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A1b")
mkdir -p "$TMPDIR_A1b/custom-logs"
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
settings = {'telemetryPath': 'custom-logs/my-telemetry.jsonl'}
log_event('match', '$TMPDIR_A1b', settings=settings, skill='test:skill', insert='x')
with open('$TMPDIR_A1b/custom-logs/my-telemetry.jsonl') as f:
    print('CUSTOM_PATH' if len(f.read()) > 0 else 'FAILED')
" 2>&1)
run_test "A1b: custom telemetryPath works" "CUSTOM_PATH" "$RESULT"

# A1c: log_event fail-safe on unwritable dir
TMPDIR_A1c=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A1c")
mkdir -p "$TMPDIR_A1c/.claude"
chmod 000 "$TMPDIR_A1c/.claude"
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
try:
    log_event('match', '$TMPDIR_A1c', skill='test', insert='x')
    print('SILENT_FAILURE_OK')
except Exception as e:
    print('RAISED_ERROR: ' + str(e))
" 2>&1)
chmod 755 "$TMPDIR_A1c/.claude"  # Restore for cleanup
run_test "A1c: log_event fail-safe on bad dir" "SILENT_FAILURE_OK" "$RESULT"

# A1d: session ID stable across multiple log_event calls
TMPDIR_A1d=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A1d")
mkdir -p "$TMPDIR_A1d/.claude"
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
log_event('match', '$TMPDIR_A1d', skill='s1', insert='x')
log_event('match', '$TMPDIR_A1d', skill='s2', insert='y')
import json
with open('$TMPDIR_A1d/.claude/skill-bus-telemetry.jsonl') as f:
    lines = f.readlines()
    e1, e2 = json.loads(lines[0]), json.loads(lines[1])
    if e1['sessionId'] == e2['sessionId']:
        print('SESSION_STABLE')
    else:
        print('SESSION_MISMATCH: ' + e1['sessionId'] + ' vs ' + e2['sessionId'])
" 2>&1)
run_test "A1d: session ID stable across calls" "SESSION_STABLE" "$RESULT"

# A2b: DEFAULT_SETTINGS has correct telemetry defaults
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from dispatcher import DEFAULT_SETTINGS
assert DEFAULT_SETTINGS.get('telemetry') is False, 'telemetry should default to False'
assert DEFAULT_SETTINGS.get('observeUnmatched') is False, 'observeUnmatched should default to False'
assert DEFAULT_SETTINGS.get('telemetryPath') == '', 'telemetryPath should default to empty string'
print('DEFAULTS_CORRECT')
" 2>&1)
run_test "A2b: DEFAULT_SETTINGS correct" "DEFAULTS_CORRECT" "$RESULT"

# A2c: SKILL_BUS_GLOBAL_CONFIG env var is honored by dispatcher.py
TMPDIR_A2c=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A2c")
mkdir -p "$TMPDIR_A2c/.claude"
FAKE_GLOBAL="$TMPDIR_A2c/fake-global.json"
cat > "$FAKE_GLOBAL" << 'EOF'
{
  "inserts": {"from-global": {"text": "global context injected"}},
  "subscriptions": [{"insert": "from-global", "on": "test:envcheck", "when": "pre"}]
}
EOF
# With env var pointing to our fake global, dispatcher should find the subscription
RESULT=$(SKILL_BUS_SKILL="test:envcheck" SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL" python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$TMPDIR_A2c" 2>&1)
run_test "A2c: SKILL_BUS_GLOBAL_CONFIG honored" "global context injected" "$RESULT"

# A3: match events logged when telemetry enabled
TMPDIR_A3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A3")
mkdir -p "$TMPDIR_A3/.claude"
cat > "$TMPDIR_A3/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true},
  "inserts": {"ctx": {"text": "test context"}},
  "subscriptions": [{"insert": "ctx", "on": "test:skill", "when": "pre"}]
}
EOF
SKILL_BUS_SKILL="test:skill" SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$TMPDIR_A3" > /dev/null 2>&1
LOGFILE="$TMPDIR_A3/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "A3: match event logged" '"event":"match"' "$CONTENT"
    run_test "A3: skill field present" '"skill":"test:skill"' "$CONTENT"
    run_test "A3: insert field present" '"insert":"ctx"' "$CONTENT"
else
    run_test "A3: telemetry file created" "EXISTS" "MISSING"
fi

# A3b: no_match logged from slow path when observeUnmatched enabled
TMPDIR_A3b=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A3b")
mkdir -p "$TMPDIR_A3b/.claude"
cat > "$TMPDIR_A3b/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true, "observeUnmatched": true},
  "inserts": {"x": {"text": "ctx"}},
  "subscriptions": [{"insert": "x", "on": "other:skill", "when": "pre"}]
}
EOF
SKILL_BUS_SKILL="unmatched:skill" SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$TMPDIR_A3b" > /dev/null 2>&1
LOGFILE="$TMPDIR_A3b/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "A3b: no_match from slow path" '"event":"no_match"' "$CONTENT"
    run_test "A3b: skill field" '"skill":"unmatched:skill"' "$CONTENT"
else
    run_test "A3b: no_match telemetry file created" "EXISTS" "MISSING"
fi

# A4: condition_skip events logged when telemetry enabled
TMPDIR_A4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A4")
mkdir -p "$TMPDIR_A4/.claude"
cat > "$TMPDIR_A4/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true},
  "inserts": {"gated": {"text": "gated context", "conditions": [{"fileExists": "nonexistent-dir/"}]}},
  "subscriptions": [{"insert": "gated", "on": "test:skill", "when": "pre"}]
}
EOF
SKILL_BUS_SKILL="test:skill" SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$TMPDIR_A4" > /dev/null 2>&1
LOGFILE="$TMPDIR_A4/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "A4: condition_skip event logged" '"event":"condition_skip"' "$CONTENT"
    run_test "A4: insert field" '"insert":"gated"' "$CONTENT"
    run_test "A4: skill field" '"skill":"test:skill"' "$CONTENT"
else
    run_test "A4: telemetry file created" "EXISTS" "MISSING"
fi

# A4b: condition_skip from prompt-sourced dispatch
TMPDIR_A4b=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A4b")
mkdir -p "$TMPDIR_A4b/.claude"
cat > "$TMPDIR_A4b/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true, "monitorSlashCommands": true},
  "inserts": {"gated": {"text": "ctx", "conditions": [{"fileExists": "nonexistent/"}]}},
  "subscriptions": [{"insert": "gated", "on": "superpowers:*", "when": "pre"}]
}
EOF
SKILL_BUS_SKILL="superpowers:writing-plans" SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/dispatcher.py" --timing pre --source prompt --cwd "$TMPDIR_A4b" > /dev/null 2>&1
LOGFILE="$TMPDIR_A4b/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "A4b: condition_skip from prompt source" '"event":"condition_skip"' "$CONTENT"
    run_test "A4b: source field" '"source":"prompt"' "$CONTENT"
else
    run_test "A4b: telemetry file created" "EXISTS" "MISSING"
fi

# A5: log rotation truncates when file exceeds maxLogSizeKB
TMPDIR_A5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A5")
mkdir -p "$TMPDIR_A5/.claude"
# Create a file with 100 lines (each ~100 bytes = ~10KB)
for i in $(seq 1 100); do
    echo "{\"ts\":\"2026-02-09T10:00:00+0000\",\"sessionId\":\"s1\",\"event\":\"match\",\"skill\":\"test:$i\",\"insert\":\"x\"}" >> "$TMPDIR_A5/.claude/skill-bus-telemetry.jsonl"
done
BEFORE=$(wc -l < "$TMPDIR_A5/.claude/skill-bus-telemetry.jsonl")
# Set maxLogSizeKB to 5 (5KB) — file is ~10KB, should trigger rotation
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
settings = {'maxLogSizeKB': 5}
log_event('match', '$TMPDIR_A5', settings=settings, skill='trigger:rotation', insert='x')
" 2>&1)
AFTER=$(wc -l < "$TMPDIR_A5/.claude/skill-bus-telemetry.jsonl")
if [ "$AFTER" -lt "$BEFORE" ]; then
    run_test "A5: log rotation reduced line count" "PASS" "PASS"
else
    run_test "A5: log rotation reduced line count" "REDUCED" "BEFORE=$BEFORE AFTER=$AFTER"
fi
# Verify the new event is present (rotation keeps recent entries)
CONTENT=$(cat "$TMPDIR_A5/.claude/skill-bus-telemetry.jsonl")
run_test "A5: rotation keeps new event" "trigger:rotation" "$CONTENT"

# A5b: no rotation when under limit
TMPDIR_A5b=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_A5b")
mkdir -p "$TMPDIR_A5b/.claude"
echo '{"ts":"2026-02-09T10:00:00+0000","sessionId":"s1","event":"match","skill":"test:small","insert":"x"}' > "$TMPDIR_A5b/.claude/skill-bus-telemetry.jsonl"
BEFORE_B=$(wc -l < "$TMPDIR_A5b/.claude/skill-bus-telemetry.jsonl")
python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
from telemetry import log_event
settings = {'maxLogSizeKB': 512}
log_event('match', '$TMPDIR_A5b', settings=settings, skill='test:small2', insert='x')
" 2>&1 > /dev/null
AFTER_B=$(wc -l < "$TMPDIR_A5b/.claude/skill-bus-telemetry.jsonl")
if [ "$AFTER_B" -eq 2 ]; then
    run_test "A5b: no rotation when under limit" "PASS" "PASS"
else
    run_test "A5b: no rotation when under limit" "2_LINES" "LINES=$AFTER_B"
fi

echo "=== Group B: fast path telemetry ==="

HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"

# B1: no_match logged from fast path when observeUnmatched enabled
TMPDIR_B1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_B1")
mkdir -p "$TMPDIR_B1/.claude"
cat > "$TMPDIR_B1/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true, "observeUnmatched": true},
  "inserts": {"x": {"text": "ctx"}},
  "subscriptions": [{"insert": "x", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOF
# Feed hook input JSON via stdin. Use a skill name that won't match anything.
HOOK_INPUT="{\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"telemetry-test:nonexistent-12345\"},\"cwd\":\"$TMPDIR_B1\"}"
echo "$HOOK_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$HOOKS_DIR/dispatch.sh" pre > /dev/null 2>&1
LOGFILE="$TMPDIR_B1/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "B1: no_match logged from fast path" '"event":"no_match"' "$CONTENT"
    run_test "B1: skill field" '"skill":"telemetry-test:nonexistent-12345"' "$CONTENT"
else
    run_test "B1: telemetry file created from fast path" "EXISTS" "MISSING"
fi

# B2: no_match logged from prompt-monitor fast path
TMPDIR_B2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_B2")
mkdir -p "$TMPDIR_B2/.claude"
cat > "$TMPDIR_B2/.claude/skill-bus.json" << 'EOF'
{
  "settings": {"telemetry": true, "observeUnmatched": true, "monitorSlashCommands": true},
  "inserts": {"x": {"text": "ctx"}},
  "subscriptions": [{"insert": "x", "on": "superpowers:writing-plans", "when": "pre"}]
}
EOF
HOOK_INPUT="{\"prompt\":\"/telemetry-test:nonexistent-12345\",\"cwd\":\"$TMPDIR_B2\"}"
echo "$HOOK_INPUT" | SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent bash "$HOOKS_DIR/prompt-monitor.sh" > /dev/null 2>&1
LOGFILE="$TMPDIR_B2/.claude/skill-bus-telemetry.jsonl"
if [ -f "$LOGFILE" ]; then
    CONTENT=$(cat "$LOGFILE")
    run_test "B2: no_match from prompt-monitor fast path" '"event":"no_match"' "$CONTENT"
else
    run_test "B2: telemetry file from prompt-monitor" "EXISTS" "MISSING"
fi

echo "=== Group C: CLI stats subcommand ==="

# C1: stats with match events shows summary
TMPDIR_C1=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C1")
mkdir -p "$TMPDIR_C1/.claude"
cat > "$TMPDIR_C1/.claude/skill-bus-telemetry.jsonl" << 'EOF'
{"ts":"2026-02-09T10:00:00+0000","sessionId":"abc123","event":"match","skill":"superpowers:writing-plans","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:01:00+0000","sessionId":"abc123","event":"match","skill":"superpowers:writing-plans","insert":"capture-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:05:00+0000","sessionId":"abc123","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:10:00+0000","sessionId":"abc123","event":"no_match","skill":"other-plugin:wrap-up","source":"fast_path"}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --cwd "$TMPDIR_C1")
run_test "C1: stats shows skills intercepted" "Skills intercepted: 1" "$RESULT"
run_test "C1: stats shows inserts injected" "Inserts injected: 2" "$RESULT"
run_test "C1: stats shows skill name" "superpowers:writing-plans" "$RESULT"
run_test "C1: stats shows condition skip" "Condition skips: 1" "$RESULT"
run_test "C1: stats shows no-coverage" "No coverage: 1" "$RESULT"

# C2: stats with no telemetry file
TMPDIR_C2=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C2")
mkdir -p "$TMPDIR_C2/.claude"
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --cwd "$TMPDIR_C2")
run_test "C2: stats with no data" "No telemetry data" "$RESULT"

# C3: stats --session filters by session ID (inclusion + exclusion)
TMPDIR_C3=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C3")
mkdir -p "$TMPDIR_C3/.claude"
cat > "$TMPDIR_C3/.claude/skill-bus-telemetry.jsonl" << 'EOF'
{"ts":"2026-02-09T10:00:00+0000","sessionId":"session1","event":"match","skill":"a:b","insert":"x","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:01:00+0000","sessionId":"session2","event":"match","skill":"c:d","insert":"y","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:02:00+0000","sessionId":"session1","event":"match","skill":"e:f","insert":"z","timing":"pre","source":"tool"}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --session session1 --cwd "$TMPDIR_C3")
run_test "C3: session filter includes session1 event 1" "a:b" "$RESULT"
run_test "C3: session filter includes session1 event 2" "e:f" "$RESULT"
run_test_absent "C3: session filter excludes session2" "c:d" "$RESULT"

# C4: stats shows top skills with per-insert hit rates
TMPDIR_C4=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C4")
mkdir -p "$TMPDIR_C4/.claude"
cat > "$TMPDIR_C4/.claude/skill-bus-telemetry.jsonl" << 'EOF'
{"ts":"2026-02-09T10:00:00+0000","sessionId":"s1","event":"match","skill":"superpowers:writing-plans","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:01:00+0000","sessionId":"s1","event":"match","skill":"superpowers:writing-plans","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:02:00+0000","sessionId":"s1","event":"match","skill":"superpowers:writing-plans","insert":"capture-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:03:00+0000","sessionId":"s1","event":"match","skill":"superpowers:brainstorming","insert":"compound-knowledge","timing":"pre","source":"tool"}
{"ts":"2026-02-09T10:04:00+0000","sessionId":"s1","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:05:00+0000","sessionId":"s1","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:06:00+0000","sessionId":"s1","event":"no_match","skill":"other-plugin:wrap-up","source":"fast_path"}
{"ts":"2026-02-09T10:07:00+0000","sessionId":"s1","event":"no_match","skill":"other-plugin:wrap-up","source":"fast_path"}
{"ts":"2026-02-09T10:08:00+0000","sessionId":"s1","event":"no_match","skill":"superpowers:debugging","source":"tool"}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --cwd "$TMPDIR_C4")
run_test "C4: shows skills intercepted count" "Skills intercepted: 2" "$RESULT"
run_test "C4: shows inserts injected count" "Inserts injected: 4" "$RESULT"
run_test "C4: top skill with invocation count" "superpowers:writing-plans" "$RESULT"
run_test "C4: per-insert hit rate" "compound-knowledge 2/3" "$RESULT"
run_test "C4: condition failure detail" "wip-context" "$RESULT"
run_test "C4: condition failure count" "2x" "$RESULT"
run_test "C4: no-coverage skill with count" "other-plugin:wrap-up" "$RESULT"

# C5: stats --days filters by age
TMPDIR_C5=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C5")
mkdir -p "$TMPDIR_C5/.claude"
# Write events: one from today, one from 10 days ago
TODAY=$(date -u +%Y-%m-%dT%H:%M:%S+0000)
OLD_DATE="2026-01-01T10:00:00+0000"
cat > "$TMPDIR_C5/.claude/skill-bus-telemetry.jsonl" << EOF
{"ts":"$TODAY","sessionId":"s1","event":"match","skill":"recent:skill","insert":"x","timing":"pre","source":"tool"}
{"ts":"$OLD_DATE","sessionId":"s2","event":"match","skill":"old:skill","insert":"y","timing":"pre","source":"tool"}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --days 7 --cwd "$TMPDIR_C5")
run_test "C5: --days includes recent event" "recent:skill" "$RESULT"
run_test_absent "C5: --days excludes old event" "old:skill" "$RESULT"

# C5b: stats without --days shows all events
RESULT_ALL=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --cwd "$TMPDIR_C5")
run_test "C5b: no --days shows recent" "recent:skill" "$RESULT_ALL"
run_test "C5b: no --days shows old" "old:skill" "$RESULT_ALL"

# C6: stats shows suggestions for no-coverage skills
TMPDIR_C6=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_C6")
mkdir -p "$TMPDIR_C6/.claude"
cat > "$TMPDIR_C6/.claude/skill-bus-telemetry.jsonl" << 'EOF'
{"ts":"2026-02-09T10:00:00+0000","sessionId":"s1","event":"no_match","skill":"superpowers:debugging","source":"tool"}
{"ts":"2026-02-09T10:01:00+0000","sessionId":"s1","event":"no_match","skill":"superpowers:debugging","source":"tool"}
{"ts":"2026-02-09T10:02:00+0000","sessionId":"s1","event":"no_match","skill":"superpowers:debugging","source":"tool"}
{"ts":"2026-02-09T10:03:00+0000","sessionId":"s1","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:04:00+0000","sessionId":"s1","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:05:00+0000","sessionId":"s1","event":"condition_skip","skill":"superpowers:writing-plans","insert":"wip-context","pattern":"superpowers:*"}
{"ts":"2026-02-09T10:06:00+0000","sessionId":"s1","event":"match","skill":"superpowers:writing-plans","insert":"compound","timing":"pre","source":"tool"}
EOF
RESULT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent python3 "$LIB_DIR/cli.py" stats --cwd "$TMPDIR_C6")
run_test "C6: suggests add-sub for uncovered skill" "/skill-bus:add-sub" "$RESULT"
run_test "C6: names the uncovered skill" "superpowers:debugging" "$RESULT"
run_test "C6: suggests investigating condition skips" "simulate" "$RESULT"
run_test "C6: shows Suggestions header" "Suggestions:" "$RESULT"

# ─── Group D: Completion telemetry ───
echo ""
echo "=== Group D: Completion telemetry ==="

# D1: skill_complete event logged when --timing complete fires
D_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$D_DIR")
mkdir -p "$D_DIR/.claude"
cat > "$D_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"telemetry": true, "completionHooks": true},
  "inserts": {"capture": {"text": "Capture solutions."}},
  "subscriptions": [
    {"insert": "capture", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF

D1_OUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$LIB_DIR/dispatcher.py" --timing complete --cwd "$D_DIR" 2>&1)
D1_LOG="$D_DIR/.claude/skill-bus-telemetry.jsonl"
D1_CONTENT=""
[ -f "$D1_LOG" ] && D1_CONTENT=$(cat "$D1_LOG")
run_test "D1a: skill_complete event logged" '"event":"skill_complete"' "$D1_CONTENT"
run_test "D1b: skill_complete has skill name" '"skill":"superpowers:debugging"' "$D1_CONTENT"

# D2: skill_complete NOT logged for pre timing (even with when:complete sub)
D2_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$D2_DIR")
mkdir -p "$D2_DIR/.claude"
cat > "$D2_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"telemetry": true, "completionHooks": true},
  "inserts": {"capture": {"text": "Capture solutions."}},
  "subscriptions": [
    {"insert": "capture", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF
SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$LIB_DIR/dispatcher.py" --timing pre --cwd "$D2_DIR" > /dev/null 2>&1
D2_LOG="$D2_DIR/.claude/skill-bus-telemetry.jsonl"
D2_CONTENT=""
[ -f "$D2_LOG" ] && D2_CONTENT=$(cat "$D2_LOG")
run_test_absent "D2: skill_complete NOT logged for pre timing" '"event":"skill_complete"' "$D2_CONTENT"

# D3: skill_complete NOT logged when telemetry disabled
D3_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$D3_DIR")
mkdir -p "$D3_DIR/.claude"
cat > "$D3_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"telemetry": false, "completionHooks": true},
  "inserts": {"capture": {"text": "Capture solutions."}},
  "subscriptions": [
    {"insert": "capture", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF
SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$LIB_DIR/dispatcher.py" --timing complete --cwd "$D3_DIR" > /dev/null 2>&1
if [ ! -f "$D3_DIR/.claude/skill-bus-telemetry.jsonl" ]; then
    run_test "D3: skill_complete NOT logged when telemetry disabled" "PASS" "PASS"
else
    run_test "D3: skill_complete NOT logged when telemetry disabled" "NO_FILE" "FILE_EXISTS"
fi

# D4: skill_complete NOT logged for post timing
D4_DIR=$(mktemp -d)
CLEANUP_DIRS+=("$D4_DIR")
mkdir -p "$D4_DIR/.claude"
cat > "$D4_DIR/.claude/skill-bus.json" <<'EOF'
{
  "settings": {"telemetry": true, "completionHooks": true},
  "inserts": {"capture": {"text": "Capture solutions."}},
  "subscriptions": [
    {"insert": "capture", "on": "superpowers:debugging", "when": "complete"}
  ]
}
EOF
SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="superpowers:debugging" \
    python3 "$LIB_DIR/dispatcher.py" --timing post --cwd "$D4_DIR" > /dev/null 2>&1
D4_LOG="$D4_DIR/.claude/skill-bus-telemetry.jsonl"
D4_CONTENT=""
[ -f "$D4_LOG" ] && D4_CONTENT=$(cat "$D4_LOG")
run_test_absent "D4: skill_complete NOT logged for post timing" '"event":"skill_complete"' "$D4_CONTENT"

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
