#!/usr/bin/env bash
# Per-session budget on the 5h rate-limit window.
#   budget.sh prompt        UserPromptSubmit hook (JSON on stdin)
#   budget.sh tool          PostToolUse hook (JSON on stdin)
#   budget.sh pre           PreToolUse hook: denies every tool from 90 % of the budget, unless granted
#   budget.sh stop          Stop hook: ends a "budget:finish" grant at the end of the turn
#   budget.sh status SID    for the status line: prints "consumed budget pct", or nothing
# State: $BUDGET_DIR/<session_id>.json, written only by that session (atomic tmp + mv).
# Quota: quota.json, written by statusline.sh. Env overrides exist for the tests.

BUDGET_DIR="${BUDGET_DIR:-$HOME/.claude/budget}"
QUOTA="${QUOTA_FILE:-$HOME/.claude/quota.json}"
NOW="${BUDGET_NOW:-$(date +%s)}"
STALE_MIN=1440   # state files untouched for 24 h belong to dead sessions

# Prints "used resets_at" from quota.json; nothing if the file is absent, empty,
# malformed, or its window has already ended (stale: the status line has not rewritten it).
quota() {
  jq -r --argjson now "$NOW" '
    select((.used_percentage | type) == "number" and (.resets_at | type) == "number"
           and .resets_at > $now)
    | "\(.used_percentage) \(.resets_at)"' "$QUOTA" 2>/dev/null
}

# Prints "consumed budget pct cap" for a state file (consumed and budget floored, pct raw),
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

valid_sid() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

prompt_mode() {
  local in sid prompt n q start cap note f tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  prompt=$(jq -r '.prompt // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  # Dead sessions: purge by age. A resumed session keeps its state if it comes back
  # within 24 h (same session_id assumed; unverified), otherwise it is purged here.
  find "$BUDGET_DIR" -name '*.json' -mmin +"$STALE_MIN" -delete 2>/dev/null

  [[ $prompt =~ ^[[:space:]]*budget:(off|finish|[1-9][0-9]*)([[:space:]]|$) ]] || exit 0
  n=${BASH_REMATCH[1]}
  f="$BUDGET_DIR/$sid.json"

  if [ "$n" = finish ]; then
    if [ ! -f "$f" ]; then
      emit UserPromptSubmit "Il n'y a aucun budget actif dans cette session : budget:finish ignoré."
      exit 0
    fi
    tmp="$f.tmp.$$"
    jq '.grant = true' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; exit 0; }
    emit UserPromptSubmit "Autorisation donnée : termine l'étape en cours, puis arrête-toi, résume où tu en es et attends. L'autorisation tombe à la fin de ce tour."
    exit 0
  fi

  if [ "$n" = off ]; then
    rm -f "$f"
    emit UserPromptSubmit "Budget de tâche supprimé pour cette session. Plus aucun rappel de consommation."
    exit 0
  fi

  q=$(quota)
  if [ -z "$q" ]; then
    emit UserPromptSubmit "Budget demandé (${n} %), mais quota.json est absent, vide ou périmé : aucun budget posé. Le préfixe budget:${n} est à renvoyer après la prochaine réponse."
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
    emit UserPromptSubmit "Budget demandé (${n} %), mais la fenêtre 5 h est déjà consommée à 100 % : aucun budget posé."
    exit 0
  fi

  mkdir -p "$BUDGET_DIR"
  tmp="$f.tmp.$$"
  jq -n --argjson s "$start" --argjson c "$cap" --argjson r "$2" --argjson t "$NOW" \
    '{start: $s, cap: $c, resets_at: $r, set_at: $t, fired: []}' > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; exit 0; }

  emit UserPromptSubmit "Budget de tâche : $(jq -n --argjson s "$start" --argjson c "$cap" '$c - $s | floor') % de la fenêtre 5 h (départ à $(jq -n --argjson s "$start" '$s | floor') %), consommé 0, plafond atteint à $(jq -n --argjson c "$cap" '$c | floor') %.${note} Surveille ta consommation. Au plafond, arrête-toi proprement et résume où tu en es. Quand la tâche est terminée, demande à l'utilisateur s'il veut clore le budget (budget:off)."
}

tool_mode() {
  local in sid f m c b pct cap level tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  f="$BUDGET_DIR/$sid.json"
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
    50)  emit PostToolUse "Budget de tâche : 50 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Garde un rythme compatible avec le plafond." ;;
    80)  emit PostToolUse "Budget de tâche : 80 % consommé (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Il reste peu : va à l'essentiel, prépare une conclusion." ;;
    100) emit PostToolUse "Budget de tâche : plafond atteint (${c}/${b} % de la fenêtre 5 h, plafond à ${cap} %). Arrête-toi à la fin de cette étape, ne lance rien de nouveau, résume où tu en es et ce qui reste, puis demande à l'utilisateur : budget:finish (terminer l'étape), budget:N (nouveau plafond) ou budget:off (tâche terminée)." ;;
  esac
}

# Lock: from 90 % of the budget every tool is denied, unless "budget:finish" granted it for
# this turn. Reads the state and quota files only; silent below 90 % and whenever data is missing.
pre_mode() {
  local in sid f m c b pct cap q used reset left at who=""
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  f="$BUDGET_DIR/$sid.json"
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
  emit_deny "Budget de tâche à ${c}/${b} % (plafond ${cap} %), fenêtre 5 h : ${left} % restants jusqu'à ${at}. Outil refusé. Arrête l'étape, résume où tu en es et demande à l'utilisateur de choisir : budget:finish (terminer l'étape en cours), budget:N (nouveau plafond de N %) ou budget:off (tâche terminée).${who}"
}

stop_mode() {
  local in sid f tmp
  in=$(cat)
  sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
  valid_sid "$sid" || exit 0
  f="$BUDGET_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  jq -e '.grant == true' "$f" >/dev/null 2>&1 || exit 0
  tmp="$f.tmp.$$"
  jq 'del(.grant)' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
}

status_mode() {
  local sid=$1 f m
  valid_sid "$sid" || exit 0
  f="$BUDGET_DIR/$sid.json"
  [ -f "$f" ] || exit 0
  m=$(measure "$f"); [ -n "$m" ] || exit 0
  set -- $m
  echo "$1 $2 $3"
}

case "$1" in
  prompt) prompt_mode ;;
  tool)   tool_mode ;;
  pre)    pre_mode ;;
  stop)   stop_mode ;;
  status) status_mode "$2" ;;
  *)      exit 0 ;;
esac
