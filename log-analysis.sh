#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_FILE="${SCRIPT_DIR}/log-analysis-result.txt"
> "$RESULT_FILE"

log() {
    echo "$1" | tee -a "$RESULT_FILE"
}

log "=== Log analysis started ==="
log "Started at: $(date)"
log ""

# --- 1. Визначення вебсервера та панелі керування ---

WEBSERVER=""
PANEL="unknown"

if pgrep -x nginx >/dev/null; then
    WEBSERVER="nginx"
elif pgrep -x httpd >/dev/null || pgrep -x apache2 >/dev/null; then
    WEBSERVER="apache"
elif pgrep -x lshttpd >/dev/null; then
    WEBSERVER="litespeed"
else
    echo "Не вдалося визначити вебсервер." >&2
    exit 1
fi

# Розширена перевірка панелі керування
# helper: перевірити systemctl тільки якщо команда доступна
is_active() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
    fi
    return 1
}

# DirectAdmin
if pgrep -x directadmin >/dev/null 2>&1 \
   || pgrep -f '/usr/local/directadmin' >/dev/null 2>&1 \
   || [ -x /usr/local/directadmin/directadmin ] \
   || is_active directadmin; then
    PANEL="DirectAdmin"

# cPanel (cpsrvd, cpanel)
elif [ -d /usr/local/cpanel ] \
   || [ -f /usr/local/cpanel/version ] \
   || pgrep -f 'cpsrvd|cpanel' >/dev/null 2>&1 \
   || is_active cpanel \
   || is_active cpsrvd; then
    PANEL="cPanel"

# Plesk
elif [ -d /usr/local/psa ] \
   || [ -d /opt/psa ] \
   || pgrep -f 'psa|plesk' >/dev/null 2>&1 \
   || is_active psa \
   || is_active sw-engine; then
    PANEL="Plesk"
fi

SERVER_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

log "Webserver: $WEBSERVER"
log "Control panel: $PANEL"
log "Server time: $SERVER_TIME"
log ""

# --- 2. Пошук конфігів і доменів ---

declare -A DOMAIN_LOGS_SET
declare -A DOMAIN_SSL_LOGS_SET

CONF_PATHS=()

case "$WEBSERVER" in
    nginx)
        CONF_PATHS+=(/etc/nginx/conf.d /etc/nginx/sites-enabled /usr/local/nginx/conf/vhosts)
        ;;
    apache)
        CONF_PATHS+=(/etc/httpd/conf.d /etc/apache2/sites-enabled)
        ;;
    litespeed)
        CONF_PATHS+=(/usr/local/lsws/conf/vhosts)
        ;;
esac

