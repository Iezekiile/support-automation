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

  # Use a null-delimited loop instead of xargs to avoid running du with no args.
  find "$ROOT" $(build_find_excludes) -type f -size "$MIN_SIZE" -print0 2>/dev/null \
    | (
        found=0
        while IFS= read -r -d '' file; do
          found=1
          du -b "$file" 2>/dev/null
        done
        # If nothing found, produce no output (prevents du reporting '.' when no args)
        if [ "$found" -eq 0 ]; then
          :
        fi
      ) \
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

  # Try to use 'du --inodes' if available (most GNU coreutils support it).
  # Fallback to 'find' counting if du --inodes is not supported.
  if du -x --inodes "$ROOT" >/dev/null 2>&1; then
    du -x --inodes "$ROOT" 2>/dev/null \
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
      | head -n "$TOP"
  else
    # Fallback: count files under ROOT using find (relative paths) and aggregate.
    # This produces similar results but may differ in edge cases vs du --inodes.
    # Normalize ROOT (remove trailing slash except for "/")
    local ROOT_NO_TRAIL="${ROOT%/}"
    if [[ -z "$ROOT_NO_TRAIL" ]]; then
      ROOT_NO_TRAIL="/"
    fi

    find "$ROOT" -xdev -type f -printf '%P\0' 2>/dev/null \
      | awk -v root="$ROOT_NO_TRAIL" 'BEGIN { RS = "\0"; FS = "/" }
        {
          # skip empty records
          if (NF == 1 && $1 == "") next
          cur = root
          for (i = 1; i <= NF - 1; i++) {
            if (cur == "/") cur = "/" $i
            else cur = cur "/" $i
            count[cur]++
          }
        }
        END {
          for (d in count) print count[d], d
        }' \
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
  fi
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
