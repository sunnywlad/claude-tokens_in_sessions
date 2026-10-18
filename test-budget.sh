#!/usr/bin/env bash
# Tests for budget.sh and the status line segment. Run: bash ~/.claude/test-budget.sh
# Everything happens in a temp HOME, nothing real is touched.

SRC="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T"; mkdir -p "$T/.claude"
cp "$SRC/budget.sh" "$SRC/statusline.sh" "$T/.claude/"
export BUDGET_DIR="$T/.claude/budget" QUOTA_FILE="$T/.claude/quota.json"
export BUDGET_NOW=1000000
B="bash $T/.claude/budget.sh"
FUT=1005000   # resets_at inside the window (now + 5000 s)
FUT2=1023000  # a later window

pass=0; fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check DESC CONDITION-exit-code
  if [ "$2" -eq 0 ]; then ok; else bad "$1"; fi
}
quota() { echo "{\"used_percentage\": $1, \"resets_at\": ${2:-$FUT}}" > "$QUOTA_FILE"; }
prompt() { jq -n --arg s "$1" --arg p "$2" '{session_id: $s, prompt: $p, hook_event_name: "UserPromptSubmit"}' | $B prompt; }
tool() { jq -n --arg s "$1" '{session_id: $s, tool_name: "Bash", hook_event_name: "PostToolUse"}' | $B tool; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty'; }
state() { jq -r "$2" "$BUDGET_DIR/$1.json" 2>/dev/null; }
reset() { rm -rf "$BUDGET_DIR" "$QUOTA_FILE"; }

# 1. No prefix: nothing emitted, no state
reset; quota 11
out=$(prompt s1 "just a normal prompt")
check "no prefix: empty output" $([ -z "$out" ]; echo $?)
check "no prefix: no state" $([ ! -e "$BUDGET_DIR/s1.json" ]; echo $?)
out=$(prompt s1 "please explain budget:25 to me")
check "prefix not at start: ignored" $([ -z "$out" ] && [ ! -e "$BUDGET_DIR/s1.json" ]; echo $?)

# 2. Setting a budget
reset; quota 11
out=$(prompt s1 "budget:25 do the task")
check "set: start" $([ "$(state s1 .start)" = 11 ]; echo $?)
check "set: cap = start + 25" $([ "$(state s1 .cap)" = 36 ]; echo $?)
check "set: resets_at stored" $([ "$(state s1 .resets_at)" = $FUT ]; echo $?)
check "set: context says 25 %, cap 36" $(echo "$out" | ctx | grep -q "25 %.*plafond atteint à 36 %"; echo $?)
check "set: hookEventName" $([ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ]; echo $?)
check "set: no leftover tmp file" $([ -z "$(ls "$BUDGET_DIR" | grep tmp)" ]; echo $?)

# 3. Cap above 100 is bounded and says so
reset; quota 90
out=$(prompt s1 "budget:25 go")
check "bound: cap 100" $([ "$(state s1 .cap)" = 100 ]; echo $?)
check "bound: says so" $(echo "$out" | ctx | grep -q "ramené à 100"; echo $?)
check "bound: budget is 10" $(echo "$out" | ctx | grep -q "10 % de la fenêtre"; echo $?)

# 4. Window already used up
reset; quota 100
out=$(prompt s1 "budget:25 go")
check "full window: no state" $([ ! -e "$BUDGET_DIR/s1.json" ]; echo $?)
check "full window: says so" $(echo "$out" | ctx | grep -q "déjà consommée"; echo $?)

# 5. Quota unusable: absent, empty, malformed, stale. Set refuses, tool stays silent.
for kind in absent empty malformed stale; do
  reset; quota 11; prompt s1 "budget:25 go" > /dev/null   # valid state first, to test the tool hook
  case $kind in
    absent) rm -f "$QUOTA_FILE" ;;
    empty) : > "$QUOTA_FILE" ;;
    malformed) echo '{oops' > "$QUOTA_FILE" ;;
    stale) quota 40 999999 ;;   # resets_at in the past
  esac
  out=$(tool s1); rc=$?
  check "$kind: tool hook silent and rc 0" $([ -z "$out" ] && [ $rc -eq 0 ]; echo $?)
  rm -rf "$BUDGET_DIR"
  out=$(prompt s2 "budget:25 go")
  check "$kind: set writes no state" $([ ! -e "$BUDGET_DIR/s2.json" ]; echo $?)
  check "$kind: set explains" $(echo "$out" | ctx | grep -q "aucun budget posé"; echo $?)
done

# 6. budget:off
reset; quota 11; prompt s1 "budget:25 go" > /dev/null
out=$(prompt s1 "budget:off now")
check "off: state removed" $([ ! -e "$BUDGET_DIR/s1.json" ]; echo $?)
check "off: says so" $(echo "$out" | ctx | grep -q "supprimé"; echo $?)
out=$(prompt s9 "budget:off")
check "off without state: no crash" $([ $? -eq 0 ]; echo $?)

# 7. Thresholds: start 10, budget 20, cap 30. 50 % at used 20, 80 % at used 26, 100 % at used 30.
reset; quota 10; prompt s1 "budget:20 go" > /dev/null
quota 14; out=$(tool s1)
check "below 50 %: silent" $([ -z "$out" ]; echo $?)
quota 20; out=$(tool s1)
check "50 %: fires" $(echo "$out" | ctx | grep -q "50 % consommé (10/20"; echo $?)
check "50 %: event name" $([ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = PostToolUse ]; echo $?)
out=$(tool s1)
check "50 % again: silent (once per threshold)" $([ -z "$out" ]; echo $?)
quota 26; out=$(tool s1)
check "80 %: fires" $(echo "$out" | ctx | grep -q "80 % consommé"; echo $?)
out=$(tool s1)
check "80 % again: silent" $([ -z "$out" ]; echo $?)
quota 31; out=$(tool s1)
check "100 %: fires, tells to stop" $(echo "$out" | ctx | grep -q "plafond atteint.*Arrête-toi proprement.*résume"; echo $?)
out=$(tool s1)
check "100 % again: silent" $([ -z "$out" ]; echo $?)
check "fired list complete" $([ "$(state s1 '.fired | join(",")')" = "50,80,100" ]; echo $?)

