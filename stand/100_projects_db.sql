-- =============================================================================
-- Seed-данные тестового стенда - projects_db
--
-- Схема без изменений:
--   project-service/migrations/0001_init.sql
--   project-service/migrations/0002_tags_table.sql
--
-- ВАЖНО: колонка projects.tags удалена миграцией 0002. Теги лежат в таблице
-- tags с уникальным индексом по (project_id, lower(name)).
--
-- Запуск - из stand/up.sh, файл подаётся в psql через stdin:
--   docker compose exec -T projects-db psql -U postgres -d projects_db \
--     -v ON_ERROR_STOP=1 < stand/100_projects_db.sql
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DELETE FROM tags;
DELETE FROM missions;
DELETE FROM projects;

-- Второй проект нужен, чтобы сценарии вида
--   GET /api/projects/00000000-0000-0000-0000-000000000000/missions/{id}
-- проверяли принадлежность ресурса, а не отсутствие строки.
INSERT INTO projects (id, user_id, title, description, status, created_at)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   '11111111-1111-1111-1111-111111111111',
   'Мониторинг птиц Кузьминского парка',
   'Ежегодный учёт видового состава птиц: кормушки, водопои, гнездовые участки.',
   'active',
   NOW() - INTERVAL '90 days'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
   '11111111-1111-1111-1111-111111111111',
   'Учёт опылителей на дачных участках',
   'Наблюдения за пчёлами и шмелями на любительских пасеках.',
   'active',
   NOW() - INTERVAL '30 days');

INSERT INTO tags (project_id, name)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'птицы'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Кузьминский парк'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'орнитология'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'насекомые'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'опылители');

-- Два задания. Требования первого содержат мета-метки [meta:require_photo] и
-- [meta:require_place], которые фронтенд использует для условного показа полей.
INSERT INTO missions (id, project_id, title, description, requirements, status, created_at)
VALUES
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'Наблюдение уток в пруду',
   'Опишите уток: вид, количество, поведение, место наблюдения.',
   'Обязательны фотографии[meta:require_photo]и указание места[meta:require_place]',
   'active',
   NOW() - INTERVAL '60 days'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbc',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'Подсчёт синиц на кормушке',
   'Отметьте все виды синиц и приведите число птиц.',
   NULL,
   'active',
   NOW() - INTERVAL '45 days');

COMMIT;

\echo 'projects_db: 2 проекта, 5 тегов, 2 задания.'
