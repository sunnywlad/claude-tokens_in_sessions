#!/usr/bin/env bash
# Tests for count.sh and the status line segment. Run: bash ~/.claude/test-count.sh
# Everything happens in a temp HOME, nothing real is touched.

SRC="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T"; mkdir -p "$T/.claude"
cp "$SRC/count.sh" "$SRC/statusline.sh" "$T/.claude/"
export COUNT_DIR="$T/.claude/count" QUOTA_FILE="$T/.claude/quota.json"
export COUNT_NOW=1000000
B="bash $T/.claude/count.sh"
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
state() { jq -r "$2" "$COUNT_DIR/$1.json" 2>/dev/null; }
reset() { rm -rf "$COUNT_DIR" "$QUOTA_FILE"; }

# 1. No prefix: nothing emitted, no state
reset; quota 11
out=$(prompt s1 "just a normal prompt")
check "no prefix: empty output" $([ -z "$out" ]; echo $?)
check "no prefix: no state" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
out=$(prompt s1 "please explain count:25 to me")
check "prefix not at start: ignored" $([ -z "$out" ] && [ ! -e "$COUNT_DIR/s1.json" ]; echo $?)

# 2. Setting a count
reset; quota 11
out=$(prompt s1 "count:25 do the task")
check "set: start" $([ "$(state s1 .start)" = 11 ]; echo $?)
check "set: cap = start + 25" $([ "$(state s1 .cap)" = 36 ]; echo $?)
check "set: resets_at stored" $([ "$(state s1 .resets_at)" = $FUT ]; echo $?)
check "set: context says 25 %, cap 36" $(echo "$out" | ctx | grep -q "25 %.*plafond atteint à 36 %"; echo $?)
check "set: hookEventName" $([ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = UserPromptSubmit ]; echo $?)
check "set: no leftover tmp file" $([ -z "$(ls "$COUNT_DIR" | grep tmp)" ]; echo $?)

# 3. Cap above 100 is bounded and says so
reset; quota 90
out=$(prompt s1 "count:25 go")
check "bound: cap 100" $([ "$(state s1 .cap)" = 100 ]; echo $?)
check "bound: says so" $(echo "$out" | ctx | grep -q "ramené à 100"; echo $?)
check "bound: count is 10" $(echo "$out" | ctx | grep -q "10 % de la fenêtre"; echo $?)

# 4. Window already used up
reset; quota 100
out=$(prompt s1 "count:25 go")
check "full window: no state" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
check "full window: says so" $(echo "$out" | ctx | grep -q "déjà consommée"; echo $?)

# 5. Quota unusable: absent, empty, malformed, stale. Set refuses, tool stays silent.
for kind in absent empty malformed stale; do
  reset; quota 11; prompt s1 "count:25 go" > /dev/null   # valid state first, to test the tool hook
  case $kind in
    absent) rm -f "$QUOTA_FILE" ;;
    empty) : > "$QUOTA_FILE" ;;
    malformed) echo '{oops' > "$QUOTA_FILE" ;;
    stale) quota 40 999999 ;;   # resets_at in the past
  esac
  out=$(tool s1); rc=$?
  check "$kind: tool hook silent and rc 0" $([ -z "$out" ] && [ $rc -eq 0 ]; echo $?)
  rm -rf "$COUNT_DIR"
  out=$(prompt s2 "count:25 go")
  check "$kind: set writes no state" $([ ! -e "$COUNT_DIR/s2.json" ]; echo $?)
  check "$kind: set explains" $(echo "$out" | ctx | grep -q "aucun compte posé"; echo $?)
done

# 6. count:off
reset; quota 11; prompt s1 "count:25 go" > /dev/null
out=$(prompt s1 "count:off now")
check "off: state removed" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
check "off: says so" $(echo "$out" | ctx | grep -q "supprimé"; echo $?)
out=$(prompt s9 "count:off")
check "off without state: no crash" $([ $? -eq 0 ]; echo $?)

