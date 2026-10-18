#!/usr/bin/env bash
# Per-session count on the 5h rate-limit window.
#   count.sh prompt        UserPromptSubmit hook (JSON on stdin)
#   count.sh tool          PostToolUse hook (JSON on stdin)
#   count.sh pre           PreToolUse hook: denies every tool from 90 % of the count, unless granted
#   count.sh stop          Stop hook: ends a "count:finish" grant at the end of the turn
#   count.sh status SID    for the status line: prints "consumed count pct", or nothing
# State: $COUNT_DIR/<session_id>.json, written only by that session (atomic tmp + mv).
# Quota: quota.json, written by statusline.sh. Env overrides exist for the tests.

COUNT_DIR="${COUNT_DIR:-$HOME/.claude/count}"
QUOTA="${QUOTA_FILE:-$HOME/.claude/quota.json}"
NOW="${COUNT_NOW:-$(date +%s)}"
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

valid_sid() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

prompt_mode() {
  local in sid prompt n q start cap note f tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  prompt=$(jq -r '.prompt // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  # Dead sessions: purge by age. A resumed session keeps its state if it comes back
  # within 24 h (same session_id assumed; unverified), otherwise it is purged here.
  find "$COUNT_DIR" -name '*.json' -mmin +"$STALE_MIN" -delete 2>/dev/null

  # A pasted prompt arrives wrapped in <pasted_content id="...">: the prefix right after it counts.
  if ! [[ $prompt =~ ^[[:space:]]*(\<pasted_content[^\>]*\>[[:space:]]*)?count:(off|finish|[1-9][0-9]*)([[:space:]]|$) ]]; then
    if [ -f "$COUNT_DIR/$sid.json" ] && locked "$COUNT_DIR/$sid.json"; then
      emit_block "Compte de tâche à 90 % ou plus : prompt refusé, aucun coût. Réponds par count:finish (terminer l'étape en cours), count:N (nouveau plafond de N %) ou count:off (tâche terminée)."
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

tool_mode() {
  local in sid f m c b pct cap level tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
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
    50)  emit PostToolUse "Compte de tâche : 50 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Garde un rythme compatible avec le plafond." ;;
    80)  emit PostToolUse "Compte de tâche : 80 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Il reste peu : va à l'essentiel, prépare une conclusion." ;;
    100) emit PostToolUse "Compte de tâche : plafond atteint (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Arrête-toi à la fin de cette étape, ne lance rien de nouveau, résume où tu en es et ce qui reste, puis demande à l'utilisateur : count:finish (terminer l'étape), count:N (nouveau plafond) ou count:off (tâche terminée)." ;;
  esac
}

# Lock: from 90 % of the count every tool is denied, unless "count:finish" granted it for
# this turn. Reads the state and quota files only; silent below 90 % and whenever data is missing.
pre_mode() {
  local in sid f m c b pct cap q used reset left at who=""
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
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

case "$1" in
  log)    log_mode ;;
  tokens) tokens_mode "$2" ;;
  prompt) prompt_mode ;;
  tool)   tool_mode ;;
  pre)    pre_mode ;;
  stop)   stop_mode ;;
  status) status_mode "$2" ;;
  *)      exit 0 ;;
esac
