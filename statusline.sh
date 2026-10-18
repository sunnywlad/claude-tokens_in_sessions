#!/usr/bin/env bash
# Status line: name | ctx 87k/1M | 5h NN% (used)
input=$(cat)

ctx=$(echo "$input" | jq -r '(.context_window.current_usage // {}) | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))')
size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
sid=$(echo "$input" | jq -r '.session_id // empty')
name=$(jq -rs --arg sid "$sid" '.[] | select(.sessionId==$sid) | .name' ~/.claude/sessions/*.json 2>/dev/null | head -n1)
[ -z "$name" ] && name=$(echo "$input" | jq -r '.session_name // empty')
now=$(date +%s)
used5=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')

G='\033[32m'; Y='\033[33m'; R='\033[31m'; O='\033[38;5;208m'; N='\033[0m'

case "$ctx" in ''|*[!0-9]*) ctx=0 ;; esac
case "$size" in ''|*[!0-9]*) size=0 ;; esac

if [ "$ctx" -lt 150000 ]; then cc=$G; elif [ "$ctx" -le 200000 ]; then cc=$O; else cc=$R; fi

ctxk="$((ctx / 1000))k"
if [ "$size" -ge 1000000 ]; then sizes="$((size / 1000000))M"; else sizes="$((size / 1000))k"; fi

if [ -n "$name" ]; then
  { printf "\033]0;%s\007" "$name" > /dev/tty; } 2>/dev/null
fi

if [ -n "$used5" ]; then
  left=$(echo "$used5" | jq -R 'tonumber | 100 - . | floor')
  if [ "$left" -gt 40 ]; then lc=$G; elif [ "$left" -ge 15 ]; then lc=$Y; else lc=$R; fi
  reset_txt=""
  reset5=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty | floor' 2>/dev/null)
  case "$reset5" in
    ''|*[!0-9]*) ;;
    *)
      diff=$((reset5 - now))
      if [ "$diff" -le 0 ]; then
        reset_txt=" | reset now"
      else
        reset_txt=" | reset $(date -d "@$reset5" +%H:%M)"
      fi
      ;;
  esac
  five=$(printf "${lc}5h %s%%%s${N}" "$(echo "$used5" | jq -R 'tonumber | floor')" "$reset_txt")
else
  five="5h --"
fi

# 7-day pace: "U A code" (code 0 green, 1 orange, 2 red), empty if absent
pace=$(echo "$input" | jq -r --argjson now "$now" '
  .rate_limits.seven_day
  | select(. != null and .used_percentage != null and .resets_at != null)
  | .used_percentage as $u
  | ((1 - (.resets_at - $now) / 604800) | if . < 0 then 0 elif . > 1 then 1 else . end) * 100 as $a
  | "\($u | floor) \($a | floor) \(if $u <= $a then 0 elif ($u - $a) <= 10 then 1 else 2 end)"
' 2>/dev/null)
if [ -n "$pace" ]; then
  set -- $pace
  case "$3" in 0) pc=$G ;; 1) pc=$O ;; *) pc=$R ;; esac
  seven=$(printf "${pc}7d %s%% / %s%%${N}" "$1" "$2")
else
  seven="7d --"
fi

# Persist raw quota for the hook (atomic overwrite, merge so absent fields keep old values)
if [ -n "$used5" ] || [ -n "$pace" ]; then
  out="$HOME/.claude/quota.json"
  tmp="$out.tmp.$$"
  old=$(cat "$out" 2>/dev/null)
  [ -z "$old" ] && old='{}'
  if echo "$input" | jq --argjson old "$old" '
      $old + ({
        used_percentage: .rate_limits.five_hour.used_percentage,
        resets_at: .rate_limits.five_hour.resets_at,
        seven_day_used_percentage: .rate_limits.seven_day.used_percentage,
        seven_day_resets_at: .rate_limits.seven_day.resets_at
      } | with_entries(select(.value != null)))
    ' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$out"
  else
    rm -f "$tmp"
  fi
fi

# Task budget segment: green < 80 % of the budget, orange 80-100 %, red beyond; absent without a budget
task=""
if [ -n "$sid" ]; then
  tb=$(bash "${BUDGET_SH:-$HOME/.claude/budget.sh}" status "$sid" 2>/dev/null)
  if [ -n "$tb" ]; then
    set -- $tb
    tc=$(echo "$3" | jq -R 'tonumber | if . < 80 then 0 elif . <= 100 then 1 else 2 end')
    case "$tc" in 0) tcc=$G ;; 1) tcc=$O ;; *) tcc=$R ;; esac
    task=$(printf " | ${tcc}task %s/%s${N}" "$1" "$2")
  fi
fi

printf "%s | ${cc}ctx %s/%s${N} | %b | %b%b\n" "${name:-claude}" "$ctxk" "$sizes" "$five" "$seven" "$task"