# 7. Thresholds: start 10, count 20, cap 30. 50 % at used 20, 80 % at used 26, 100 % at used 30.
reset; quota 10; prompt s1 "count:20 go" > /dev/null
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
check "100 %: fires, tells to stop" $(echo "$out" | ctx | grep -q "plafond atteint.*Arrête-toi à la fin de cette étape.*résume"; echo $?)
out=$(tool s1)
check "100 % again: silent" $([ -z "$out" ]; echo $?)
check "fired list complete" $([ "$(state s1 '.fired | join(",")')" = "50,80,100" ]; echo $?)

# 8. A jump over several thresholds fires only the highest, and marks the lower ones
reset; quota 10; prompt s1 "count:20 go" > /dev/null
quota 28; out=$(tool s1)
check "jump: one message, 80 %" $(echo "$out" | ctx | grep -q "80 % consommé"; echo $?)
out=$(tool s1)
check "jump: 50 % not replayed" $([ -z "$out" ]; echo $?)

# 9. Window reset during the task: consumed = (100 - start) + used_now
reset; quota 80; prompt s1 "count:30 go" > /dev/null   # start 80, cap 100, count 20
quota 5 $FUT2
out=$(tool s1)
check "reset: 25 consumed of 20 -> 100 % message" $(echo "$out" | ctx | grep -q "plafond atteint (25/20"; echo $?)
echo '{"used_percentage": 5, "resets_at": 1023000}' > "$QUOTA_FILE"
check "reset: status shows 25/20" $([ "$($B status s1)" = "25 20 125" ]; echo $?)
# jitter on resets_at (a few seconds) is not a reset
reset; quota 10; prompt s1 "count:20 go" > /dev/null
quota 15 $((FUT + 3))
check "jitter: same window, consumed 5" $([ "$($B status s1 | cut -d' ' -f1)" = 5 ]; echo $?)

# 10. Two sessions, separate counts
reset; quota 10
prompt sA "count:20 go" > /dev/null
quota 20
prompt sB "count:5 go" > /dev/null
check "two sessions: separate files" $([ "$(state sA .cap)" = 30 ] && [ "$(state sB .cap)" = 25 ] && [ "$(state sB .start)" = 20 ]; echo $?)
outA=$(tool sA); outB=$(tool sB)
check "two sessions: A at 50 %, B silent" $(echo "$outA" | ctx | grep -q "50 %" && [ -z "$outB" ]; echo $?)
check "two sessions: B untouched by A" $([ "$(state sB '.fired | length')" = 0 ]; echo $?)

# 11. Session without a count: tool hook silent
reset; quota 50
out=$(tool nocount)
check "no count: silent" $([ -z "$out" ]; echo $?)

# 12. Unsafe or missing session_id
reset; quota 11
echo '{"prompt": "count:25 go"}' | $B prompt > /dev/null
check "no session_id: no state" $([ ! -d "$COUNT_DIR" ] || [ -z "$(ls "$COUNT_DIR")" ]; echo $?)
prompt "../evil" "count:25 go" > /dev/null
check "path-like session_id refused" $([ ! -e "$T/.claude/evil.json" ] && [ -z "$(ls "$COUNT_DIR" 2>/dev/null)" ]; echo $?)
echo 'not json' | $B prompt; check "garbage stdin: rc 0" $([ $? -eq 0 ]; echo $?)
echo 'not json' | $B tool; check "garbage stdin (tool): rc 0" $([ $? -eq 0 ]; echo $?)

# 13. Cleanup of dead sessions by age (24 h), at the next prompt
reset; quota 11; prompt old "count:25 go" > /dev/null; prompt young "count:25 go" > /dev/null
touch -d '3 days ago' "$COUNT_DIR/old.json"
prompt young "hello" > /dev/null
check "cleanup: old removed" $([ ! -e "$COUNT_DIR/old.json" ]; echo $?)
check "cleanup: young kept" $([ -e "$COUNT_DIR/young.json" ]; echo $?)

# 14. Resume: same session_id keeps its state (if the id is stable, see report)
reset; quota 10; prompt r1 "count:20 go" > /dev/null
quota 20; prompt r1 "continue" > /dev/null
check "resume: state kept as is" $([ "$(state r1 .start)" = 10 ]; echo $?)
# Re-issuing a count replaces the old one with a fresh start
prompt r1 "count:10 again" > /dev/null
check "re-issue: new start" $([ "$(state r1 .start)" = 20 ] && [ "$(state r1 '.fired | length')" = 0 ]; echo $?)

