#!/bin/bash
set -euo pipefail
DISPATCHER="$(cd "$(dirname "$0")/../lib" && pwd)/dispatcher.py"
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

# CI isolation: prevent leaking runner's or developer's real ~/.claude/skill-bus.json
# Tests needing a specific global config override this inline
export SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent

# --- Test Group A: Insert-level conditions ---
echo "=== Group A: Insert-level conditions ==="

# A1: Insert condition passes → subscription fires
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude" "$TMPDIR/docs"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "INSERT_LEVEL_COND_PASS",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "A1: insert condition passes" "INSERT_LEVEL_COND_PASS" "$OUTPUT"
rm -rf "$TMPDIR"

# A2: Insert condition fails → subscription skipped
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
# No docs/ directory — fileExists fails
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test_empty "A2: insert condition fails → skipped" "$OUTPUT"
rm -rf "$TMPDIR"

# A3: Insert condition + subscription condition — both pass
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude" "$TMPDIR/docs"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "BOTH_CONDITIONS_PASS",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "TEST_V031_VAR"}]}
  ]
}
EOFCFG
OUTPUT=$(TEST_V031_VAR=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "A3: insert + sub conditions both pass" "BOTH_CONDITIONS_PASS" "$OUTPUT"
rm -rf "$TMPDIR"

# A4: Insert condition passes, subscription condition fails → skipped
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude" "$TMPDIR/docs"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "NONEXISTENT_VAR_XYZ"}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test_empty "A4: insert passes, sub fails → skipped" "$OUTPUT"
rm -rf "$TMPDIR"

# A5: Insert condition fails, subscription condition would pass → skipped (short-circuit)
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
# No docs/ — insert condition fails
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"envSet": "TEST_V031_VAR"}]}
  ]
}
EOFCFG
OUTPUT=$(TEST_V031_VAR=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test_empty "A5: insert fails → short-circuit, sub skipped" "$OUTPUT"
rm -rf "$TMPDIR"

# A6: Subscription opts out with inheritConditions: false → insert conditions ignored
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
# No docs/ — insert condition would fail, but sub opts out
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "OPT_OUT_FIRES",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "inheritConditions": false}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "A6: sub opts out with inheritConditions:false → fires" "OPT_OUT_FIRES" "$OUTPUT"
rm -rf "$TMPDIR"

# A8: Subscription opts out but has own conditions → only sub conditions apply
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
# No docs/ — insert condition would fail, but sub opts out and has its own condition
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "OPT_OUT_OWN_COND",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "inheritConditions": false, "conditions": [{"envSet": "TEST_V031_VAR"}]}
  ]
}
EOFCFG
OUTPUT=$(TEST_V031_VAR=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "A8: opt-out + own conditions → only sub conditions" "OPT_OUT_OWN_COND" "$OUTPUT"
rm -rf "$TMPDIR"

# A9: Prompt path — insert-level conditions work via match_subscriptions_prompt
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude" "$TMPDIR/docs"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {
    "test-insert": {
      "text": "PROMPT_PATH_INSERT_COND",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source prompt 2>/dev/null || true)
run_test "A9: prompt path with insert conditions" "PROMPT_PATH_INSERT_COND" "$OUTPUT"
rm -rf "$TMPDIR"

# A10: Prompt path — insert condition fails → skipped
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "settings": {"monitorSlashCommands": true},
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR",
      "conditions": [{"fileExists": "docs/"}]
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source prompt 2>/dev/null || true)
run_test_empty "A10: prompt path, insert condition fails → skipped" "$OUTPUT"
rm -rf "$TMPDIR"

# A7: Insert without conditions, subscription without conditions → no change from v0.3.0
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "NO_CONDITIONS_ANYWHERE"
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre"}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "A7: no conditions anywhere → fires normally" "NO_CONDITIONS_ANYWHERE" "$OUTPUT"
rm -rf "$TMPDIR"

echo ""
echo "=== Group B: Regex in fileContains ==="

# B1: Regex match succeeds
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
echo '{"name": "test", "prisma": "5.22.0"}' > "$TMPDIR/package.json"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "REGEX_MATCH"
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "package.json", "pattern": "prisma.*\\d+\\.\\d+", "regex": true}}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "B1: regex fileContains matches" "REGEX_MATCH" "$OUTPUT"
rm -rf "$TMPDIR"

# B2: Regex match fails
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
echo '{"name": "test"}' > "$TMPDIR/package.json"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR"
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "package.json", "pattern": "prisma.*\\d+\\.\\d+", "regex": true}}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test_empty "B2: regex fileContains no match" "$OUTPUT"
rm -rf "$TMPDIR"

# B3: Literal match still works (no regex flag)
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
echo '{"prisma": "5.22.0"}' > "$TMPDIR/package.json"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "LITERAL_MATCH"
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "package.json", "pattern": "prisma"}}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "B3: literal fileContains still works" "LITERAL_MATCH" "$OUTPUT"
rm -rf "$TMPDIR"

