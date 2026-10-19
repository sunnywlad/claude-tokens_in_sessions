#!/usr/bin/env bash
# Per-session count on the 5h rate-limit window.
#   count.sh prompt        UserPromptSubmit hook (JSON on stdin)
#   count.sh tool          PostToolUse hook (JSON on stdin)
#   count.sh pre           PreToolUse hook: denies every tool from 90 % of the count, unless granted
#   count.sh fail          PostToolUseFailure hook: same thresholds as "tool", for tools that failed
#   count.sh stop          Stop hook: ends a "count:finish" grant at the end of the turn
#   count.sh status SID    for the status line: prints "consumed count pct", or nothing
#   count.sh hermes llm|pre|end   Hermes shell hooks (pre_llm_call, pre_tool_call, on_session_end)
#   count.sh ctx on|off|status   global switch of the context lock and warning (night runs)
#   count.sh quota         Hermes plugin: merges a CLI rate_limit_event (JSON on stdin) into quota.json
# Context lock (independent of count:): from COUNT_CTX_LIMIT tokens of context (default 150000)
# "pre" denies every tool and "prompt" blocks every prompt, until the user types "unlock:".
# The same tool hook warns the session CTX_WARN_MARGIN (15000) tokens before each lock level.
# "unlock:free" removes the context limit for the whole session, lock active or not.
# State: $COUNT_DIR/<session_id>.json, written only by that session (atomic tmp + mv).
# Quota: quota.json, written by statusline.sh. Env overrides exist for the tests.

COUNT_DIR="${COUNT_DIR:-$HOME/.claude/count}"
QUOTA="${QUOTA_FILE:-$HOME/.claude/quota.json}"
NOW="${COUNT_NOW:-$(date +%s)}"
CTX_LIMIT="${COUNT_CTX_LIMIT:-150000}"
CTX_STEPS="${COUNT_CTX_STEPS:-180000 220000}"   # the lock comes back at each, one "unlock:" per step
CTX_WARN_MARGIN="${COUNT_CTX_WARN_MARGIN:-15000}"   # the session is warned this many tokens before a lock
CTX_OFF="$COUNT_DIR/ctx.off"   # present = no context lock and no warning, for every session
STALE_MIN=1440   # state files untouched for 24 h belong to dead sessions

# Prints "used resets_at" from quota.json; nothing if the file is absent, empty,
# malformed, or its window has already ended (stale: the status line has not rewritten it).
quota() {
  jq -r --argjson now "$NOW" '
    select((.used_percentage | type) == "number" and (.resets_at | type) == "number"
           and .resets_at > $now)
    | "\(.used_percentage) \(.resets_at)"' "$QUOTA" 2>/dev/null
}

# Prints "consumed count pct cap" for a state file (consumed and count floored, pct raw),
# or nothing when the quota is unusable.
# Consumption: same window (resets_at within 60 s of the stored one, to absorb jitter)
#   = used_now - start.
# Window reset during the task: the rest of the first window (100 - start) counts as
#   spent in full, and the second window adds used_now:
#   consumed = (100 - start) + used_now. Assumes at most one reset.
measure() {
  local f=$1 q
  q=$(quota); [ -n "$q" ] || return 1
  set -- $q
  jq -r --argjson u "$1" --argjson r "$2" '
    (if ((.resets_at - $r) | fabs) < 60 then $u - .start else (100 - .start) + $u end) as $c
    | ([$c, 0] | max) as $c
    | (.cap - .start) as $b
    | "\($c | floor) \($b | floor) \($c / $b * 100) \(.cap | floor)"' "$f" 2>/dev/null
}

emit() { # emit EVENT MESSAGE
  jq -n --arg ev "$1" --arg c "$2" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $c}}'
}

