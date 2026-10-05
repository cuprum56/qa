#!/usr/bin/env bash
#
# Воспроизводимый стенд для тестирования платформы "Общее дело".
#
#   ./stand/up.sh              поднять backend + применить seed + поднять frontend
#   ./stand/up.sh backend      только backend и seed
#   ./stand/up.sh seed         переприменить seed на поднятом стенде
#   ./stand/up.sh psql [база]  интерактивный psql к одной из баз
#   ./stand/up.sh status       показать состояние
#   ./stand/up.sh logs         логи сервисов
#   ./stand/up.sh down         остановить (данные сохраняются)
#   ./stand/up.sh reset        удалить тома и поднять заново
#
# Нужен Docker с работающим docker compose (v2).
# Каталог с исходниками приложения задаётся APP_DIR - по умолчанию ищется
# в нескольких типовых местах относительно этого репозитория.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_DIR="$REPO_ROOT/stand"
GATEWAY_URL="http://localhost:8080"
FRONTEND_URL="http://localhost:3000"

die()  { printf '\033[31mx %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m+ %s\033[0m\n' "$*"; }
info() { printf '\033[2m  %s\033[0m\n' "$*"; }

compose() { docker compose --project-directory "$APP_DIR/backend" --env-file "$APP_DIR/backend/.env" "$@"; }

# -- 1. Находим исходники приложения --------------------------------------------
detect_app_dir() {
  if [ -n "${APP_DIR:-}" ]; then
    [ -f "$APP_DIR/backend/docker-compose.yml" ] && { printf '%s' "$APP_DIR"; return 0; }
    die "APP_DIR=$APP_DIR: не найден backend/docker-compose.yml"
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

# Определяются лениво: `--help` и проверка синтаксиса не должны требовать,
# чтобы приложение уже было на диске.
require_app_dir() {
  [ -n "${APP_DIR:-}" ] && return 0
  APP_DIR="$(detect_app_dir || true)"
  [ -n "$APP_DIR" ] || die "Не удалось найти каталог с backend/docker-compose.yml.
Задайте его явно:  APP_DIR=/путь/к/gra ./stand/up.sh"
  ok "Исходники приложения: $APP_DIR"
}

# -- 2. Готовим .env ------------------------------------------------------------
# docker-compose.yml требует эти переменные через ${VAR:?подсказка}, поэтому без
# .env compose не стартует. Файл генерируем один раз со случайными секретами:
# переиспользовать чужие секреты для стенда не нужно, а постоянные значения
# в репозитории - плохая привычка.
ensure_env() {
  local env_file="$APP_DIR/backend/.env"
  if [ -f "$env_file" ]; then
    ok ".env уже существует - используем прежние секреты"
    return
  fi
  command -v openssl >/dev/null 2>&1 || die "нужен openssl, чтобы сгенерировать .env"
  local gen="openssl rand -hex"
  {
    printf 'POSTGRES_USER=postgres\n'
    printf 'POSTGRES_PASSWORD=qa_%s\n' "$($gen 16)"
    printf 'REDIS_PASSWORD=\n'
    printf 'MINIO_ROOT_USER=qaadmin\n'
    printf 'MINIO_ROOT_PASSWORD=qa_%s\n' "$($gen 16)"
    printf 'JWT_SECRET=%s\n' "$($gen 32)"
    printf 'JWT_TTL_SECONDS=86400\n'
    printf 'MINIO_BUCKET=observations\n'
    printf 'MINIO_REGION=us-east-1\n'
    printf 'CORS_ALLOWED_ORIGINS=%s,%s\n' "$FRONTEND_URL" "http://127.0.0.1:3000"
  } > "$env_file"
  chmod 600 "$env_file"
  ok "Создан $env_file со случайными секретами"
}

# -- 3. Ждём готовности шлюза ----------------------------------------------------
wait_for_gateway() {
  info "Жду шлюз на $GATEWAY_URL/health (до 180 с)..."
  local i
  for i in $(seq 1 90); do
    if curl -fsS --max-time 2 "$GATEWAY_URL/health" >/dev/null 2>&1; then
      ok "Шлюз отвечает: $(curl -fsS "$GATEWAY_URL/health")"
      return 0
    fi
    sleep 2
  done
  die "Шлюз не поднялся за 180 с. Смотрите: ./stand/up.sh logs"
}

# -- 4. Seed --------------------------------------------------------------------
# Файлы передаются в psql через stdin: так не нужно ничего копировать в каталог
# приложения и не остаётся мусора после прогона.
apply_seed() {
  local row file service db
  while IFS=: read -r file service db; do
    [ -n "$file" ] || continue
    info "seed -> $service / $db ($(basename "$file"))"
    compose exec -T "$service" psql -U postgres -d "$db" \
      -v ON_ERROR_STOP=1 -q < "$SEED_DIR/$file" \
      || die "seed $file не применился"
  done <<'SEEDFILES'
000_users_db.sql:users-db:users_db
100_projects_db.sql:projects-db:projects_db
200_observations_db.sql:observations-db:observations_db
SEEDFILES
  ok "Seed-данные применены: 4 пользователя, 2 проекта, 2 задания, 2 наблюдения"
}

# -- 5. Frontend ----------------------------------------------------------------
# Фронтенд нужен только для ручных и UI-автотестов. API-тесты его не требуют,
# поэтому по умолчанию не поднимаем: npm ci на чистой машине занимает минуты.
start_frontend() {
  [ -d "$APP_DIR/frontend" ] || { info "каталог frontend не найден - пропускаю"; return 0; }
  if ! command -v npm >/dev/null 2>&1; then
    die "для фронтенда нужен npm"
  fi
  if [ ! -d "$APP_DIR/frontend/node_modules" ]; then
    info "устанавливаю зависимости фронтенда (npm ci)..."
    ( cd "$APP_DIR/frontend" && npm ci >/dev/null )
  fi
  if curl -fsS --max-time 2 "$FRONTEND_URL" >/dev/null 2>&1; then
    ok "Фронтенд уже отвечает на $FRONTEND_URL"
    return 0
  fi
  info "запускаю Next.js в фоне..."
  ( cd "$APP_DIR/frontend" && nohup npm run dev > "$SEED_DIR/frontend.log" 2>&1 & )
  local i
  for i in $(seq 1 45); do
    if curl -fsS --max-time 2 "$FRONTEND_URL" >/dev/null 2>&1; then
      ok "Фронтенд: $FRONTEND_URL (лог: stand/frontend.log)"
      return 0
    fi
    sleep 2
  done
  die "Фронтенд не поднялся за 90 с. Смотрите: stand/frontend.log"
}

# -- Команды --------------------------------------------------------------------
require_docker() {
  local probe
  # В WSL в PATH часто лежит шимм Docker Desktop, который сам печатает
  # "command 'docker' could not be found in this WSL 2 distro". Наличие бинаря
  # в PATH тут обманчиво, поэтому проверяем не наличие команды, а её вывод.
  probe="$(docker version 2>&1 || true)"
  if ! command -v docker >/dev/null 2>&1; then
    die "docker не найден в PATH. Установите Docker Engine или Docker Desktop."
  fi
  case "$probe" in
    *"could not be found in this WSL"*)
      die "Docker Desktop не подключён к этой WSL-дистрибутивы.
Включите Docker Desktop -> Settings -> Resources -> WSL Integration -> отметьте дистрибутив." ;;
  esac
  docker compose version >/dev/null 2>&1 || die "нужен docker compose v2 (docker-compose-plugin)"
  require_app_dir
}