is_text_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    local mime
    mime=$(file --mime-type -b "$file")
    [[ "$mime" == text/* ]] && return 0
    return 1
}

for CONF_DIR in "${CONF_PATHS[@]}"; do
    [ -d "$CONF_DIR" ] || continue

    while IFS= read -r CONF_FILE; do
        DOMAIN=$(grep -E "server_name|ServerName" "$CONF_FILE" 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/;//')
        LOGS=$(grep -E "access_log|CustomLog" "$CONF_FILE" 2>/dev/null | awk '{print $2}' | sed 's/;//')

        if [[ -n "$DOMAIN" && -n "$LOGS" ]]; then
            for logf in $LOGS; do
                [ -z "$logf" ] && continue
                if [[ "$logf" != /* ]]; then
                    logf="$(dirname "$CONF_FILE")/$logf"
                fi
                if is_text_file "$logf"; then
                    if [[ "$logf" =~ ssl|https ]]; then
                        DOMAIN_SSL_LOGS_SET["$DOMAIN|$logf"]=1
                    else
                        DOMAIN_LOGS_SET["$DOMAIN|$logf"]=1
                    fi
                fi
            done
        fi
    done < <(find "$CONF_DIR" -type f)
done

if [ "${#DOMAIN_LOGS_SET[@]}" -eq 0 ] && [ "${#DOMAIN_SSL_LOGS_SET[@]}" -eq 0 ]; then
    echo "Не знайдено доменів та логів." >&2
    exit 1
fi

get_domain_logs() {
    local domain="$1"
    local -n arr_ref=$2
    arr_ref=()
    for key in "${!DOMAIN_LOGS_SET[@]}"; do
        if [[ $key == "$domain|"* ]]; then
            arr_ref+=("${key#*|}")
        fi
    done
}

get_domain_ssl_logs() {
    local domain="$1"
    local -n arr_ref=$2
    arr_ref=()
    for key in "${!DOMAIN_SSL_LOGS_SET[@]}"; do
        if [[ $key == "$domain|"* ]]; then
            arr_ref+=("${key#*|}")
        fi
    done
}

# --- 3. Вибір домену ---

echo "Доступні домени:"
DOMAINS=()
for key in "${!DOMAIN_LOGS_SET[@]}"; do
    DOMAINS+=("${key%%|*}")
done
for key in "${!DOMAIN_SSL_LOGS_SET[@]}"; do
    DOMAINS+=("${key%%|*}")
done
readarray -t DOMAINS_UNIQ < <(printf '%s\n' "${DOMAINS[@]}" | sort -u)

select DOMAIN in "ALL" "${DOMAINS_UNIQ[@]}"; do
    [ -n "$DOMAIN" ] && break
done

# --- 4. Вибір періоду ---

echo "Оберіть період:"
select PERIOD in "1h" "2h" "4h" "8h" "24h" "ALL"; do
    [ -n "$PERIOD" ] && break
done

case "$PERIOD" in
    1h) SINCE_EPOCH=$(( $(date +%s) - 3600 ));;
    2h) SINCE_EPOCH=$(( $(date +%s) - 7200 ));;
    4h) SINCE_EPOCH=$(( $(date +%s) - 14400 ));;
    8h) SINCE_EPOCH=$(( $(date +%s) - 28800 ));;
    24h) SINCE_EPOCH=$(( $(date +%s) - 86400 ));;
    ALL) SINCE_EPOCH=0;;
esac

# --- 5. TOP значень ---

read -p "Скільки значень виводити (20/50/100) [20]: " TOP
TOP=${TOP:-20}

# --- 6. Аналіз логів ---

analyze_files() {
    local DOMAIN_NAME="$1"
    shift
    local FILES=("$@")

    log "=== Domain: $DOMAIN_NAME ==="
    log "Log files:"
    for f in "${FILES[@]}"; do
        log " - $f"
    done

    FILTERED_LINES=$(mktemp)
    for f in "${FILES[@]}"; do
        if [ "$SINCE_EPOCH" -eq 0 ]; then
            cat "$f" >> "$FILTERED_LINES"
        else
            awk -v since="$SINCE_EPOCH" '
            {
                match($0, /\[([0-9]{2})\/([A-Za-z]{3})\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+\-0-9]{5})\]/, arr);
                if(arr[0] != ""){
                    mon = arr[2]
                    m["Jan"]="01"; m["Feb"]="02"; m["Mar"]="03"; m["Apr"]="04"; m["May"]="05"; m["Jun"]="06";
                    m["Jul"]="07"; m["Aug"]="08"; m["Sep"]="09"; m["Oct"]="10"; m["Nov"]="11"; m["Dec"]="12";
                    month = m[mon]
                    date_str = arr[3] "-" month "-" arr[1] " " arr[4] ":" arr[5] ":" arr[6] " " arr[7]
                    cmd = "date -d \"" date_str "\" +%s"
                    cmd | getline logtime
                    close(cmd)
                    if (logtime >= since)
                        print $0
                }
            }
            ' "$f" >> "$FILTERED_LINES"
        fi
    done

    log "--- TOP IP (combined SSL + non-SSL) ---"
    awk '{print $1}' "$FILTERED_LINES" | sort | uniq -c | sort -nr | head -n "$TOP" | tee -a "$RESULT_FILE"

    log "--- TOP User-Agents (combined SSL + non-SSL) ---"
    awk -F\" '{print $6}' "$FILTERED_LINES" | grep -v '^$' | sort | uniq -c | sort -nr | head -n "$TOP" | tee -a "$RESULT_FILE"

    log ""
    rm -f "$FILTERED_LINES"
}

if [ "$DOMAIN" = "ALL" ]; then
    declare -A ALL_LOGS_SET
    for d in "${DOMAINS_UNIQ[@]}"; do
        get_domain_logs "$d" arr1
        get_domain_ssl_logs "$d" arr2
        for f in "${arr1[@]}" "${arr2[@]}"; do
            ALL_LOGS_SET["$f"]=1
        done
    done
    FILES=("${!ALL_LOGS_SET[@]}")
    analyze_files "ALL_DOMAINS" "${FILES[@]}"
else
    FILES1=()
    FILES2=()
    get_domain_logs "$DOMAIN" FILES1
    get_domain_ssl_logs "$DOMAIN" FILES2
    FILES=("${FILES1[@]}" "${FILES2[@]}")

    if [ ${#FILES[@]} -eq 0 ]; then
        log "Лог файли для домену $DOMAIN не знайдені."
        exit 1
    fi

    analyze_files "$DOMAIN" "${FILES[@]}"
fi

log "=== Log analysis finished ==="
log "Finished at: $(date)"