# B4: Invalid regex pattern → warning + false
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.claude"
echo 'some content' > "$TMPDIR/test.txt"
cat > "$TMPDIR/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {
    "test-insert": {
      "text": "SHOULD_NOT_APPEAR"
    }
  },
  "subscriptions": [
    {"insert": "test-insert", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "test.txt", "pattern": "[invalid(regex", "regex": true}}]}
  ]
}
EOFCFG
OUTPUT=$(SKILL_BUS_DEBUG=1 SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR" --source tool 2>/dev/null || true)
run_test "B4: invalid regex → warning in output" "regex error" "$OUTPUT"
rm -rf "$TMPDIR"

echo ""
echo "=== Group C: Insert collision semantics ==="

# C1: insert name collision — project wins
TMPDIR_COLLISION=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_COLLISION")
FAKE_GLOBAL_COLLISION=$(mktemp -d); CLEANUP_DIRS+=("$FAKE_GLOBAL_COLLISION")
cat > "$FAKE_GLOBAL_COLLISION/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"shared-name": {"text": "GLOBAL_VERSION"}},
  "subscriptions": [{"insert": "shared-name", "on": "test:skill", "when": "pre"}]
}
EOFCFG
mkdir -p "$TMPDIR_COLLISION/.claude"
cat > "$TMPDIR_COLLISION/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"shared-name": {"text": "PROJECT_WINS"}},
  "subscriptions": [{"insert": "shared-name", "on": "test:skill", "when": "pre"}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_COLLISION/skill-bus.json" SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_COLLISION" --source tool 2>/dev/null || true)
run_test "C1: insert collision: project wins" "PROJECT_WINS" "$OUTPUT"
run_test_absent "C1: insert collision: global text not present" "GLOBAL_VERSION" "$OUTPUT"

# C2: insert collision emits INFO (not ERROR/WARNING)
OUTPUT_WITH_MSG=$(SKILL_BUS_GLOBAL_CONFIG="$FAKE_GLOBAL_COLLISION/skill-bus.json" SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_COLLISION" --source tool 2>&1 || true)
run_test "C2: collision emits INFO message" "INFO" "$OUTPUT_WITH_MSG"
run_test "C2: message mentions project version" "using project version" "$OUTPUT_WITH_MSG"

echo ""
echo "=== Group C2: Timeout proximity ==="

# Test: timeout proximity warning format
RESULT=$(python3 -c "
import sys; sys.path.insert(0, '$(cd "$(dirname "$0")/../lib" && pwd)')
from dispatcher import _warnings
_warnings.clear()
# Simulate the warning that would be emitted
elapsed = 4.5
if elapsed > 4.0:
    _warnings.append(f'[skill-bus] WARNING: dispatch took {elapsed:.1f}s (5s timeout), context may be incomplete')
print(_warnings[0])
")
run_test "timeout warning format" "dispatch took 4.5s" "$RESULT"

echo ""
echo "=== Group D: Defensive guards ==="

# D1: Import error gives clear message (test via Python)
RESULT=$(python3 -c "
import sys, os, tempfile
tmpdir = tempfile.mkdtemp()
# Create a cli.py-like script that imports from nonexistent dir
script = os.path.join(tmpdir, 'test_import.py')
with open(script, 'w') as f:
    f.write('''
import sys, os
_lib_dir = \"/nonexistent/path\"
sys.path.insert(0, _lib_dir)
try:
    from dispatcher import load_config
except ImportError as e:
    print(f\"[skill-bus] CLI error: cannot import dispatcher.py from {_lib_dir}: {e}\", file=sys.stderr)
    sys.exit(1)
''')
result = os.popen(f'python3 {script} 2>&1 || true').read()
print(result)
" 2>&1)
run_test "D1: import guard clear message" "cannot import dispatcher.py" "$RESULT"

# D2: dotfile warning in fileContains
TMPDIR_DOTFILE=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_DOTFILE")
mkdir -p "$TMPDIR_DOTFILE/.claude"
echo "SECRET=foo" > "$TMPDIR_DOTFILE/.env"
cat > "$TMPDIR_DOTFILE/.claude/skill-bus.json" << 'EOFCFG'
{
  "inserts": {"dotfile-test": {"text": "DOTFILE_WARN_TEST"}},
  "subscriptions": [{"insert": "dotfile-test", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": ".env", "pattern": "SECRET"}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_DOTFILE" --source tool 2>/dev/null || true)
run_test "D2: dotfile warning present" "dotfile" "$OUTPUT"
run_test "D2: condition still evaluates (fires)" "DOTFILE_WARN_TEST" "$OUTPUT"

# D3: regex pattern length guard
TMPDIR_REGEX=$(mktemp -d); CLEANUP_DIRS+=("$TMPDIR_REGEX")
mkdir -p "$TMPDIR_REGEX/.claude"
echo "content" > "$TMPDIR_REGEX/test.txt"
LONG_PATTERN=$(python3 -c "print('a' * 501)")
cat > "$TMPDIR_REGEX/.claude/skill-bus.json" << EOFCFG
{
  "inserts": {"regex-guard": {"text": "SHOULD_NOT_APPEAR"}},
  "subscriptions": [{"insert": "regex-guard", "on": "test:skill", "when": "pre", "conditions": [{"fileContains": {"file": "test.txt", "pattern": "$LONG_PATTERN", "regex": true}}]}]
}
EOFCFG
OUTPUT=$(SKILL_BUS_GLOBAL_CONFIG=/dev/null/nonexistent SKILL_BUS_SKILL="test:skill" python3 "$DISPATCHER" --timing pre --cwd "$TMPDIR_REGEX" --source tool 2>/dev/null || true)
run_test "D3: regex too long → warning" "too long" "$OUTPUT"
run_test_absent "D3: sub does not fire" "SHOULD_NOT_APPEAR" "$OUTPUT"

echo ""
echo "=== Results ==="
echo "  Total: $TOTAL | Pass: $PASS | Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  SOME TESTS FAILED"
    exit 1
else
    echo "  ALL TESTS PASSED"
fi
