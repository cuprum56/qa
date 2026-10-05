-- =============================================================================
-- Seed-данные тестового стенда - observations_db
--
-- Схема без изменений:
--   observation-service/migrations/0001_init.sql
--   observation-service/migrations/0002_add_place.sql
--
-- Запуск - из stand/up.sh, файл подаётся в psql через stdin:
--   docker compose exec -T observations-db psql -U postgres -d observations_db \
--     -v ON_ERROR_STOP=1 < stand/200_observations_db.sql
--
-- ВНИМАНИЕ: ссылки между сервисами не защищены внешними ключами - базы изолированы.
-- mission_id ниже ссылается на задание в projects_db, но проверить это на уровне
-- СУБД невозможно. Именно поэтому в sql/sql-queries.sql есть запросы на "сиротские"
-- записи: они ищут нарушения ссылочной целостности, которые FK не поймал бы.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DELETE FROM observation_comments;
DELETE FROM observation_files;
DELETE FROM observations;

INSERT INTO observations (id, user_id, mission_id, title, description, status, place, created_at)
VALUES
  ('cccccccc-cccc-cccc-cccc-cccccccccccc',
   '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'Утка в пруду Центрального парка',
   'Одна взрослая особь, спокойно плавает у дальнего берега. Оперение серо-бурое.',
   'approved',
   'Москва, Измайловский парк, пруд',
   NOW() - INTERVAL '20 days'),

  ('cccccccc-cccc-cccc-cccc-cccccccccccd',
   '22222222-2222-2222-2222-222222222222',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbc',
   'Синицы на кормушке у дома',
   'Четыре птицы: две большие синицы, две лазоревки.',
   'pending',
   'Москва, ул. Кузьминская, д. 7',
   NOW() - INTERVAL '3 days');

-- Формат object_key и url повторяет то, что пишет сервис при загрузке
-- (observation-service/src/storage.rs:69-91):
--     object_key = "{observation_id}/{uuid4}-{title, не-alphanumeric -> _}"
--     url        = "{MINIO_ENDPOINT}/{bucket}/{object_key}"
-- Имя бакета в object_key НЕ участвует - это отдельная часть пути в url.
INSERT INTO observation_files (id, observation_id, title, file_type, url, object_key, created_at)
VALUES
  ('f1111111-1111-1111-1111-111111111111',
   'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'Утка крупно',
   'image/png',
   'http://minio:9000/observations/cccccccc-cccc-cccc-cccc-cccccccccccc/f1111111-1111-1111-1111-111111111111-Утка_крупно',
   'cccccccc-cccc-cccc-cccc-cccccccccccc/f1111111-1111-1111-1111-111111111111-Утка_крупно',
   NOW() - INTERVAL '20 days');

-- Ветка комментариев: ответ на ответ. Нужна, чтобы проверить каскадное удаление
-- родителя (API-09): при удалении dddddddd должен исчезнуть и eeeeeeee.
INSERT INTO observation_comments (id, observation_id, user_id, parent_comment_id, comment, created_at)
VALUES
  ('dddddddd-dddd-dddd-dddd-dddddddddddd',
   'cccccccc-cccc-cccc-cccc-cccccccccccc',
   '11111111-1111-1111-1111-111111111111',
   NULL,
   'Уточните, пожалуйста, время наблюдения - оно важно для сезонности.',
   NOW() - INTERVAL '19 days'),

  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
   'cccccccc-cccc-cccc-cccc-cccccccccccc',
   '22222222-2222-2222-2222-222222222222',
   'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'Наблюдение в 18:40, солнечно.',
   NOW() - INTERVAL '18 days');

COMMIT;

\echo 'observations_db: 2 наблюдения, 1 файл, ветка комментариев из 2 записей.'
