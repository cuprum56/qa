-- =============================================================================
-- Проверки projects_db (P1...P6)
--
-- Миграция тегов, уникальность тегов, принадлежность заданий и владелец проекта.
-- P4 - ручная сверка user_id против users_db: внешнего ключа нет.
--
-- Запуск (из корня репозитория):
--   ./stand/up.sh backend
--   ./api/newman.sh
--   ./stand/up.sh psql projects_db < sql/10-projects-db.sql
--
-- Каждая проверка печатает строку вида:
--   [U1] OK ,  4 учётные записи с ожидаемыми ролями
--   [U5] ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-15 ,  1 запись с role=scientist
-- Слово "НАРУШЕНИЕ" означает расхождение, которое нужно завести баг-репортом.
-- Индекс всех проверок: sql/sql-queries.sql
-- =============================================================================

\echo ''


-- P1. Миграция 0002_tags_table.sql применена: колонка projects.tags удалена,
--      теги лежат в отдельной таблице.
--      Если колонка ещё есть, seed со вставкой тегов в tags не пройдёт, а
--      поиск по тегам будет читать пустой массив и всегда возвращать 0 строк.
\echo ''
\echo '[P1] Колонка projects.tags удалена, теги в таблице tags'
SELECT 'P1' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK ,  теги нормализованы'
            ELSE 'НАРУШЕНИЕ: projects.tags ещё существует, миграция 0002 не применена'
       END AS verdict
FROM information_schema.columns
WHERE table_name = 'projects' AND column_name = 'tags';


-- P2. Теги уникальны в пределах проекта без учёта регистра.
--      Уникальный индекс idx_tags_project_lower_name обязан существовать:
--      иначе "Птицы" и "птицы" станут двумя разными тегами, а фильтр
--      по тегам вернёт дублированные проекты.
\echo ''
\echo '[P2] Теги проекта уникальны по lower(name)'
SELECT 'P2' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' пар тегов-дублей'
       END AS verdict,
       COUNT(*) AS duplicate_pairs
FROM (
  SELECT project_id, lower(name)
  FROM tags
  GROUP BY project_id, lower(name)
  HAVING COUNT(*) > 1
) d;


-- P3. Каждое задание принадлежит существующему проекту.
--      Здесь FK есть (missions.project_id REFERENCES projects(id)), поэтому
--      проверка настоящая: нарушение означает сломанную миграцию, а не
--      отсутствие ограничения.
\echo ''
\echo '[P3] Все задания привязаны к существующим проектам'
SELECT 'P3' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' заданий без проекта'
       END AS verdict,
       COUNT(*) AS orphans
FROM missions m
WHERE NOT EXISTS (SELECT 1 FROM projects p WHERE p.id = m.project_id);


-- P4. У каждого проекта есть владелец. FK на users нет, база другая.
--      Выводите user_id и сверяйте с пользователями из U1: значение должно
--      совпадать с id учёного 11111111-1111-1111-1111-111111111111.
\echo ''
\echo '[P4] Сверка вручную: user_id проектов против users_db'
SELECT 'P4' AS check,
       'СВЕРКА' AS verdict,
       p.id AS project_id,
       p.user_id,
       CASE WHEN p.user_id = '11111111-1111-1111-1111-111111111111'
            THEN 'владелец - seed-учёный'
            ELSE 'владелец другой: проверьте, что он есть в users_db'
       END AS cross_db
FROM projects p
ORDER BY p.created_at;


-- P5. Задание с обязательным фото существует.
--      Фикстура для UI-сценариев и для проверки бизнес-правила в P-вакансии:
--      наблюдение, прошедшее модерацию, обязано иметь файл. Нумерация
--      [meta:require_photo] используется фронтендом для условного показа поля.
\echo ''
\echo '[P5] Задание с мета-меткой [meta:require_photo] существует'
SELECT 'P5' AS check,
       CASE WHEN COUNT(*) > 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: нет задания с require_photo - UI-сценарии сломаны'
       END AS verdict,
       m.id AS mission_id, m.title, m.project_id
FROM missions m
WHERE m.requirements LIKE '%[meta:require_photo]%';


-- P6. У каждого проекта есть хотя бы один тег.
--      Мягкое правило, не дефект: проект без тегов не найдётся в фильтре
--      и выпадет из выдачи. Полезно как метрика качества наполнения.
\echo ''
\echo '[P6] Каждый проект имеет хотя бы один тег'
SELECT 'P6' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'ЗАМЕЧАНИЕ: ' || COUNT(*) || ' проект(ов) без тегов'
       END AS verdict,
       COUNT(*) AS projects_without_tags
FROM projects p
WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.project_id = p.id);
