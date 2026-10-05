# Тестовый стенд

Воспроизводимое окружение для [api/newman.sh](../api/newman.sh) и ручных проверок: все
идентификаторы в тест-кейсах и SQL-запросах ссылаются на одни и те же строки этого seed.

```bash
./stand/up.sh          # backend + seed + frontend
./api/newman.sh        # прогон автотестов
```


> **WSL.** Docker из WSL работает только с включённой интеграцией: Docker Desktop -> Settings ->
> Resources -> WSL Integration -> включить дистрибутив. Если `docker` не найден, `up.sh` сообщит об
> этом и завершится, а не упадёт в середине сборки.

## Команды

- `./stand/up.sh` - образы, сервисы, ожидание шлюза, seed, frontend. `backend` - то же без
  фронтенда: API-тесты его не требуют, а `npm ci` на чистой машине занимает минуты.
- `./stand/up.sh seed` - переприменить seed; `status` - состояние контейнеров и коды `/health`;
  `logs` - хвост логов; `down` - остановить с сохранением томов; `reset` - снести тома и поднять заново.
- `./stand/up.sh psql [база]` - интерактивный psql в `users_db`, `projects_db` или `observations_db`.

**Путь к исходникам.** `up.sh` ищет каталог с `backend/docker-compose.yml` рядом с репозиторием
и в `/mnt/c/prog/mai/gra`; если приложение в другом месте - `APP_DIR=/путь/к/gra ./stand/up.sh`.

**Секреты.** `docker-compose.yml` требует `POSTGRES_PASSWORD`, `JWT_SECRET`, `MINIO_ROOT_USER`,
`MINIO_ROOT_PASSWORD` (синтаксис `${VAR:?}`). `up.sh` создаёт `backend/.env` со **случайными**
значениями при первом запуске и больше его не трогает. `JWT_SECRET` нужен и за пределами compose:
`api/newman.sh` читает его, чтобы подписать токены для негативных сценариев обработки токена.

## Топология

- `3000` Next.js - интерфейс; `80` nginx - внешняя точка входа; `8080` gateway - точка входа для
  тестов; `8081`, `8082`, `8083` - user-, project-, observation-service.
- `5432` - три изолированные базы `users_db`, `projects_db`, `observations_db`; `6379` - Redis,
  сессии; `9000` - MinIO, файлы.

Тесты ходят на `:8080`, минуя nginx. Разница существенна: nginx отдаёт HTML-ошибку при превышении
`client_max_body_size`, а gateway - JSON, поэтому коды ошибок проверяются через 8080.

## Seed-данные

- `000_users_db.sql` -> `users_db`: 4 учётные записи и 2 участия.
- `100_projects_db.sql` -> `projects_db`: 2 проекта, 5 тегов, 2 задания.
- `200_observations_db.sql` -> `observations_db`: 2 наблюдения, 1 файл, ветка из 2 комментариев.

Все пароли - `Passw0rd`, хеш один (bcrypt `$2b$`, cost 12): соль хранится внутри хеша, поэтому
пароль проверяется одинаково, а стенд остаётся воспроизводимым. Команда перегенерации - в шапке
`000_users_db.sql`.

**Учётные записи** (`users_db`): `scientist@seed.local` `11111111-...` - владелец проекта и модератор;
`volunteer@seed.local` `22222222-...` - участник, ему принадлежит seed-наблюдение; `admin@seed.local`
`33333333-...` - верхний уровень прав; `stranger@seed.local` `44444444-...` - **не участник** проекта.

`stranger` намеренно не входит в проект: запросы к ресурсам проекта от его имени должны давать
`403`, а не `404`, иначе сценарии проверки прав потеряли бы смысл.

**Ключевые идентификаторы.** `projects_db`: `aaaaaaaa-...` - проект "Мониторинг птиц Кузьминского
парка", `eeeeeeee-...` - "Учёт опылителей на дачных участках", `bbbbbbbb-...bbbb` - задание с флагом
`[meta:require_photo]`, `bbbbbbbb-...bbbc` - второе задание без фото. `observations_db`:
`cccccccc-...cccc` - наблюдение волонтёра, `approved`; `cccccccc-...cccd` - второе, `pending`;
`f1111111-...` - файл у первого; `dddddddd-...` - комментарий-родитель; `eeeeeeee-...` - ответ
волонтёра, для проверки каскадного удаления.

Префикс `eeeeeeee` используется дважды - во второй базе это проект, в третьей комментарий. Базы
изолированы, коллизии нет, но при ручном копировании фрагментов легко перепутать.

## Проверки

```bash
python3 stand/validate_seed.py [/путь/к/gra]
./stand/up.sh psql users_db        < sql/00-users-db.sql
./stand/up.sh psql projects_db     < sql/10-projects-db.sql
./stand/up.sh psql observations_db < sql/20-observations-db.sql
```

`validate_seed.py` строит схему из миграций сервисов (учитывая `DROP COLUMN` и `ADD COLUMN`) и
сверяет с ней колонки в `INSERT` seed-файлов; ловит удалённую миграцией колонку `projects.tags`.
Работает без Docker и сети. SQL-проверки нужны после `newman.sh`: автотесты смотрят на HTTP-контракт,
а не на остатки в таблицах; между базами нет внешних ключей, поэтому часть проверок - ручная сверка.

## Частые проблемы

- `docker: command not found` - не включена WSL Integration, см. требования.
- `POSTGRES_PASSWORD is required` - удалите `backend/.env` и запустите `up.sh` заново.
- `column "tags" does not exist` - seed применён раньше миграций, помогает `./stand/up.sh seed`.
- Шлюз не отвечает за 180 с - смотрите `./stand/up.sh logs`, обычно первая сборка долгая.
- Newman пишет `ECONNREFUSED` - стенд не поднят, нужен `./stand/up.sh backend`.
- Ошибка `bcrypt` при входе - хеш не соответствует паролю, перегенерируйте из `000_users_db.sql`.

## Границы стенда

TLS, HSTS и Secure-cookie не проверяются (HTTP), реальная почта не работает (SMTP не настроен -
это дефект WEB-04), нагрузочные измерения бессмысленны, см. [docs/methodology.md](../docs/methodology.md).