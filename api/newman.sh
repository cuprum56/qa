#!/usr/bin/env bash
#
# Прогон API-автотестов коллекции Postman через Newman.
#
# Коды выхода: 0 - ожидаемо, 1 - регрессии, 2 - стенд не отвечает или прогон
# недействителен, 3 - какой-то дефект перестал воспроизводиться.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="$REPO_ROOT/api"
OUT_DIR="$REPO_ROOT/test-report/newman"
COLLECTION="$API_DIR/postman_collection.json"
ENVIRONMENT="$API_DIR/environment.json"

BASE_URL="${BASE_URL:-http://localhost:8080/api}"

die() { printf '\033[31mx %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }
ok()  { printf '\033[32m+ %s\033[0m\n' "$*"; }

command -v newman >/dev/null 2>&1 || die "newman не найден. Установите: npm install -g newman"
command -v node    >/dev/null 2>&1 || die "node не найден"
[ -f "$COLLECTION" ] || die "нет коллекции $COLLECTION"

usage() {
  cat <<'EOF'
Использование: ./api/newman.sh [опции]

  --folder "04 Projects"   прогнать только одну папку коллекции
  --tag contract           прогнать только запросы с этим тегом
  --bail                   остановиться на первом провале проверки

Переменные окружения:
  BASE_URL     адрес API, по умолчанию http://localhost:8080/api
  JWT_SECRET   если задан, используется вместо backend/.env
  APP_DIR      каталог с backend/docker-compose.yml

Коды выхода: 0 - ожидаемо, 1 - регрессии, 2 - стенд недоступен,
3 - какой-то дефект перестал воспроизводиться.
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

# -- 1. Проверяем, что стенд отвечает --------------------------------------------
# /health живёт на шлюзе, без префикса /api, поэтому адрес выводим из BASE_URL.
GATEWAY_URL="${BASE_URL%/api}"
if ! curl -fsS --max-time 5 "$GATEWAY_URL/health" >/dev/null 2>&1; then
  die "стенд не отвечает на $GATEWAY_URL/health. Поднимите его: ./stand/up.sh" 2
fi

# -- 2. Достаём JWT_SECRET: переменная окружения или backend/.env ----------------
# Секрет нужен, чтобы подписать битые и просроченные токены для сценариев 10 Contract.
# backend/.env создаёт ./stand/up.sh; путь к приложению ищется так же, как там.
detect_app_dir() {
  if [ -n "${APP_DIR:-}" ]; then
    [ -f "$APP_DIR/backend/docker-compose.yml" ] && { printf '%s' "$APP_DIR"; return 0; }
    return 1
  fi
  local candidate
  for candidate in \
      "$REPO_ROOT/../app" \
      "$REPO_ROOT/../gra" \
      "$REPO_ROOT/../../gra" \
      "$HOME/prog/gra" \
      "$HOME/gra" \
      /mnt/c/prog/mai/gra; do
    if [ -f "$candidate/backend/docker-compose.yml" ]; then
      ( cd "$candidate" && pwd ) && return 0
    fi
  done
  return 1
}

resolve_secret() {
  if [ -n "${JWT_SECRET:-}" ]; then printf '%s' "$JWT_SECRET"; return 0; fi
  local app_dir env_file
  app_dir="$(detect_app_dir || true)"
  [ -n "$app_dir" ] || return 1
  env_file="$app_dir/backend/.env"
  [ -f "$env_file" ] || return 1
  sed -n 's/^JWT_SECRET=//p' "$env_file" | head -1 | tr -d '"'"'"'\r'
}

SECRET="$(resolve_secret || true)"
if [ -z "$SECRET" ]; then
  die "не удалось получить JWT_SECRET.
Нужен для подписи битых и просроченных токенов в сценариях 10 Contract.
Варианты: экспортировать JWT_SECRET вручную, либо поднять стенд (./stand/up.sh),
который создаёт backend/.env со случайным секретом."
fi

# -- 3. Временная копия коллекции с абсолютными путями к фикстурам ---------------
# Newman разрешает пути multipart-файлов относительно текущего каталога,
# поэтому пути делаем абсолютными - тогда запуск не зависит от места вызова.
RUN_ID="$(date +%s)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
RESOLVED="$WORK_DIR/collection.json"

python3 - "$COLLECTION" "$REPO_ROOT" "$RESOLVED" <<'PY'
import io, json, sys
src, root, dst = sys.argv[1], sys.argv[2], sys.argv[3]
col = json.load(io.open(src, encoding='utf-8'))
fixed = 0
for folder in col.get('item', []):
    for request in folder.get('item', []):
        body = request.get('request', {}).get('body', {})
        for field in body.get('formdata', []) or []:
            if field.get('type') == 'file' and field.get('src'):
                field['src'] = [root + '/' + p.lstrip('./') for p in field['src']]
                fixed += 1
json.dump(col, io.open(dst, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('  абсолютных путей к фикстурам: %d' % fixed)
PY

# -- 4. Подделанные и истёкшие токены -------------------------------------------
mapfile -t TOKEN_LINES < <(python3 "$API_DIR/gen_tokens.py" --secret "$SECRET")
ENV_VARS=()
for line in "${TOKEN_LINES[@]}"; do
  [ -n "$line" ] && ENV_VARS+=(--env-var "$line")
done
ok "токены для негативных сценариев сгенерированы"

# -- 5. Аргументы прогона -------------------------------------------------------
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --folder) EXTRA+=(--folder "$2"); shift 2 ;;
    --tag)    EXTRA+=(--tag "$2"); shift 2 ;;
    --bail)   EXTRA+=(--bail); shift ;;
    *)        die "неизвестный аргумент: $1" ;;
  esac
