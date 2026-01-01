#!/bin/bash

EXCLUDES=(
  "/proc"
  "/sys"
  "/dev"
  "/run"
  "/tmp"
  "/var/run"
)

print_line() {
  echo "------------------------------------------------------------"
}

human() {
  numfmt --to=iec --suffix=B --format="%.1f" "$1"
}

read_top() {
  echo "Скільки об'єктів показувати? (20 / 50 / 100)"
  read TOP
  [[ ! "$TOP" =~ ^(20|50|100)$ ]] && TOP=20
}

read_min_size() {
  echo "Мінімальний розмір файлів:"
  echo "1 - понад 50 MB"
  echo "2 - понад 100 MB"
  echo "3 - понад 250 MB"
  echo "4 - понад 1 GB"
  read SIZE_CHOICE

  case "$SIZE_CHOICE" in
    1) MIN_SIZE="+50M" ;;
    2) MIN_SIZE="+100M" ;;
    3) MIN_SIZE="+250M" ;;
    4) MIN_SIZE="+1G" ;;
    *) MIN_SIZE="+50M" ;;
  esac
}

build_find_excludes() {
  for d in "${EXCLUDES[@]}"; do
    echo -n " -path $d -prune -o"
  done
}

print_fs_usage() {
  print_line
  echo "Дисковий простір (розділ /):"
  df -h /
}

top_heavy_files() {
  local ROOT="$1"

  print_line
  echo "Найважчі файли (>${MIN_SIZE}):"

  find "$ROOT" $(build_find_excludes) -type f -size "$MIN_SIZE" -print0 2>/dev/null \
    | xargs -0 du -b 2>/dev/null \
    | sort -nr \
    | head -n "$TOP" \
    | while read SIZE FILE; do
        echo "$(human "$SIZE")  $FILE"
      done
}

top_dirs_by_size() {
  local ROOT="$1"

  print_line
  echo "Найважчі директорії (за обсягом, нижній рівень):"

  du -x --bytes "$ROOT" 2>/dev/null \
    | sort -nr \
    | awk '
      {
        path=$2
        skip=0
        for (i in seen)
          if (index(path, i"/") == 1) skip=1
        if (!skip) {
          seen[path]=1
          print $1, path
        }
      }
    ' \
    | head -n "$TOP" \
    | while read SIZE DIR; do
        echo "$(human "$SIZE")  $DIR"
      done
}

top_dirs_by_inodes() {
  local ROOT="$1"

  print_line
  echo "Найважчі директорії (за інодами, нижній рівень):"

  find "$ROOT" -xdev -type f 2>/dev/null \
    | awk -F/ '
      {
        dir=""
        for (i=1; i<=NF-1; i++) {
          dir=dir"/"$i
          count[dir]++
        }
      }
      END {
        for (d in count)
          print count[d], d
      }
    ' \
    | sort -nr \
    | awk '
      {
        path=$2
        skip=0
        for (i in seen)
          if (index(path, i"/") == 1) skip=1
        if (!skip) {
          seen[path]=1
          print
        }
      }
    ' \
    | head -n "$TOP"
}

print_inode_usage() {
  print_line
  echo "Іноди:"
  df -ih "$1"
}

print_line
echo "Оберіть режим роботи:"
echo "1 - VPS"
echo "2 - Shared hosting"
read MODE

read_top
read_min_size

if [[ "$MODE" == "1" ]]; then
  ROOT="/"

  print_fs_usage
  print_inode_usage "/"

  top_heavy_files "$ROOT"
  top_dirs_by_size "$ROOT"
  top_dirs_by_inodes "$ROOT"

elif [[ "$MODE" == "2" ]]; then
  ROOT="$(pwd)"

  print_line
  echo "Поточна директорія: $ROOT"

  print_fs_usage
  print_inode_usage "$ROOT"

  top_heavy_files "$ROOT"
  top_dirs_by_size "$ROOT"
  top_dirs_by_inodes "$ROOT"

else
  echo "Некоректний вибір режиму."
  exit 1
fi

print_line
echo "Аналіз завершено."