# 8. A jump over several thresholds fires only the highest, and marks the lower ones
reset; quota 10; prompt s1 "budget:20 go" > /dev/null
quota 28; out=$(tool s1)
check "jump: one message, 80 %" $(echo "$out" | ctx | grep -q "80 % consommé"; echo $?)
out=$(tool s1)
check "jump: 50 % not replayed" $([ -z "$out" ]; echo $?)

# 9. Window reset during the task: consumed = (100 - start) + used_now
reset; quota 80; prompt s1 "budget:30 go" > /dev/null   # start 80, cap 100, budget 20
quota 5 $FUT2
out=$(tool s1)
check "reset: 25 consumed of 20 -> 100 % message" $(echo "$out" | ctx | grep -q "plafond atteint (25/20"; echo $?)
echo '{"used_percentage": 5, "resets_at": 1023000}' > "$QUOTA_FILE"
check "reset: status shows 25/20" $([ "$($B status s1)" = "25 20 125" ]; echo $?)
# jitter on resets_at (a few seconds) is not a reset
reset; quota 10; prompt s1 "budget:20 go" > /dev/null
quota 15 $((FUT + 3))
check "jitter: same window, consumed 5" $([ "$($B status s1 | cut -d' ' -f1)" = 5 ]; echo $?)

# 10. Two sessions, separate budgets
reset; quota 10
prompt sA "budget:20 go" > /dev/null
quota 20
prompt sB "budget:5 go" > /dev/null
check "two sessions: separate files" $([ "$(state sA .cap)" = 30 ] && [ "$(state sB .cap)" = 25 ] && [ "$(state sB .start)" = 20 ]; echo $?)
outA=$(tool sA); outB=$(tool sB)
check "two sessions: A at 50 %, B silent" $(echo "$outA" | ctx | grep -q "50 %" && [ -z "$outB" ]; echo $?)
check "two sessions: B untouched by A" $([ "$(state sB '.fired | length')" = 0 ]; echo $?)

# 11. Session without a budget: tool hook silent
reset; quota 50
out=$(tool nobudget)
check "no budget: silent" $([ -z "$out" ]; echo $?)

# 12. Unsafe or missing session_id
reset; quota 11
echo '{"prompt": "budget:25 go"}' | $B prompt > /dev/null
check "no session_id: no state" $([ ! -d "$BUDGET_DIR" ] || [ -z "$(ls "$BUDGET_DIR")" ]; echo $?)
prompt "../evil" "budget:25 go" > /dev/null
check "path-like session_id refused" $([ ! -e "$T/.claude/evil.json" ] && [ -z "$(ls "$BUDGET_DIR" 2>/dev/null)" ]; echo $?)
echo 'not json' | $B prompt; check "garbage stdin: rc 0" $([ $? -eq 0 ]; echo $?)
echo 'not json' | $B tool; check "garbage stdin (tool): rc 0" $([ $? -eq 0 ]; echo $?)

# 13. Cleanup of dead sessions by age (24 h), at the next prompt
reset; quota 11; prompt old "budget:25 go" > /dev/null; prompt young "budget:25 go" > /dev/null
touch -d '3 days ago' "$BUDGET_DIR/old.json"
prompt young "hello" > /dev/null
check "cleanup: old removed" $([ ! -e "$BUDGET_DIR/old.json" ]; echo $?)
check "cleanup: young kept" $([ -e "$BUDGET_DIR/young.json" ]; echo $?)

# 14. Resume: same session_id keeps its state (if the id is stable, see report)
reset; quota 10; prompt r1 "budget:20 go" > /dev/null
quota 20; prompt r1 "continue" > /dev/null
check "resume: state kept as is" $([ "$(state r1 .start)" = 10 ]; echo $?)
# Re-issuing a budget replaces the old one with a fresh start
prompt r1 "budget:10 again" > /dev/null
check "re-issue: new start" $([ "$(state r1 .start)" = 20 ] && [ "$(state r1 '.fired | length')" = 0 ]; echo $?)

# 15. Status line segment
sl() { jq -n --arg s "$1" '{session_id: $s, context_window: {}, rate_limits: {five_hour: {used_percentage: '"$2"', resets_at: '"$FUT"'}}}' | bash "$T/.claude/statusline.sh" 2>/dev/null; }
reset; quota 10; prompt sl1 "budget:20 go" > /dev/null
out=$(sl sl1 12)
check "statusline: segment task 2/20" $(echo "$out" | grep -q "task 2/20"; echo $?)
check "statusline: green under 80 %" $(echo "$out" | grep -q $'\033\[32mtask'; echo $?)
out=$(sl sl1 27)
check "statusline: orange at 85 %" $(echo "$out" | grep -q $'\033\[38;5;208mtask 17/20'; echo $?)
out=$(sl sl1 33)
check "statusline: red beyond 100 %" $(echo "$out" | grep -q $'\033\[31mtask 23/20'; echo $?)
out=$(sl nobudget 12)
check "statusline: no segment without budget" $(echo "$out" | grep -qv "task"; echo $?)
check "statusline: still prints 5h part" $(echo "$out" | grep -q "5h"; echo $?)

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