done

mkdir -p "$OUT_DIR"
STAMP="$RUN_ID"
JSON_REPORT="$OUT_DIR/report-$STAMP.json"
JUNIT_REPORT="$OUT_DIR/junit-$STAMP.xml"
HTML_REPORT="$OUT_DIR/report-$STAMP.html"

printf '\n\033[1mПрогон API-автотестов\033[0m\n'
printf '  коллекция: %s\n' "${COLLECTION#$REPO_ROOT/}"
printf '  стенд:     %s\n' "$BASE_URL"
printf '  отчёты:    %s\n' "${OUT_DIR#$REPO_ROOT/}/report-$STAMP.*"
printf '\n'

set +e
newman run "$RESOLVED" \
  --environment "$ENVIRONMENT" \
  --env-var "base_url=${BASE_URL#/http://}" \
  --env-var "run_id=$RUN_ID" \
  "${ENV_VARS[@]}" \
  --reporters cli,json,junit,html \
  --reporter-json-export "$JSON_REPORT" \
  --reporter-junit-export "$JUNIT_REPORT" \
  --reporter-html-export "$HTML_REPORT" \
  --reporter-html-export-include "assertions,failures,summary" \
  --color on \
  "${EXTRA[@]}"
STATUS=$?
set -e

python3 "$API_DIR/summarize.py" "$JSON_REPORT" "$COLLECTION" && SUMMARY=0 || SUMMARY=$?

# Решение принимает summarize.py: он единственный, кто различает регрессию,
# "дефект исправлен" и недействительный прогон.
if [ "$SUMMARY" -eq 0 ] && [ "$STATUS" -ne 0 ]; then
  printf '\n\033[33m! сводка не нашла ни регрессий, ни исправленных дефектов,\033[0m\n'
  printf '  но newman вернул код %d. Скорее всего, упал сам прогон или репортер.\n' "$STATUS"
  exit "$STATUS"
fi

case "$SUMMARY" in
  0) ok "прогон ожидаем: регрессий нет, все дефекты воспроизводятся" ;;
  1) printf '\033[31mx найдены регрессии\033[0m - см. bug-reports/api-critical.md, api-major-auth.md, api-major-domain.md, api-minor.md\n' ;;
  2) printf '\033[33m! прогон недействителен: запросы не дошли до стенда\033[0m\n' ;;
  3) printf '\033[33m! какой-то дефект перестал воспроизводиться\033[0m - сценарий надо переписать\n' ;;
esac
exit "$SUMMARY"