# 15. Status line segment
sl() { jq -n --arg s "$1" '{session_id: $s, context_window: {}, rate_limits: {five_hour: {used_percentage: '"$2"', resets_at: '"$FUT"'}}}' | bash "$T/.claude/statusline.sh" 2>/dev/null; }
reset; quota 10; prompt sl1 "count:20 go" > /dev/null
out=$(sl sl1 12)
check "statusline: segment task 2/20" $(echo "$out" | grep -q "task 2/20"; echo $?)
check "statusline: green under 80 %" $(echo "$out" | grep -q $'\033\[32mtask'; echo $?)
out=$(sl sl1 27)
check "statusline: orange at 85 %" $(echo "$out" | grep -q $'\033\[38;5;208mtask 17/20'; echo $?)
out=$(sl sl1 33)
check "statusline: red beyond 100 %" $(echo "$out" | grep -q $'\033\[31mtask 23/20'; echo $?)
quota 12; out=$(sl nocount 12)
check "statusline: no segment without count" $(echo "$out" | grep -qv "task"; echo $?)
check "statusline: still prints 5h part" $(echo "$out" | grep -q "5h"; echo $?)
check "statusline: 5h shows used (12 %), not left" $(echo "$out" | grep -q "5h 12%" && ! echo "$out" | grep -q "left"; echo $?)

