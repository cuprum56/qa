-- =============================================================================
-- Проверки users_db (U1...U7)
--
-- Seed-аккаунты, роли, хеши паролей, ограничение ролей и участия.
-- Следствия изоляции баз (FK на projects нет) вынесены в U7 как ручная сверка.
--
-- Запуск (из корня репозитория):
--   ./stand/up.sh backend
--   ./api/newman.sh
--   ./stand/up.sh psql users_db < sql/00-users-db.sql
--
-- Каждая проверка печатает строку вида:
--   [U1] OK ,  4 учётные записи с ожидаемыми ролями
--   [U5] ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-15 ,  1 запись с role=scientist
-- Слово "НАРУШЕНИЕ" означает расхождение, которое нужно завести баг-репортом.
-- Индекс всех проверок: sql/sql-queries.sql
-- =============================================================================

\echo ''


-- U1. Seed-аккаунты на месте, роли соответствуют замыслу.
--      Проверяет, что стенд собрался: без этих четырёх записей половина
--      сценариев коллекции не имеет от кого выполняться.
\echo ''
\echo '[U1] Seed-аккаунты и их роли'
SELECT 'U1' AS check,
       CASE WHEN COUNT(*) = 4 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ожидалось 4 учётные записи, найдено ' || COUNT(*)
       END AS verdict,
       string_agg(email || ' -> ' || role, ', ' ORDER BY email) AS detail
FROM users
WHERE id IN (
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333',
  '44444444-4444-4444-4444-444444444444'
);


-- U2. Пароли хранятся хешами bcrypt, а не открытым текстом.
--      Не "красивая" проверка: если бы в users.password_hash лежал сам пароль,
--      любая SQL-инъекция в любом сервисе дала бы все пароли сразу.
\echo ''
\echo '[U2] Хеши паролей - bcrypt, не открытый текст'
SELECT 'U2' AS check,
       CASE WHEN COUNT(*) FILTER (WHERE password_hash ~ '^\$2[aby]\$\d{2}\$') = COUNT(*)
             AND COUNT(*) FILTER (WHERE password_hash = 'Passw0rd') = 0
            THEN 'OK ,  все ' || COUNT(*) || ' паролей - bcrypt-хеши'
            ELSE 'НАРУШЕНИЕ: ' ||
                 COUNT(*) FILTER (WHERE password_hash NOT LIKE '$2%'
                                    OR password_hash = 'Passw0rd')
                 || ' записей без корректного bcrypt-хеша'
       END AS verdict,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE password_hash ~ '^\$2[aby]\$\d{2}\$') AS bcrypt_rows,
       COUNT(*) FILTER (WHERE password_hash = 'Passw0rd')            AS plaintext_rows
FROM users;


-- U3. Ограничение ролей применено.
--      Миграция user-service/migrations/0002_roles.sql добавляет CHECK. Без него
--      в базу попадёт любая строка - это и есть путь, которым API-15 получает
--      себе учёного.
\echo ''
\echo '[U3] CHECK-ограничение на допустимые роли существует'
SELECT 'U3' AS check,
       CASE WHEN COUNT(*) = 1 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: users_role_allowed_values отсутствует, роль не ограничена'
       END AS verdict
FROM pg_constraint
WHERE conname = 'users_role_allowed_values'
  AND contype = 'c';


-- U4. Посторонний пользователь не участвует в проекте.
--      Инвариант для всей матрицы прав в папке 02 Authorization. Если запись
--      появилась, сценарии проверки 403 потеряли бы смысл: посторонний
--      превратился бы в участника и получил бы 404 вместо 403.
\echo ''
\echo '[U4] stranger не является участником проекта aaaa...'
SELECT 'U4' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK ,  stranger остаётся посторонним'
            ELSE 'НАРУШЕНИЕ: stranger участвует в ' || COUNT(*) || ' проект(ах)'
       END AS verdict,
       COUNT(*) AS participations
FROM participations
WHERE user_id = '44444444-4444-4444-4444-444444444444';


-- U5. ДОКАЗАТЕЛЬСТВО ДЕФЕКТА API-15 - роль из тела запроса попала в БД.
--      Критичность в том, что подделать роль может любой, кто умеет
--      зарегистрироваться: код user-service/src/handlers/users.rs:94-102
--      берёт role из тела и пишет его без сверки, а доступ учёного даёт
--      project-service/src/middleware/auth.rs:32-34.
--
--      Сценарий: выполните папку "01 Auth" коллекции - запрос
--      "[KNOWN BUG] Register with role scientist -> 201" - затем выполните
--      этот запрос. Одна строка с role='scientist' у записи, созданной
--      публичной регистрацией, подтверждает дефект на уровне данных.
--      Если строк нет - либо дефект исправлен (закройте API-15 и перепишите
--      сценарий), либо автотесты не выполнялись.
\echo ''
\echo '[U5] ДОКАЗАТЕЛЬСТВО ,  API-15 ,  роль scientist у публично зарегистрированных'
SELECT 'U5' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'дефект не воспроизведён: роль из тела не сохранилась'
            ELSE 'ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-15 ,  записей: ' || COUNT(*)
       END AS verdict,
       u.email, u.role, u.created_at
FROM users u
WHERE u.role = 'scientist'
  AND u.email NOT IN ('scientist@seed.local')
  AND u.email NOT LIKE '%@seed.local'
ORDER BY u.created_at DESC;


-- U6. Участия уникальны: пара (пользователь, проект) встречается один раз.
--      Уникальный индекс должен страховать от дублей, но полезно убедиться,
--      что он вообще создан - иначе повторное вступление создаст вторую строку.
\echo ''
\echo '[U6] Нет повторных участий и участий на несуществующего пользователя'
SELECT 'U6' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' проблемных участий'
       END AS verdict,
       COUNT(*) AS broken
FROM (
  SELECT user_id, project_id
  FROM participations
  GROUP BY user_id, project_id
  HAVING COUNT(*) > 1
  UNION ALL
  SELECT p.id, NULL
  FROM participations p
  WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.id = p.user_id)
) duplicates_or_orphans;


-- U7. Ручная сверка: project_id из этой базы должен существовать в projects_db.
--      FK нет, вывести "нарушение" средствами SQL невозможно - сравните
--      список вручную с выводом P3.
\echo ''
\echo '[U7] Сверка вручную: project_id из users_db против projects_db'
SELECT 'U7' AS check,
       'СВЕРКА' AS verdict,
       p.project_id,
       CASE WHEN p.project_id IN (
         'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
         'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
       ) THEN 'есть в seed projects_db'
            ELSE 'НЕТ в seed projects_db - ссылка битая'
       END AS cross_db
FROM (SELECT DISTINCT project_id FROM participations) p
ORDER BY p.project_id;