emit_deny() { # emit_deny REASON
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

emit_block() { # emit_block REASON
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
}

# True when the session's count is at 90 % or more and no "finish" grant is active.
locked() { # locked STATE_FILE
  local m
  jq -e '.grant == true' "$1" >/dev/null 2>&1 && return 1
  m=$(measure "$1"); [ -n "$m" ] || return 1
  set -- $m
  [ "$(jq -n --argjson p "$3" '$p >= 90')" = true ]
}

# Context size of a session: input + cache write + cache read of the last main-thread assistant
# message of the transcript (sidechains are sub-agents). Prints nothing when unreadable.
ctx_tokens() { # ctx_tokens TRANSCRIPT
  [ -f "$1" ] || return 1
  jq -rnR '[inputs | fromjson? | select(.type == "assistant" and (.isSidechain | not) and .message.usage != null)]
    | last | .message.usage
    | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' "$1" 2>/dev/null
}

# True (and sets CTX_TOKENS, CTX_AT) when the context has reached the session's current lock level:
# CTX_LIMIT at first, then the step stored by the last "unlock:" (none left = never locked again).
ctx_locked() { # ctx_locked SID TRANSCRIPT
  local at=$CTX_LIMIT f="$COUNT_DIR/$1.ctx.json"
  [ -e "$CTX_OFF" ] && return 1
  [ -f "$f" ] && { at=$(jq -r '.next // empty' "$f" 2>/dev/null); [ -n "$at" ] || return 1; }
  CTX_TOKENS=$(ctx_tokens "$2"); [ -n "$CTX_TOKENS" ] || return 1
  CTX_AT=$at
  [ "$CTX_TOKENS" -ge "$at" ]
}

# Tells the running session, once per lock level, that the lock is CTX_WARN_MARGIN tokens away
# (PostToolUse, no count needed). Prints the hook output and returns 0 only when it fires.
ctx_warn() { # ctx_warn SID TRANSCRIPT EVENT
  local at=$CTX_LIMIT f="$COUNT_DIR/$1.ctx.json" w="$COUNT_DIR/$1.warn.json" tokens tmp
  [ -e "$CTX_OFF" ] && return 1
  [ -f "$f" ] && { at=$(jq -r '.next // empty' "$f" 2>/dev/null); [ -n "$at" ] || return 1; }
  tokens=$(ctx_tokens "$2"); [ -n "$tokens" ] || return 1
  [ "$tokens" -lt "$at" ] && [ "$tokens" -ge $((at - CTX_WARN_MARGIN)) ] || return 1
  [ "$(jq -r '.at // empty' "$w" 2>/dev/null)" = "$at" ] && return 1
  mkdir -p "$COUNT_DIR"
  tmp="$w.tmp.$$"
  jq -n --argjson a "$at" '{at: $a}' > "$tmp" && mv "$tmp" "$w" || { rm -f "$tmp"; return 1; }
  emit "$3" "Contexte de la session à $((tokens / 1000))k tokens, verrou à $((at / 1000))k : bientôt la limite. Prépare-toi à finir la tâche en cours, à enregistrer l'essentiel en mémoire, puis à être clear (l'utilisateur lancera /clear). Ne démarre rien de nouveau."
}

# First step strictly above the given token count; nothing when none is left.
ctx_next() { # ctx_next TOKENS
  local x
  for x in $CTX_STEPS; do [ "$x" -gt "$1" ] && { echo "$x"; return; }; done
}

ctx_reason() { # ctx_reason TOKENS
  echo "Contexte de la session à $(($1 / 1000))k tokens (seuil $((CTX_AT / 1000))k) : verrouillée. Tape unlock: en début de prompt pour continuer ici, ou /clear (ou /compact) pour repartir léger."
}

valid_sid() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

prompt_mode() {
  local in sid prompt n q start cap note f tmp tr nxt
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  prompt=$(jq -r '.prompt // empty' <<<"$in" 2>/dev/null)
  tr=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  # Dead sessions: purge by age. A resumed session keeps its state if it comes back
  # within 24 h (same session_id assumed; unverified), otherwise it is purged here.
  find "$COUNT_DIR" -name '*.json' -mmin +"$STALE_MIN" -delete 2>/dev/null

  # "unlock:free": no context limit for the rest of the session, even before any lock.
  if [[ $prompt =~ ^[[:space:]]*(\<pasted_content[^\>]*\>[[:space:]]*)?unlock:free([[:space:]]|$) ]]; then
    mkdir -p "$COUNT_DIR"
    tmp="$COUNT_DIR/$sid.ctx.json.tmp.$$"
    jq -n --argjson t "$NOW" '{unlocked_at: $t, free: true, next: null}' > "$tmp" && mv "$tmp" "$COUNT_DIR/$sid.ctx.json" || rm -f "$tmp"
    emit UserPromptSubmit "Verrou de contexte désactivé par l'utilisateur pour toute la session (unlock:free) : aucune limite de contexte. Continue la tâche ; garde en tête que chaque appel coûte cher quand le contexte grossit."
    exit 0
  fi

  # Context lock: "unlock:" lifts it for the rest of the session; anything else is blocked.
  if [[ $prompt =~ ^[[:space:]]*(\<pasted_content[^\>]*\>[[:space:]]*)?unlock:([[:space:]]|$) ]]; then
    if ctx_locked "$sid" "$tr"; then
      mkdir -p "$COUNT_DIR"
      tmp="$COUNT_DIR/$sid.ctx.json.tmp.$$"
      nxt=$(ctx_next "$CTX_TOKENS")
      jq -n --argjson t "$NOW" --argjson k "$CTX_TOKENS" --arg n "$nxt" \
        '{unlocked_at: $t, tokens: $k, next: (if $n == "" then null else ($n | tonumber) end)}' > "$tmp" && mv "$tmp" "$COUNT_DIR/$sid.ctx.json" || rm -f "$tmp"
      emit UserPromptSubmit "Verrou de contexte déverrouillé par l'utilisateur (contexte à $((CTX_TOKENS / 1000))k tokens, prochain verrou $([ -n "$nxt" ] && echo "à $((nxt / 1000))k" || echo aucun)). Continue la tâche ; garde en tête que chaque appel coûte cher à cette taille."
    else
      emit UserPromptSubmit "Aucun verrou de contexte actif dans cette session : unlock: ignoré."
    fi
    exit 0
  fi
  # A sub-agent report arrives as a prompt (<agent-message from=...> seen in real, <task-notification> assumed): it passes both locks (count and context).
  [[ $prompt =~ ^[[:space:]]*\<(task-notification|agent-message)[[:space:]\>] ]] && exit 0
  if ctx_locked "$sid" "$tr"; then
    emit_block "$(ctx_reason "$CTX_TOKENS")"
    exit 0
  fi

  # A pasted prompt arrives wrapped in <pasted_content id="...">: the prefix right after it counts.
  if ! [[ $prompt =~ ^[[:space:]]*(\<pasted_content[^\>]*\>[[:space:]]*)?count:(off|finish|[1-9][0-9]*)([[:space:]]|$) ]]; then
    if [ -f "$COUNT_DIR/$sid.json" ] && locked "$COUNT_DIR/$sid.json"; then
      emit_block "Compte de tâche à 90 % ou plus : prompt refusé, aucun coût. Réponds par count:finish (terminer l'étape en cours), count:N (nouveau plafond de N %) ou count:off (tâche terminée)."
    else
      ctx_warn "$sid" "$tr" UserPromptSubmit
    fi
    exit 0
  fi
  n=${BASH_REMATCH[2]}
  f="$COUNT_DIR/$sid.json"

  if [ "$n" = finish ]; then
    if [ ! -f "$f" ]; then
      emit UserPromptSubmit "Il n'y a aucun compte actif dans cette session : count:finish ignoré."
      exit 0
    fi
    tmp="$f.tmp.$$"
    jq '.grant = true' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; exit 0; }
    emit UserPromptSubmit "Autorisation donnée : termine l'étape en cours, puis arrête-toi, résume où tu en es et attends. L'autorisation tombe à la fin de ce tour."
    exit 0
  fi

  if [ "$n" = off ]; then
    rm -f "$f"
    emit UserPromptSubmit "Compte de tâche supprimé pour cette session. Plus aucun rappel de consommation."
    exit 0
  fi

  q=$(quota)
  if [ -z "$q" ]; then
    emit UserPromptSubmit "Compte demandé (${n} %), mais quota.json est absent, vide ou périmé : aucun compte posé. Le préfixe count:${n} est à renvoyer après la prochaine réponse."
    exit 0
  fi
  set -- $q
  start=$1
  cap=$(jq -n --argjson s "$start" --argjson n "$n" '[$s + $n, 100] | min')
  note=""
  if [ "$(jq -n --argjson s "$start" --argjson n "$n" '($s + $n) > 100')" = true ]; then
    note=" Plafond demandé au-delà de 100 : ramené à 100."
  fi
  if [ "$(jq -n --argjson s "$start" --argjson c "$cap" '$c - $s > 0')" != true ]; then
    emit UserPromptSubmit "Compte demandé (${n} %), mais la fenêtre 5 h est déjà consommée à 100 % : aucun compte posé."
    exit 0
  fi

  mkdir -p "$COUNT_DIR"
  tmp="$f.tmp.$$"
  jq -n --argjson s "$start" --argjson c "$cap" --argjson r "$2" --argjson t "$NOW" \
    '{start: $s, cap: $c, resets_at: $r, set_at: $t, fired: []}' > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; exit 0; }

  emit UserPromptSubmit "Compte de tâche : $(jq -n --argjson s "$start" --argjson c "$cap" '$c - $s | floor') % de la fenêtre 5 h (départ à $(jq -n --argjson s "$start" '$s | floor') %), consommé 0, plafond atteint à $(jq -n --argjson c "$cap" '$c | floor') %.${note} Surveille ta consommation. Au plafond, arrête-toi proprement et résume où tu en es. Quand la tâche est terminée, demande à l'utilisateur s'il veut clore le compte (count:off)."
}

