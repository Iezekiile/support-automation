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
    crowd_alert_id=$(printf '%s\n' "$crowd_decision" | awk '{print $1}' | head -n1 || true)
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
    blocked_temp|blocked_deny|blocked_other) printf "%-10s : %s\n" "$name" "Є блокування";;
    allow)          printf "%-10s : %s\n" "$name" "ALLOW запис";;
    *)              printf "%-10s : %s\n" "$name" "невідомо";;
  esac
}

status_line "CSF"    "$csf_status"
status_line "ModSec" "$modsec_status"
status_line "CrowdS" "$crowd_status"
status_line "cPHulk" "$cphulk_status"

# --- Detailed sections for systems with blocks ---
echo
print_title "Деталі та рекомендації (лише для систем з блокуванням)"

# CSF details (if blocked or ALLOW)
if [[ "$csf_status" == "blocked_temp" || "$csf_status" == "blocked_deny" || "$csf_status" == "blocked_other" || "$csf_status" == "allow" ]]; then
  echo "== CSF =="
  if [[ -n "$csf_output" ]]; then
    echo "CSF records:"
    printf '%s\n' "$csf_output"
  else
    echo "CSF: немає виводу"
  fi
  echo
  echo "Рекомендовані дії:"
  if [[ "$csf_status" == "blocked_temp" ]]; then
    echo "- Тимчасове блокування: csf -tr $IP"
  fi
  if [[ "$csf_status" == "blocked_deny" ]]; then
    echo "- Перманентний DENY: csf -dr $IP"
  fi
  if [[ "$csf_status" == "allow" ]]; then
    echo "- ALLOW запис: csf -ar $IP"
  fi
  if [[ "$csf_status" == "blocked_other" ]]; then
    echo "- Інший запис у CSF (перегляньте вивід вище)"
  fi

  # Show LFD matches only when CSF had TEMP/DENY
  if [[ "$csf_status" == "blocked_temp" || "$csf_status" == "blocked_deny" ]]; then
    echo
    echo "== LFD (перевірка пов'язана з CSF) =="
    if [[ -n "$lfd_matches" ]]; then
      printf '%s\n' "$lfd_matches"
      echo
      echo "Рекомендовані дії:"
      echo "- Перевірити записи LFD у $LFD_LOG та очистити/відкоригувати за потреби (залежить від конфігурації)."
    else
      # differentiate missing log vs no matches
      if [[ ! -f "$LFD_LOG" && -z $(ls "${LFD_LOG}"* 2>/dev/null) ]]; then
        echo "LFD лог не знайдено: $LFD_LOG"
      else
        echo "LFD: відповідних записів не знайдено"
      fi
    fi
  fi
fi

# ModSecurity details
if [[ "$modsec_status" == "entries_found" ]]; then
  echo
  echo "== ModSecurity =="
  echo "Log entries:"
  printf '%s\n' "$modsec_matches"
  echo
  echo "Рекомендовані дії:"
  echo "- Перевірити whitelist (наприклад): /etc/apache2/conf.d/modsec/modsec2.wordpress.conf"
  echo "- Перевірити конфіг Apache: httpd -t"
  echo "- Reload Apache: systemctl reload httpd"
  echo "- Для LiteSpeed: /usr/local/lsws/bin/lswsctrl restart"
fi

# CrowdSec details
if [[ "$crowd_status" == "blocked" ]]; then
  echo
  echo "== CrowdSec =="
  echo "Decision(s):"
  printf '%s\n' "$crowd_decision"
  if [[ -n "$crowd_alert_id" ]]; then
    echo
    echo "Alert details (cscli alerts inspect):"
    cscli alerts inspect -d "$crowd_alert_id" 2>/dev/null || true
  fi
  echo
  echo "Рекомендовані дії:"
  echo "- Unblock: cscli decisions delete -i $IP"
  echo "- Add to allowlist: cscli allowlists add clients $IP"
fi

# cPHulk details
if [[ "$cphulk_status" == "entries_found" ]]; then
  echo
  echo "== cPHulk =="
  echo "Log entries:"
  printf '%s\n' "$cphulk_matches"
  echo
  echo "Рекомендовані дії:"
  echo "- Unblock (cPanel): /scripts/hulk-unban-ip $IP"
fi

# If nothing found at all:
if [[ "$csf_status" == "no_block" || "$csf_status" == "missing" ]] && [[ "$modsec_status" != "entries_found" ]] && [[ "$crowd_status" != "blocked" ]] && [[ "$cphulk_status" != "entries_found" ]]; then
  echo "Ніяких блокувань не виявлено (за перевіреними системами)."
fi

echo
sep
printf "IP check finished for: %s\n" "$IP"
sep
echo