# 16. PreToolUse lock from 90 % of the count: start 10, count 20, cap 30; 90 % = used 28
pre() { jq -n --arg s "$1" --arg a "${2:-}" '{session_id: $s, tool_name: "Bash", hook_event_name: "PreToolUse"} + (if $a != "" then {agent_id: $a} else {} end)' | $B pre; }
stopev() { jq -n --arg s "$1" '{session_id: $s, hook_event_name: "Stop", stop_hook_active: false}' | $B stop; }
reset; quota 10; prompt s1 "count:20 go" > /dev/null
quota 27; out=$(pre s1)
check "lock: silent at 85 %" $([ -z "$out" ]; echo $?)
quota 28; out=$(pre s1)
check "lock: deny at 90 %" $([ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = deny ]; echo $?)
check "lock: event name" $([ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = PreToolUse ]; echo $?)
reason=$(echo "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)
check "lock: reason offers finish, new cap, off" $(echo "$reason" | grep -q "count:finish" && echo "$reason" | grep -q "count:N" && echo "$reason" | grep -q "count:off"; echo $?)
check "lock: reason gives global window left" $(echo "$reason" | grep -q "72 %"; echo $?)
check "lock: reason says ask the user" $(echo "$reason" | grep -qi "demande"; echo $?)
out=$(pre s1 agent42)
check "lock: subagent told to hand back to orchestrator" $(echo "$out" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -q "orchestrateur"; echo $?)
out=$(pre nocount)
check "lock: no count, silent" $([ -z "$out" ]; echo $?)
echo 'not json' | $B pre; check "lock: garbage stdin rc 0" $([ $? -eq 0 ]; echo $?)
rm -f "$QUOTA_FILE"; out=$(pre s1)
check "lock: quota unusable, silent" $([ -z "$out" ]; echo $?)

# 17. The three answers to a lock: finish, new cap, off
reset; quota 10; prompt s1 "count:20 go" > /dev/null; quota 29
out=$(prompt s1 "count:finish")
check "finish: grant stored" $([ "$(state s1 .grant)" = true ]; echo $?)
check "finish: says so" $(echo "$out" | ctx | grep -q "étape en cours"; echo $?)
check "finish: lock lifted" $([ -z "$(pre s1)" ]; echo $?)
stopev s1
check "finish: grant cleared at end of turn" $([ "$(state s1 '.grant // false')" = false ]; echo $?)
check "finish: lock back after the turn" $([ -n "$(pre s1)" ]; echo $?)
out=$(prompt s1 "count:10 more")
check "new cap: fresh start at current use" $([ "$(state s1 .start)" = 29 ] && [ "$(state s1 .cap)" = 39 ]; echo $?)
check "new cap: lock lifted" $([ -z "$(pre s1)" ]; echo $?)
quota 38; prompt s1 "count:off" > /dev/null
check "off: state removed after lock" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
check "off: no lock" $([ -z "$(pre s1)" ]; echo $?)
out=$(prompt s9 "count:finish")
check "finish without count: says none, no state" $(echo "$out" | ctx | grep -q "aucun compte" && [ ! -e "$COUNT_DIR/s9.json" ]; echo $?)
stopev nocount; check "stop without state: rc 0" $([ $? -eq 0 ]; echo $?)
check "stop: silent" $([ -z "$(stopev nocount)" ]; echo $?)

# 18. Messages tell the session how the count gets closed
reset; quota 10; out=$(prompt s1 "count:20 go")
check "set: tells to ask the user before closing the count" $(echo "$out" | ctx | grep -q "count:off"; echo $?)
quota 31; out=$(tool s1)
check "100 %: asks the user, offers finish" $(echo "$out" | ctx | grep -q "count:finish"; echo $?)

# 19. Lock on the prompt: from 90 % only count: prefixes pass, any other prompt is blocked
reset; quota 10; prompt s1 "count:20 go" > /dev/null
quota 27; out=$(prompt s1 "an ordinary question")
check "prompt lock: silent at 85 %" $([ -z "$out" ]; echo $?)
quota 28; out=$(prompt s1 "an ordinary question")
check "prompt lock: block at 90 %" $([ "$(echo "$out" | jq -r .decision)" = block ]; echo $?)
reason=$(echo "$out" | jq -r .reason)
check "prompt lock: reason offers finish, new cap, off" $(echo "$reason" | grep -q "count:finish" && echo "$reason" | grep -q "count:N" && echo "$reason" | grep -q "count:off"; echo $?)
check "prompt lock: block, no context injected" $([ -z "$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')" ]; echo $?)
out=$(prompt s1 "count:finish")
check "prompt lock: count:finish passes" $([ "$(state s1 .grant)" = true ] && [ -z "$(echo "$out" | jq -r '.decision // empty')" ]; echo $?)
out=$(prompt s1 "an ordinary question")
check "prompt lock: ordinary prompt passes under a grant" $([ -z "$out" ]; echo $?)
stopev s1
out=$(prompt s1 "count:5 more")
check "prompt lock: count:N passes" $([ "$(state s1 .start)" = 28 ] && [ -z "$(echo "$out" | jq -r '.decision // empty')" ]; echo $?)
quota 28; prompt s1 "count:off" > /dev/null
check "prompt lock: count:off passes" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
out=$(prompt s1 "an ordinary question")
check "prompt lock: no count, never blocked" $([ -z "$out" ]; echo $?)
reset; quota 10; prompt s1 "count:20 go" > /dev/null; quota 29; rm -f "$QUOTA_FILE"
out=$(prompt s1 "an ordinary question")
check "prompt lock: quota unusable, never blocked" $([ -z "$out" ]; echo $?)

# 20. quota.json never goes backwards inside a window: a session with stale data must not overwrite a fresher value
sl2() { jq -n --arg s "$1" '{session_id: $s, context_window: {}, rate_limits: {five_hour: {used_percentage: '"$2"', resets_at: '"$3"'}}}' | bash "$T/.claude/statusline.sh" >/dev/null 2>&1; }
qv() { jq -r "$1" "$QUOTA_FILE"; }
reset; mkdir -p "$T/.claude"
sl2 a 55 $FUT
sl2 b 52 $FUT
check "quota merge: stale lower value ignored in the same window" $([ "$(qv .used_percentage)" = 55 ]; echo $?)
sl2 b 57 $FUT
check "quota merge: higher value taken" $([ "$(qv .used_percentage)" = 57 ]; echo $?)
sl2 b 53 $((FUT + 3))
check "quota merge: lower value ignored despite resets_at jitter" $([ "$(qv .used_percentage)" = 57 ]; echo $?)
sl2 c 4 $FUT2
check "quota merge: newer window replaces, even lower" $([ "$(qv .used_percentage)" = 4 ] && [ "$(qv .resets_at)" = $FUT2 ]; echo $?)
sl2 d 60 $FUT
check "quota merge: older window from a stale session ignored" $([ "$(qv .used_percentage)" = 4 ] && [ "$(qv .resets_at)" = $FUT2 ]; echo $?)

# 21. An idle session shows the freshest 5h figure known to quota.json, not its own stale stdin
slout() { jq -n --arg s "$1" '{session_id: $s, context_window: {}, rate_limits: {five_hour: {used_percentage: '"$2"', resets_at: '"$3"'}}}' | bash "$T/.claude/statusline.sh" 2>/dev/null; }
reset; quota 55
out=$(slout idle 52 $FUT)
check "idle: stale stdin 52 shows the fresher 55 from quota.json" $(echo "$out" | grep -q "5h 55%"; echo $?)
quota 55
out=$(slout idle 57 $FUT)
check "idle: fresher stdin 57 is kept" $(echo "$out" | grep -q "5h 57%"; echo $?)
quota 4 $FUT2
out=$(slout idle 60 $FUT)
check "idle: stdin from an older window shows the newer window of quota.json" $(echo "$out" | grep -q "5h 4%"; echo $?)
quota 4 $((FUT - 9000))
out=$(slout idle 30 $FUT)
check "idle: quota.json from an older window is ignored" $(echo "$out" | grep -q "5h 30%"; echo $?)
reset
out=$(slout idle 30 $FUT)
check "idle: no quota.json, stdin shown" $(echo "$out" | grep -q "5h 30%"; echo $?)

# 22. Transcript tokens: `count.sh tokens PATH` prints "model input cache_write cache_read output",
# one line per model, deduplicated by message.id, sub-agent files (<PATH minus .jsonl>/subagents/*.jsonl) included
msg() { # msg ID MODEL IN CACHE_WRITE CACHE_READ OUT
  jq -nc --arg id "$1" --arg m "$2" --argjson i "$3" --argjson cw "$4" --argjson cr "$5" --argjson o "$6" \
    '{type: "assistant", message: {id: $id, model: $m, usage: {input_tokens: $i, cache_creation_input_tokens: $cw, cache_read_input_tokens: $cr, output_tokens: $o}}}'
}
TR="$T/proj/tr1.jsonl"; mkdir -p "$T/proj/tr1/subagents"
{
  echo '{"type":"user","message":{"content":"hello"}}'
  msg m1 sonnet 2 100 1000 10
  msg m1 sonnet 2 100 1000 10        # same API message, second content block
  msg m2 sonnet 3 50 2000 20
  msg m3 opus 1 10 500 5
  echo '{"type":"system","subtype":"turn_duration"}'
} > "$TR"
out=$($B tokens "$TR")
check "tokens: duplicate message.id counted once, per model" $([ "$(echo "$out" | grep '^sonnet ')" = "sonnet 5 150 3000 30" ]; echo $?)
check "tokens: second model on its own line" $([ "$(echo "$out" | grep '^opus ')" = "opus 1 10 500 5" ]; echo $?)
check "tokens: non-assistant lines ignored" $([ "$(echo "$out" | wc -l)" = 2 ]; echo $?)
{ msg a1 sonnet 1 20 300 4; msg a1 sonnet 1 20 300 4; msg a2 haiku 2 0 100 1; } > "$T/proj/tr1/subagents/agent-x.jsonl"
out=$($B tokens "$TR")
check "tokens: sub-agent usage added to the same model" $([ "$(echo "$out" | grep '^sonnet ')" = "sonnet 6 170 3300 34" ]; echo $?)
check "tokens: sub-agent model with no parent line appears" $([ "$(echo "$out" | grep '^haiku ')" = "haiku 2 0 100 1" ]; echo $?)
printf '%s' '{"type":"assistant","message":{"id":"cut","model":"sonn' >> "$TR"   # half-written last line
out=$($B tokens "$TR"); rc=$?
check "tokens: truncated last line ignored, rc 0" $([ $rc -eq 0 ] && [ "$(echo "$out" | grep '^sonnet ')" = "sonnet 6 170 3300 34" ]; echo $?)
out=$($B tokens "$T/proj/absent.jsonl"); rc=$?
check "tokens: missing file, silent rc 0" $([ -z "$out" ] && [ $rc -eq 0 ]; echo $?)
out=$($B tokens); rc=$?
check "tokens: no path, silent rc 0" $([ -z "$out" ] && [ $rc -eq 0 ]; echo $?)
: > "$T/proj/empty.jsonl"
out=$($B tokens "$T/proj/empty.jsonl")
check "tokens: empty file, silent" $([ -z "$out" ]; echo $?)

# 23. Calibration journal: `count.sh log` (PostToolUse) appends one JSON line per call to
# $COUNT_DIR/calib.log, only for a session with an active count. Never prints anything.
logev() { jq -n --arg s "$1" --arg t "$2" '{session_id: $s, transcript_path: $t, tool_name: "Bash", hook_event_name: "PostToolUse"}' | $B log; }
LOG="$COUNT_DIR/calib.log"
reset; quota 10
out=$(logev nocount "$TR")
check "log: no count, nothing written" $([ -z "$out" ] && [ ! -e "$LOG" ]; echo $?)
prompt s1 "count:20 go" > /dev/null
out=$(logev s1 "$TR")
check "log: silent on stdout" $([ -z "$out" ]; echo $?)
check "log: one line written" $([ "$(wc -l < "$LOG")" = 1 ]; echo $?)
check "log: session, quota and time" $([ "$(jq -r '[.sid, .used, .resets_at, .t] | join(" ")' "$LOG")" = "s1 10 $FUT 1000000" ]; echo $?)
check "log: tokens per model" $([ "$(jq -c '.tokens' "$LOG")" = '{"haiku":[2,0,100,1],"opus":[1,10,500,5],"sonnet":[6,170,3300,34]}' ]; echo $?)
quota 12; logev s1 "$TR"
check "log: second call appends" $([ "$(wc -l < "$LOG")" = 2 ] && [ "$(tail -1 "$LOG" | jq -r .used)" = 12 ]; echo $?)
check "log: purge by age keeps the journal" $(touch -d '3 days ago' "$LOG"; prompt s1 "hello" > /dev/null; [ -e "$LOG" ]; echo $?)
rm -f "$LOG"
logev s1 "$T/proj/absent.jsonl"
check "log: transcript missing, nothing written" $([ ! -e "$LOG" ]; echo $?)
logev s1 ""
check "log: transcript path empty, nothing written" $([ ! -e "$LOG" ]; echo $?)
rm -f "$QUOTA_FILE"; logev s1 "$TR"
check "log: quota unusable, nothing written" $([ ! -e "$LOG" ]; echo $?)
echo 'not json' | $B log; check "log: garbage stdin rc 0" $([ $? -eq 0 ]; echo $?)

# 24. A pasted prompt arrives wrapped in <pasted_content id="..."> (seen in a real session, 2026-10-19):
# the prefix right after the wrapper counts as the start of the prompt
reset; quota 11
out=$(prompt s1 $'\n\n<pasted_content id="e090">\ncount:5 do the task')
check "pasted: count set after the wrapper" $([ "$(state s1 .cap)" = 16 ]; echo $?)
reset; quota 11
prompt s1 $'<pasted_content id="4ade">count:5 go' > /dev/null
check "pasted: wrapper without newline accepted" $([ "$(state s1 .cap)" = 16 ]; echo $?)
out=$(prompt s1 $'\n<pasted_content id="x">\ncount:off')
check "pasted: count:off after the wrapper" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
reset; quota 11
out=$(prompt s1 $'<pasted_content id="e090">\nplease explain count:5 to me')
check "pasted: prefix not right after the wrapper, ignored" $([ -z "$out" ] && [ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
out=$(prompt s1 $'text first <pasted_content id="e090">\ncount:5 go')
check "pasted: wrapper not at the start, ignored" $([ -z "$out" ] && [ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
reset; quota 10; prompt s1 "count:20 go" > /dev/null; quota 28
out=$(prompt s1 $'<pasted_content id="e090">\ncount:finish')
check "pasted: count:finish passes the lock" $([ "$(state s1 .grant)" = true ]; echo $?)

# 25. PostToolUseFailure: a failed tool (no PostToolUse) still advances the thresholds
fail() { jq -n --arg s "$1" '{session_id: $s, tool_name: "Read", hook_event_name: "PostToolUseFailure"}' | $B fail; }
reset; quota 10; prompt s1 "count:20 go" > /dev/null; quota 20
out=$(fail s1)
check "failure: 50 % fires" $(echo "$out" | ctx | grep -q "50 % consommé (10/20"; echo $?)
check "failure: event name" $([ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = PostToolUseFailure ]; echo $?)
out=$(fail s1)
check "failure: once per threshold" $([ -z "$out" ]; echo $?)
out=$(tool s1)
check "failure: shares fired with PostToolUse" $([ -z "$out" ]; echo $?)
reset; quota 10
out=$(fail s9)
check "failure: no count, silent" $([ -z "$out" ]; echo $?)

# 26. Edge cases of the prompt hook (point 6), with a lock and without
reset; quota 10; prompt s1 "count:20 go" > /dev/null; quota 28
out=$(prompt s1 "/clear")
check "/clear at the lock: blocked like any prompt (built-ins may bypass the hook, unverified)" $([ "$(echo "$out" | jq -r .decision)" = block ]; echo $?)
out=$(prompt s1 "/compact")
check "/compact at the lock: blocked like any prompt" $([ "$(echo "$out" | jq -r .decision)" = block ]; echo $?)
reset; quota 10
out=$(prompt s1 "/clear")
check "/clear without count: silent" $([ -z "$out" ] && [ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
prompt s1 "count:20 go" > /dev/null; quota 20; tool s1 > /dev/null
prompt s1 "count:10 again" > /dev/null
check "double set: second replaces the first, fired cleared" $([ "$(state s1 .start)" = 20 ] && [ "$(state s1 .cap)" = 30 ] && [ "$(state s1 '.fired | length')" = 0 ]; echo $?)
reset; quota 10
out=$(prompt s1 "count:0 go")
check "count:0: ignored" $([ -z "$out" ] && [ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
out=$(prompt s1 "count:finish")
check "finish without count: no state left behind" $([ ! -e "$COUNT_DIR/s1.json" ]; echo $?)
prompt s1 "count:20 go" > /dev/null; prompt s1 "count:finish" > /dev/null; prompt s1 "count:15 go" > /dev/null
check "set after finish: grant gone with the fresh state" $([ "$(state s1 '.grant // false')" = false ]; echo $?)

# 27. Context lock: from 150k tokens of context (input + cache write + cache read of the last
# main-thread assistant message), independent of count:. Tools denied, prompts blocked, until "unlock:".
TR="$T/transcript.jsonl"
tr_line() { # tr_line ID SIDECHAIN CONTEXT-TOKENS
  jq -nc --arg id "$1" --argjson sc "$2" --argjson c "$3" \
    '{type: "assistant", isSidechain: $sc, message: {id: $id, model: "sonnet", usage: {input_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: ($c - 1), output_tokens: 5}}}'
}
cpre() { jq -n --arg s "$1" --arg t "$TR" '{session_id: $s, transcript_path: $t, tool_name: "Bash", hook_event_name: "PreToolUse"}' | $B pre; }
cprompt() { jq -n --arg s "$1" --arg p "$2" --arg t "$TR" '{session_id: $s, prompt: $p, transcript_path: $t}' | $B prompt; }
reset; quota 10; : > "$TR"
tr_line m1 false 149999 >> "$TR"
check "ctx: silent below 150k" $([ -z "$(cpre c1)" ]; echo $?)
tr_line m2 false 150000 >> "$TR"
out=$(cpre c1)
check "ctx: deny at 150k, no count needed" $([ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = deny ]; echo $?)
reason=$(echo "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)
check "ctx: reason names unlock:" $(echo "$reason" | grep -q "unlock:"; echo $?)
check "ctx: reason gives the size" $(echo "$reason" | grep -q "150"; echo $?)
tr_line m3 true 400000 >> "$TR"
check "ctx: sidechain lines ignored (last main line still 150k)" $([ -n "$(cpre c1)" ]; echo $?)
out=$(cprompt c1 "hello")
check "ctx: ordinary prompt blocked" $([ "$(echo "$out" | jq -r .decision)" = block ]; echo $?)
check "ctx: block reason names unlock:" $(echo "$out" | jq -r .reason | grep -q "unlock:"; echo $?)
out=$(cprompt c1 "count:5 go")
check "ctx: count: prompts blocked too" $([ "$(echo "$out" | jq -r .decision)" = block ] && [ ! -e "$COUNT_DIR/c1.json" ]; echo $?)
out=$(cprompt c1 "unlock: continue")
check "unlock: passes, says so" $([ -z "$(echo "$out" | jq -r '.decision // empty')" ] && echo "$out" | ctx | grep -q "déverrouillé"; echo $?)
check "unlock: tools allowed" $([ -z "$(cpre c1)" ]; echo $?)
check "unlock: prompts allowed" $([ -z "$(cprompt c1 hello)" ]; echo $?)
check "unlock: message gives the next lock, cleanly" $(echo "$out" | ctx | grep -q "prochain verrou à 180k)"; echo $?)
tr_line m4 false 179999 >> "$TR"
check "unlock: open below the next step" $([ -z "$(cpre c1)" ] && [ -z "$(cprompt c1 hello)" ]; echo $?)
tr_line m4b false 180000 >> "$TR"
check "relock: tools denied at 180k" $([ -n "$(cpre c1)" ]; echo $?)
check "relock: prompt blocked at 180k" $([ "$(cprompt c1 hello | jq -r .decision)" = block ]; echo $?)
out=$(cprompt c1 "unlock:")
check "relock: second unlock names 220k" $(echo "$out" | ctx | grep -q "220k"; echo $?)
check "relock: open again" $([ -z "$(cpre c1)" ]; echo $?)
tr_line m4c false 220000 >> "$TR"
check "relock: denied at 220k" $([ -n "$(cpre c1)" ]; echo $?)
out=$(cprompt c1 "unlock:")
check "last unlock: no further lock announced" $(echo "$out" | ctx | grep -q "prochain verrou aucun)"; echo $?)
tr_line m4d false 900000 >> "$TR"
check "last unlock: open for good" $([ -z "$(cpre c1)" ] && [ -z "$(cprompt c1 hello)" ]; echo $?)
reset; quota 10; : > "$TR"; tr_line m1 false 230000 >> "$TR"; cprompt c5 "unlock:" > /dev/null
tr_line m2 false 900000 >> "$TR"
check "unlock past every step: never locked again" $([ -z "$(cpre c5)" ]; echo $?)
reset; quota 10; : > "$TR"; tr_line m1 false 150000 >> "$TR"; cprompt c1 "unlock:" > /dev/null
check "unlock: other session still locked" $([ -n "$(cpre c2)" ]; echo $?)
out=$(cprompt c2 $'<pasted_content id="e1">\nunlock:')
check "unlock: accepted after the paste wrapper" $(echo "$out" | ctx | grep -q "déverrouillé"; echo $?)
reset; quota 10; : > "$TR"; tr_line m1 false 1000 >> "$TR"
out=$(cprompt c3 "unlock:")
check "unlock without lock: says nothing to unlock, stores nothing" $(echo "$out" | ctx | grep -qi "aucun verrou"; echo $?)
tr_line m2 false 200000 >> "$TR"
check "unlock without lock: lock still fires later" $([ -n "$(cpre c3)" ]; echo $?)
rm -f "$TR"
check "ctx: no transcript, silent" $([ -z "$(cpre c3)" ] && [ -z "$(cprompt c3 hi)" ]; echo $?)
: > "$TR"
check "ctx: empty transcript, silent" $([ -z "$(cpre c3)" ]; echo $?)
echo 'oops' > "$TR"
check "ctx: garbage transcript, silent" $([ -z "$(cpre c3)" ]; echo $?)
tr_line m5 false 160000 >> "$TR"
export COUNT_CTX_LIMIT=200000
check "ctx: limit overridable" $([ -z "$(cpre c3)" ]; echo $?)
unset COUNT_CTX_LIMIT
reset; quota 10; : > "$TR"; tr_line m1 false 160000 >> "$TR"; prompt c4 "count:20 go" > /dev/null
check "ctx: unlocking leaves a count untouched" $(cprompt c4 "unlock:" > /dev/null; [ "$(state c4 .cap)" = 30 ]; echo $?)

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