tool_mode() { # tool_mode [EVENT]: PostToolUse by default, PostToolUseFailure for "fail"
  local ev=${1:-PostToolUse} in sid f m c b pct cap level tmp tr
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  tr=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  ctx_warn "$sid" "$tr" "$ev" && exit 0
  f="$COUNT_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  m=$(measure "$f"); [ -n "$m" ] || exit 0
  set -- $m; c=$1; b=$2; pct=$3; cap=$4

  # Highest threshold crossed and not yet fired; all crossed thresholds get marked.
  level=$(jq -r --argjson p "$pct" '
    .fired as $done | [50, 80, 100] | map(select(. <= $p and (. as $t | $done | index($t) | not))) | max // empty' "$f" 2>/dev/null)
  [ -n "$level" ] || exit 0

  tmp="$f.tmp.$$"
  jq --argjson p "$pct" '.fired = ([50, 80, 100] | map(select(. <= $p)))' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; exit 0; }

  case "$level" in
    50)  emit "$ev" "Compte de tâche : 50 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Garde un rythme compatible avec le plafond." ;;
    80)  emit "$ev" "Compte de tâche : 80 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Il reste peu : va à l'essentiel, prépare une conclusion." ;;
    100) emit "$ev" "Compte de tâche : plafond atteint (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Arrête-toi à la fin de cette étape, ne lance rien de nouveau, résume où tu en es et ce qui reste, puis demande à l'utilisateur : count:finish (terminer l'étape), count:N (nouveau plafond) ou count:off (tâche terminée)." ;;
  esac
}