# Базы разнесены по трём сервисам, поэтому psql запускается в нужном контейнере.
psql_target() {
  case "${1:-users_db}" in
    users_db)       printf 'users-db users_db' ;;
    projects_db)    printf 'projects-db projects_db' ;;
    observations_db) printf 'observations-db observations_db' ;;
    *) die "Неизвестная база: $1. Доступно: users_db, projects_db, observations_db" ;;
  esac
}

cmd_psql() {
  local service db
  read -r service db <<<"$(psql_target "${1:-users_db}")"
  [ $# -gt 0 ] && shift
  require_docker
  info "psql в $service / $db${*:+ $*}"
  # -T отключает псевдотерминал: без него перенаправление stdin из файла
  # (./stand/up.sh psql users_db < sql/sql-queries.sql) ломается.
  compose exec -T "$service" psql -U postgres -d "$db" "$@"
}

cmd_up() {
  require_docker

  ensure_env
  info "собираю образы и поднимаю сервисы (до 10 минут на первой сборке)..."
  compose up -d --build
  wait_for_gateway
  apply_seed

  if [ "${1:-}" = "backend" ]; then
    ok "Готово. API: $GATEWAY_URL/api ,  Swagger: http://localhost:8082/swagger-ui/"
  else
    start_frontend
    ok "Готово. UI: $FRONTEND_URL ,  API: $GATEWAY_URL/api"
  fi

  cat <<EOF

Учётные записи (пароль у всех Passw0rd):
  scientist@seed.local   учёный, владелец проекта
  volunteer@seed.local   волонтёр, участник
  stranger@seed.local    посторонний волонтёр - для проверок прав
  admin@seed.local       администратор

Дальше:
  ./api/newman.sh                       прогон API-автотестов
  ./stand/up.sh psql users_db           интерактивный SQL к users_db
EOF
}

cmd_seed()  { require_docker; wait_for_gateway; apply_seed; }
cmd_status() {
  require_docker
  printf 'шлюз:     '; curl -fsS --max-time 2 "$GATEWAY_URL/health" 2>/dev/null || echo 'не отвечает'
  printf '\nфронтенд: '; curl -fsS -o /dev/null --max-time 2 -w '%{http_code}' "$FRONTEND_URL" 2>/dev/null || echo 'не отвечает'
  printf '\n\n'
  compose ps 2>/dev/null || true
}
cmd_logs()  { require_docker; compose logs -f --tail 100; }
cmd_down()  { require_docker; compose down; ok "Остановлено, тома сохранены"; }
cmd_reset() { require_docker; compose down -v; ok "Тома удалены. Следующий ./stand/up.sh поднимет стенд с нуля."; }

usage() {
  cat <<'EOF'
Использование: ./stand/up.sh [команда]

  (без аргументов)  backend + seed + frontend
  backend           только backend и seed
  seed              переприменить seed на поднятом стенде
  psql [база]       интерактивный psql: users_db | projects_db | observations_db
  status            состояние контейнеров и коды /health
  logs              хвост логов сервисов
  down              остановить, тома сохранить
  reset             удалить тома (следующий запуск поднимет стенд с нуля)

Переменные окружения:
  APP_DIR           каталог с backend/docker-compose.yml, если он не в типовых местах
EOF
}

# -- Точка входа ----------------------------------------------------------------
command="${1:-up}"
shift || true

case "$command" in
  up)      cmd_up "${1:-}" ;;
  backend) cmd_up backend ;;
  seed)    cmd_seed ;;
  psql)    cmd_psql "${1:-}" ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  down)    cmd_down ;;
  reset)   cmd_reset ;;
  -h|--help|help) usage ;;
  *)       usage >&2; die "Неизвестная команда: $command" ;;
esac
