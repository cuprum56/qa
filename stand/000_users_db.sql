-- =============================================================================
-- Seed-данные тестового стенда - users_db
--
-- Скрипт рассчитан на схему, созданную миграциями сервиса, без изменений:
--   user-service/migrations/0001_init.sql
--   user-service/migrations/0002_roles.sql
--
-- Запуск - из stand/up.sh, файл подаётся в psql через stdin:
--   docker compose exec -T users-db psql -U postgres -d users_db \
--     -v ON_ERROR_STOP=1 < stand/000_users_db.sql
--
-- Идентификаторы фиксированы, чтобы api/postman_collection.json и
-- sql/sql-queries.sql ссылались на одни и те же строки.
--
-- Пароль всех учётных записей: Passw0rd (8 символов; валидатор 6...72 байта,
-- user-service/src/handlers/users.rs:83,88). Хеш - bcrypt, префикс $2b$,
-- cost 12 (DEFAULT_COST в сервисах). Перегенерировать:
--
--   python3 -c "import bcrypt; print(bcrypt.hashpw(b'Passw0rd', \
--     bcrypt.gensalt(rounds=12, prefix=b'2b')).decode())"
--
-- Один хеш на все учётные записи: соль хранится внутри хеша, поэтому пароль
-- проверяется одинаково, а стенд остаётся воспроизводимым.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

DELETE FROM participations;
DELETE FROM users;

INSERT INTO users (id, email, password_hash, first_name, last_name, phone, role, description)
VALUES
  ('11111111-1111-1111-1111-111111111111',
   'scientist@seed.local',
   '$2b$12$bZ3T/.YnV9cAc5tlX2Gf8u6Ts4erMzDBeMTm0pyzAiYYv2hHpX1fa',
   'Ирина', 'Соколова', '+7-900-000-00-01', 'scientist',
   'Орнитолог, 12 лет наблюдений за птицами Кузьминского парка.'),

  ('22222222-2222-2222-2222-222222222222',
   'volunteer@seed.local',
   '$2b$12$bZ3T/.YnV9cAc5tlX2Gf8u6Ts4erMzDBeMTm0pyzAiYYv2hHpX1fa',
   'Анна', 'Волкова', '+7-900-000-00-02', 'volunteer',
   'Студентка, участвует с 2025 года.'),

  ('33333333-3333-3333-3333-333333333333',
   'admin@seed.local',
   '$2b$12$bZ3T/.YnV9cAc5tlX2Gf8u6Ts4erMzDBeMTm0pyzAiYYv2hHpX1fa',
   'Пётр', 'Администратор', '+7-900-000-00-03', 'admin',
   'Администратор площадки.'),

  ('44444444-4444-4444-4444-444444444444',
   'stranger@seed.local',
   '$2b$12$bZ3T/.YnV9cAc5tlX2Gf8u6Ts4erMzDBeMTm0pyzAiYYv2hHpX1fa',
   'Олег', 'Посторонний', '+7-900-000-00-04', 'volunteer',
   'Регистрируется по API для проверок прав доступа.');

-- Участие в основном проекте aaaaaaaa-aaaa-...:
--   - учёный    - владелец проекта
--   - волонтёр  - участник, ему принадлежит seed-наблюдение
--   - посторонний (stranger) намеренно НЕ участник: запросы к ресурсам проекта
--     от его имени должны давать 403, а не 404. Если бы он был участником,
--     сценарии проверки прав теряли бы смысл.
INSERT INTO participations (id, user_id, project_id)
VALUES
  ('11111111-aaaa-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('11111111-bbbb-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

COMMIT;

\echo 'users_db: 4 учётные записи, 2 участия. Пароль всех: Passw0rd'