# Lock: from 90 % of the count every tool is denied, unless "count:finish" granted it for
# this turn. Reads the state and quota files only; silent below 90 % and whenever data is missing.
pre_mode() {
  local in sid f m c b pct cap q used reset left at who="" tr
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  tr=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  # SubagentHandback is how a locked sub-agent delivers its report: never deny it.
  [ "$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)" = SubagentHandback ] && exit 0
  if ctx_locked "$sid" "$tr"; then
    [ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && who=" Tu es un sous-agent : rends la main à l'orchestrateur avec ce constat."
    emit_deny "$(ctx_reason "$CTX_TOKENS") Outil refusé. Arrête l'étape, résume où tu en es et demande à l'utilisateur.${who}"
    exit 0
  fi
  f="$COUNT_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  jq -e '.grant == true' "$f" >/dev/null 2>&1 && exit 0
  m=$(measure "$f"); [ -n "$m" ] || exit 0
  set -- $m; c=$1; b=$2; pct=$3; cap=$4
  [ "$(jq -n --argjson p "$pct" '$p >= 90')" = true ] || exit 0

  q=$(quota)
  set -- $q; used=$1; reset=$2
  left=$(jq -n --argjson u "$used" '100 - $u | floor')
  at=$(date -d "@$reset" +%H:%M 2>/dev/null)
  [ -n "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] && who=" Tu es un sous-agent : rends la main à l'orchestrateur avec ce constat, il demandera à l'utilisateur."
  emit_deny "Compte de tâche à ${c}/${b} % (plafond ${cap} %), fenêtre 5 h : ${left} % restants jusqu'à ${at}. Outil refusé. Arrête l'étape, résume où tu en es et demande à l'utilisateur de choisir : count:finish (terminer l'étape en cours), count:N (nouveau plafond de N %) ou count:off (tâche terminée).${who}"
}

stop_mode() {
  local in sid f tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  f="$COUNT_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  jq -e '.grant == true' "$f" >/dev/null 2>&1 || exit 0
  tmp="$f.tmp.$$"
  jq 'del(.grant)' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

status_mode() {
  local sid=$1 f m
  valid_sid "$sid" || exit 0
  f="$COUNT_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  m=$(measure "$f"); [ -n "$m" ] || exit 0
  set -- $m
  echo "$1 $2 $3"
}

# Prints "model input cache_write cache_read output" per model for a transcript and its
# sub-agent files (<transcript minus .jsonl>/subagents/*.jsonl). One API message spans several
# transcript lines with the same message.id, so it is deduplicated across all files.
# Lines that do not parse (a half-written last line) are skipped. Silent on a missing file.
tokens_mode() {
  local tr=$1 f
  [ -f "$tr" ] || exit 0
  for f in "$tr" "${tr%.jsonl}"/subagents/*.jsonl; do
    [ -f "$f" ] && { cat "$f"; echo; }   # echo: a truncated last line must not glue to the next file
  done | jq -rnR '
    [inputs | fromjson? | select(.type == "assistant" and .message.usage != null) | .message]
    | unique_by(.id) | group_by(.model)[]
    | "\(.[0].model) \(map(.usage.input_tokens // 0) | add) \(map(.usage.cache_creation_input_tokens // 0) | add) \(map(.usage.cache_read_input_tokens // 0) | add) \(map(.usage.output_tokens // 0) | add)"' 2>/dev/null
}

# Calibration journal (PostToolUse): one JSON line per call in $COUNT_DIR/calib.log, pairing the
# global used_percentage with the session's transcript tokens per model. Only for a session with
# an active count; nothing is written when the quota or the transcript is unusable. Prints nothing.
log_mode() {
  local in sid tr q tok
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  tr=$(jq -r '.transcript_path // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  [ -f "$COUNT_DIR/$sid.json" ] && [ -f "$tr" ] || exit 0
  q=$(quota); [ -n "$q" ] || exit 0
  set -- $q
  tok=$(tokens_mode "$tr" | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1:] | map(tonumber))}] | add // {}')
  [ -n "$tok" ] || exit 0
  jq -nc --argjson t "$NOW" --arg s "$sid" --argjson u "$1" --argjson r "$2" --argjson k "$tok" \
    '{t: $t, sid: $s, used: $u, resets_at: $r, tokens: $k}' >> "$COUNT_DIR/calib.log"
}

# Merges the CLI's rate_limit_event into quota.json with the status line's rules: in the same
# window (resets_at within 60 s) a lower value loses, an older window loses, a newer one replaces.
# utilization is a fraction (0.26 = 26 %), stored as the integer percent the status line writes.
# Unusable input or a failed write leaves the file as it was. Prints nothing.
quota_mode() {
  local old out tmp
  old=$(jq -c 'select(type == "object")' "$QUOTA" 2>/dev/null); [ -n "$old" ] || old='{}'
  tmp="$QUOTA.tmp.$$"
  out=$(jq --argjson old "$old" '
    def pct: select(type == "number") | (. * 100 + 0.000001 | floor);
    (.rate_limit_info.unifiedWindows // {}) as $w
    | (($w.five_hour.utilization | pct) // null) as $u | $w.five_hour.resetsAt as $r
    | (($w.seven_day.utilization | pct) // null) as $su | $w.seven_day.resetsAt as $sr
    | $old.resets_at as $or | $old.used_percentage as $ou
    | (if $u != null and ($r | type) == "number"
         then (if ($or | type) == "number" and ($ou | type) == "number"
                  and ($r < $or - 60 or ((($r - $or) | fabs) < 60 and $u < $ou))
               then {} else {used_percentage: $u, resets_at: $r} end)
         else {} end) as $five
    | ({seven_day_used_percentage: $su, seven_day_resets_at: $sr} | with_entries(select(.value != null))) as $seven
    | if ($five | length) == 0 and ($seven | length) == 0 then empty else $old + $five + $seven end
  ' 2>/dev/null)
  [ -n "$out" ] || exit 0
  echo "$out" > "$tmp" && mv "$tmp" "$QUOTA" || rm -f "$tmp"
}

# Hermes shell hooks speak another wire format: {session_id, tool_name, extra: {user_message}} in,
# {context} / {decision: block, reason} out. This adapts them to the modes above. Hermes cannot refuse
# a prompt (pre_llm_call only injects) and has no mid-turn injection, so at a lock the model is told
# to relay the lock, and the threshold reminders arrive at the start of the next turn.
hermes_mode() { # hermes_mode llm|pre|end
  local in sid out
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  case "$1" in
    llm)
      out=$(jq -c '{session_id, prompt: (.extra.user_message // "")}' <<<"$in" | prompt_mode)
      if [ -z "$out" ]; then
        out=$(jq -nc --arg s "$sid" '{session_id: $s}' | tool_mode)
      fi
      [ -n "$out" ] || exit 0
      jq -c 'if .decision == "block" then {context: ("Verrou du compte : ne lance aucun outil, transmets ce message à l\u0027utilisateur : " + .reason)}
             elif .hookSpecificOutput.additionalContext then {context: .hookSpecificOutput.additionalContext} else empty end' <<<"$out" ;;
    pre)
      out=$(jq -c '{session_id, tool_name}' <<<"$in" | pre_mode)
      [ -n "$out" ] || exit 0
      jq -c '{decision: "block", reason: .hookSpecificOutput.permissionDecisionReason}' <<<"$out" ;;
    end)
      jq -c '{session_id}' <<<"$in" | stop_mode ;;
  esac
}

# Global switch for the context lock and its warning: "ctx off" before a night run, "ctx on" after.
ctx_switch() { # ctx_switch on|off|status
  case "$1" in
    off) mkdir -p "$COUNT_DIR" && : > "$CTX_OFF"; echo "Verrou de contexte désactivé pour toutes les sessions (count.sh ctx on pour le rétablir)." ;;
    on)  rm -f "$CTX_OFF"; echo "Verrou de contexte activé pour toutes les sessions." ;;
    status) [ -e "$CTX_OFF" ] && echo off || echo on ;;
    *)   echo "usage : count.sh ctx on|off|status" >&2; return 1 ;;
  esac
}

case "$1" in
  ctx)    ctx_switch "$2" ;;
  hermes) hermes_mode "$2" ;;
  quota)  quota_mode ;;
  log)    log_mode ;;
  tokens) tokens_mode "$2" ;;
  prompt) prompt_mode ;;
  tool)   tool_mode ;;
  fail)   tool_mode PostToolUseFailure ;;
  pre)    pre_mode ;;
  stop)   stop_mode ;;
  status) status_mode "$2" ;;
  *)      exit 0 ;;
esac
