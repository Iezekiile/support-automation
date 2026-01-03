#!/usr/bin/env bash
#
# ip-block-check.sh — аналіз блокувань IP в CSF, ModSecurity, CrowdSec, cPHulk
# Зверніть увагу: LFD перевіряємо ТІЛЬКИ коли CSF показує TEMP або DENY.
#
# Виклик: ./ip-block-check.sh [IP]
#

set -uo pipefail

LFD_LOG="/var/log/lfd.log"
MODSEC_LOG="/usr/local/apache/logs/modsec_audit.log"
CPHULK_LOG="/usr/local/cpanel/logs/cphulkd.log"

IP="${1-}"

if [[ -z "$IP" ]]; then
  read -rp "Enter IP address: " IP
fi

# Trim leading/trailing whitespace (захист від лишніх пробілів при вводі)
# Works in pure bash without calling external tools.
IP="${IP#"${IP%%[![:space:]]*}"}"   # remove leading whitespace
IP="${IP%"${IP##*[![:space:]]}"}"   # remove trailing whitespace

if [[ -z "$IP" ]]; then
  echo "No IP provided. Exiting."
  exit 1
fi

# Helpers
sep() { printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='; }
print_title() {
  sep
  printf "%s\n" "$1"
  sep
}

# safe grep for plain string with optional zgrep for rotated logs
plain_grep_file() {
  # usage: plain_grep_file <pattern> <file>
  local pattern="$1" file="$2"
  if [[ ! -f "$file" && -z $(ls "${file}"* 2>/dev/null) ]]; then
    return 1
  fi
  local out=""
  out=$(grep -F -- "$pattern" "$file" 2>/dev/null || true)
  if command -v zgrep >/dev/null 2>&1; then
    out="$out"$'\n'$(zgrep -F -- "$pattern" "${file}"* 2>/dev/null || true)
  fi
  # trim leading/trailing whitespace to check emptiness outside
  printf '%s\n' "$out"
  return 0
}

# Analysis variables
csf_status="unknown"        # missing | no_block | blocked_temp | blocked_deny | allow | blocked_other
csf_output=""

lfd_matches=""              # populated only if CSF shows TEMP or DENY and LFD log exists

modsec_status="unknown"     # log_missing | no_entries | entries_found
modsec_matches=""

crowd_status="unknown"      # missing | no_block | blocked
crowd_decision=""
crowd_alert_id=""

cphulk_status="unknown"     # log_missing | no_entries | entries_found
cphulk_matches=""

# --- Analysis phase ---

# CSF
if ! command -v csf >/dev/null 2>&1; then
  csf_status="missing"
else
  # Capture output but do not overwrite it on non-zero exit.
  csf_output="$(csf -g "$IP" 2>/dev/null)" || true
  if [[ -z "$csf_output" ]] || echo "$csf_output" | grep -qi "No matches found"; then
    csf_status="no_block"
  else
    # detect specific types
    if echo "$csf_output" | grep -qi "TEMP"; then
      csf_status="blocked_temp"
    elif echo "$csf_output" | grep -qi "DENY"; then
      csf_status="blocked_deny"
    elif echo "$csf_output" | grep -qi "ALLOW"; then
      csf_status="allow"
    else
      csf_status="blocked_other"
    fi
  fi
fi

# If CSF indicates a DENY or TEMP, then check LFD logs (they're related)
if [[ "$csf_status" == "blocked_temp" || "$csf_status" == "blocked_deny" ]]; then
  if [[ -f "$LFD_LOG" ]] || [[ -n $(ls "${LFD_LOG}"* 2>/dev/null) ]]; then
    lfd_matches="$(plain_grep_file "$IP" "$LFD_LOG" || true)"
    # remove lines with only whitespace for emptiness test later
    if [[ -z "${lfd_matches//[$'\n'[:space:]]/}" ]]; then
      lfd_matches=""
    fi
  else
    lfd_matches=""
  fi
fi

# ModSecurity
if [[ ! -f "$MODSEC_LOG" && -z $(ls "${MODSEC_LOG}"* 2>/dev/null) ]]; then
  modsec_status="log_missing"
else
  modsec_matches="$(plain_grep_file "$IP" "$MODSEC_LOG" || true)"
  if [[ -z "${modsec_matches//[$'\n'[:space:]]/}" ]]; then
    modsec_status="no_entries"
  else
    modsec_status="entries_found"
  fi
fi

# CrowdSec
if ! command -v cscli >/dev/null 2>&1; then
  crowd_status="missing"
else
  # safe: ensure pipeline failure doesn't empty variable (use || true inside substitution)
  crowd_decision="$(cscli decisions list --all 2>/dev/null | grep -F -- "$IP" || true)"
  if [[ -n "${crowd_decision//[$'\n'[:space:]]/}" ]]; then
    crowd_status="blocked"
    # extract alert id: cscli table is '|' separated and alert id is the last non-empty column
    crowd_alert_id=$(printf '%s\n' "$crowd_decision" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$NF); print $NF}' | head -n1 || true)
  else
    crowd_status="no_block"
  fi
fi

# cPHulk
if [[ ! -f "$CPHULK_LOG" && -z $(ls "${CPHULK_LOG}"* 2>/dev/null) ]]; then
  cphulk_status="log_missing"
else
  cphulk_matches="$(plain_grep_file "$IP" "$CPHULK_LOG" || true)"
  if [[ -z "${cphulk_matches//[$'\n'[:space:]]/}" ]]; then
    cphulk_status="no_entries"
  else
    cphulk_status="entries_found"
  fi
fi

# --- Summary output (column) ---
print_title "Summary — короткий огляд"
status_line() {
  local name="$1" status="$2"
  case "$status" in
    missing)        printf "%-10s : %s\n" "$name" "команда не знайдена";;
    log_missing)    printf "%-10s : %s\n" "$name" "лог не знайдено";;
    no_block|no_entries) printf "%-10s : %s\n" "$name" "нема блокування";;
    blocked|blocked_temp|blocked_deny|blocked_other) printf "%-10s : %s\n" "$name" "Є блокування";;
    allow)          pr
