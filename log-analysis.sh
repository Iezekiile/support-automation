#!/bin/bash

# Функція конвертації дати логів у timestamp (приклад для формату: 10/Oct/2023:14:22:01)
log_date_to_epoch() {
  date_str="$1"
  # Конвертуємо дату формату dd/MMM/yyyy:HH:mm:ss у формат для date
  # Припускаємо, що локаль англійська для місяців
  date -d "$(echo "$date_str" | sed 's/\// /g; s/:/ /4')" +%s 2>/dev/null
}

# Визначення періоду часу (час початку фільтрації)
select_time_range() {
  echo "Оберіть період аналізу логів:"
  echo "1) Остання година"
  echo "2) Останні 2 години"
  echo "3) Останні 4 години"
  echo "4) Останні 24 години"
  read -rp "Введіть номер опції: " time_option

  case $time_option in
    1) echo "1 hour";;
    2) echo "2 hours";;
    3) echo "4 hours";;
    4) echo "24 hours";;
    *) echo "1 hour";;
  esac
}

# Пошук логів за доменом або всі
find_log_files() {
  local domain="$1"
  local logs=()
  local patterns=()

  # Типові каталоги з логами
  local paths=(
    "/var/log/nginx/domains"
    "/var/log/nginx"
    "/var/log/apache2"
    "/usr/local/nginx/logs"
    "/var/www"
  )

  # Формуємо патерни
  if [[ -n "$domain" ]]; then
    patterns=(
      "$domain"
      "$domain.*"
      "*$domain*"
      "*${domain}_ssl*"
      "*${domain}-ssl*"
      "access.log"
      "access.log.*"
    )
  else
    patterns=(
      "access.log"
      "access.log.*"
      "*.log"
      "*_ssl*"
      "*-ssl*"
    )
  fi

  for p in "${paths[@]}"; do
    [[ -d "$p" ]] || continue

    for pat in "${patterns[@]}"; do
      while IFS= read -r -d '' file; do
        # Базова перевірка: файл має бути текстовим і читабельним
        if [[ -r "$file" ]] && file "$file" | grep -qi "text"; then
          logs+=("$file")
        fi
      done < <(find "$p" -type f -name "$pat" -print0 2>/dev/null)
    done
  done

  # Прибираємо дублікати
  printf '%s\n' "${logs[@]}" | sort -u
}

# Фільтрація логів за часом
filter_logs_by_time() {
  local files=("$@")
  local since_epoch=$SINCE_EPOCH

  # Припущення формату дати в логах: [10/Oct/2023:14:22:01 ...]
  for f in "${files[@]}"; do
    awk -v since="$since_epoch" '
      {
        # Витягаємо дату з логу у форматі dd/MMM/yyyy:HH:mm:ss (між [ та :)
        match($0, /\[([0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2})/, arr)
        if (arr[1] != "") {
          cmd = "date -d \"" arr[1] "\" +%s"
          cmd | getline logtime
          close(cmd)
          if (logtime >= since) print $0
        }
      }
    ' "$f"
  done
}

######################
# Початок виконання скрипту

# 1. Вибір періоду часу
TIME_RANGE=$(select_time_range)
SINCE_EPOCH=$(date -d "-$TIME_RANGE" +%s)

# 2. Вибір домену
read -rp "Введіть домен для аналізу або 'all' для всіх доменів: " DOMAIN_INPUT
if [[ "$DOMAIN_INPUT" == "all" || -z "$DOMAIN_INPUT" ]]; then
  DOMAIN=""
else
  DOMAIN="$DOMAIN_INPUT"
fi

# 3. Знаходимо логи
LOG_FILES=($(find_log_files "$DOMAIN"))

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
  echo "Не знайдено логів для домену '${DOMAIN:-всі}'."
  exit 1
fi

# 4. Вибір UA поля
read -rp "Для User-Agent: введіть 1 для NF-1 або 2 для NF-2: " UA_FIELD_NUM
if ! [[ "$UA_FIELD_NUM" =~ ^[12]$ ]]; then
  UA_FIELD_NUM=1
fi

# 5. Кількість рядків для виводу
read -rp "Скільки рядків показувати (head -n, за замовчуванням 20): " HEAD_COUNT
if ! [[ "$HEAD_COUNT" =~ ^[0-9]+$ ]]; then
  HEAD_COUNT=20
fi

# 6. Фільтруємо логи за часом і зберігаємо у тимчасовий файл
TMP_LOG=$(mktemp)
filter_logs_by_time "${LOG_FILES[@]}" > "$TMP_LOG"

# 7. Виводимо статистику по User-Agent
echo
echo "Топ $HEAD_COUNT User-Agent за період $TIME_RANGE для домену '${DOMAIN:-всі}':"
awk -F'"' -v field_num="$UA_FIELD_NUM" '{
  ua = $(NF - field_num);
  if(length(ua)) print ua; else print "<EMPTY-USER-AGENT>"
}' "$TMP_LOG" | sort | uniq -c | sort -nr | head -n "$HEAD_COUNT"

# 8. Виводимо статистику по IP
echo
echo "Топ $HEAD_COUNT IP за період $TIME_RANGE для домену '${DOMAIN:-всі}':"
awk '{print $1}' "$TMP_LOG" | sort | uniq -c | sort -nr | head -n "$HEAD_COUNT"

# 9. Чистимо тимчасовий файл
rm -f "$TMP_LOG"
