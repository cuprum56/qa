-- =============================================================================
-- Проверки observations_db (O1...O9)
--
-- Ссылки на другие базы, вложенность комментариев, object_key, каскады, дубликаты.
-- ВНИМАНИЕ: блок O4 удаляет данные. Он идёт последним и нужен только после
-- прогона автотестов - иначе стенд останется без наблюдения.
--
-- Запуск (из корня репозитория):
--   ./stand/up.sh backend
--   ./api/newman.sh
--   ./stand/up.sh psql observations_db < sql/20-observations-db.sql
--
-- Каждая проверка печатает строку вида:
--   [U1] OK ,  4 учётные записи с ожидаемыми ролями
--   [U5] ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-15 ,  1 запись с role=scientist
-- Слово "НАРУШЕНИЕ" означает расхождение, которое нужно завести баг-репортом.
-- Индекс всех проверок: sql/sql-queries.sql
-- =============================================================================

\echo ''


-- O1. Сверка вручную: user_id и mission_id наблюдений против других баз.
--      FK нет ни к пользователям, ни к заданиям. Это главный источник
--      "призрачных" данных: сервис примет observation с mission_id
--      00000000-0000-0000-0000-000000000000 и вернёт 201.
\echo ''
\echo '[O1] Сверка вручную: ссылки наблюдений против users_db и projects_db'
SELECT 'O1' AS check,
       'СВЕРКА' AS verdict,
       o.id AS observation_id,
       o.user_id,
       CASE WHEN o.user_id IN ('11111111-1111-1111-1111-111111111111',
                               '22222222-2222-2222-2222-222222222222')
            THEN 'пользователь есть в seed'
            ELSE 'пользователя нет в seed - ссылка битая' END AS user_check,
       o.mission_id,
       CASE WHEN o.mission_id LIKE 'bbbbbbbb-%' THEN 'задание есть в seed projects_db'
            ELSE 'задания нет в seed - ссылка битая' END AS mission_check
FROM observations o
ORDER BY o.created_at;


-- O2. Комментарий не является собственным родителем и глубина вложенности <= 1.
--      Фронтенд рисует ответы одним уровнем. Цикл parent_comment_id сделал бы
--      рекурсивный обход бесконечным.
\echo ''
\echo '[O2] Комментарии: нет циклов и самоссылок'
SELECT 'O2' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' комментариев ссылаются на себя'
       END AS verdict,
       COUNT(*) AS self_referencing
FROM observation_comments
WHERE parent_comment_id = id;


-- O3. Родитель комментария принадлежит тому же наблюдению.
--      FK на parent_comment_id есть, но на согласованность наблюдений FK
--      не смотрит: ответ может оказаться привязан к чужому наблюдению.
\echo ''
\echo '[O3] Родитель и ответ внутри одного наблюдения'
SELECT 'O3' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' ответов уехали в другое наблюдение'
       END AS verdict,
       c.id, c.observation_id, c.parent_comment_id, p.observation_id AS parent_observation
FROM observation_comments c
JOIN observation_comments p ON p.id = c.parent_comment_id
WHERE c.parent_comment_id IS NOT NULL
  AND c.observation_id <> p.observation_id;


-- O4. БИЗнес-ПРАВИЛО, а не дефект: одобренное наблюдение обязано иметь файл.
--      Минимум из UI-требований: без фотографии наблюдение нельзя
--      подтвердить. Проверяем seed и результаты прогона.
\echo ''
\echo '[O4] Одобренные наблюдения имеют хотя бы один файл'
SELECT 'O4' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' одобренных наблюдений без файлов'
       END AS verdict,
       o.id, o.title, o.status
FROM observations o
WHERE o.status = 'approved'
  AND NOT EXISTS (SELECT 1 FROM observation_files f WHERE f.observation_id = o.id);


-- O5. object_key начинается с id своего наблюдения.
--      Формат задаёт сервис при загрузке:
--      observation-service/src/storage.rs:69-79 строит
--      "{observation_id}/{uuid4}-{title}". Имя бакета в object_key не участвует.
--      Нарушение означает, что удаление наблюдения не найдёт свои файлы и
--      оставит мусор в бакете - либо удалит чужое.
\echo ''
\echo '[O5] object_key начинается с id его наблюдения'
SELECT 'O5' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK ,  формат соответствует storage.rs'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' файлов лежат не в своей папке'
       END AS verdict,
       f.id, f.object_key, f.observation_id
FROM observation_files f
WHERE f.object_key NOT LIKE f.observation_id::text || '/%';


-- O5b. Сверка: в object_key и url один и тот же ключ.
--       url = "{endpoint}/{bucket}/{object_key}". Колонка url при чтении
--       подменяется presigned-ссылкой (files.rs:229), поэтому в БД она нужна
--       только для целостности - и именно поэтому расхождение не видно через API.
\echo ''
\echo '[O5b] url заканчивается тем же object_key, что и хранится'
SELECT 'O5b' AS check,
       CASE WHEN COUNT(*) = 0 THEN 'OK'
            ELSE 'НАРУШЕНИЕ: ' || COUNT(*) || ' файлов с расхождением url и object_key'
       END AS verdict,
       f.id, f.object_key, f.url
FROM observation_files f
WHERE f.url NOT LIKE '%/' || f.object_key;


-- O6. Подделанный MIME-тип принят как файл (API-13).
--      Сервис берёт file_type из заголовка клиента (files.rs:96-97) и проверяет
--      только белый список строк, не содержимое. Сценарий коллекции
--      "07 Files / [KNOWN BUG] Upload fake image with declared MIME" грузит
--      api/fixtures/not-really.png - текстовый файл с именем .png - и получает
--      201 с file_type = image/png.
--
--      Проверить содержимое файла из SQL нельзя, и это само по себе важно:
--      object_key формируется из заголовка, а не из имени файла
--      (storage.rs:69-79), поэтому в базе нет ни расширения, ни иного следа
--      реального типа. Вторая половина проверки это и показывает.
--
--      Запустите сценарий из коллекции, затем этот запрос. Строка с
--      title = 'Фото птицы' означает, что не-изображение сохранено как image/png.
\echo ''
\echo '[O6] ДОКАЗАТЕЛЬСТВО ,  API-13 ,  не-изображение сохранено как image/png'
SELECT 'O4' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'следов поддельной загрузки нет (либо сценарий не выполнялся)'
            ELSE 'ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-13 ,  записей: ' || COUNT(*)
       END AS verdict,
       f.id, f.title, f.file_type, f.object_key, f.created_at
FROM observation_files f
WHERE f.title = 'Фото птицы'
ORDER BY f.created_at DESC;

\echo ''
\echo '[O6b] Факт: в object_key нет расширения - тип файла в БД нечем сверить'
SELECT 'O6b' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'ЗАМЕЧАНИЕ: все object_key с расширением, сверять file_type с содержимым возможно'
            ELSE 'СЛЕДСТВИЕ API-13: ' || COUNT(*) || ' из ' || (SELECT COUNT(*) FROM observation_files)
                 || ' файлов без расширения в object_key, сверить file_type с содержимым нельзя'
       END AS verdict,
       COUNT(*) AS files_without_extension
FROM observation_files
WHERE object_key !~ '\.[A-Za-z0-9]{1,5}$';


-- O7. Часть 1 дефекта API-09: комментарий из одних пробелов сохраняется.
--      Код observation-service/src/handlers/comments.rs:91 делает .trim(),
--      но не проверяет результат на пустоту. У наблюдений и при регистрации
--      такая проверка есть - здесь её нет.
\echo ''
\echo '[O7] ДОКАЗАТЕЛЬСТВО ,  API-09 ч.1 ,  комментарии из одних пробелов'
SELECT 'O5' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'дефект не воспроизведён: пустые комментарии отвергаются'
            ELSE 'ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-09 ч.1 ,  записей: ' || COUNT(*)
       END AS verdict,
       c.id, '[' || c.comment || ']' AS comment_brackets, length(c.comment) AS len
FROM observation_comments c
WHERE btrim(c.comment) = ''
ORDER BY c.created_at DESC;


-- O8. Часть 2 дефекта API-09: удаление родителя уничтожает ответы.
--      ВНИМАНИЕ: запрос удаляет данные. Выполнять только после api/newman.sh;
--      восстановление - ./stand/up.sh seed.
--
--      ON DELETE CASCADE в схеме есть (observation-service/migrations/0001_init.sql),
--      поэтому ответ исчезнет - и это и есть дефект: API не предупреждает
--      о потере ветки и не предлагает мягкого удаления.
\echo ''
\echo '[O8] ДОКАЗАТЕЛЬСТВО ,  API-09 ч.2 ,  каскадное удаление ответов'
SELECT 'O4' AS check,
       'до удаления' AS state,
       c.id,
       c.parent_comment_id,
       c.comment
FROM observation_comments c
WHERE c.id IN ('dddddddd-dddd-dddd-dddd-dddddddddddd',
               'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')
ORDER BY c.parent_comment_id NULLS FIRST;

\echo '--- удаляю родительский комментарий dddd... (восстановление: ./stand/up.sh seed) ---'
DELETE FROM observation_comments WHERE id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

\echo ''
\echo '[O8b] Проверка каскада: ответ eeee... должен исчезнуть вместе с родителем'
SELECT 'O6b' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  API-09 ч.2 ,  ответ потерян вместе с родителем'
            ELSE 'дефект не воспроизведён: ответ сохранился, ON DELETE CASCADE не сработал'
       END AS verdict,
       COUNT(*) AS replies_left
FROM observation_comments
WHERE id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';


-- O9. Дубликаты наблюдений от одного пользователя по одному заданию.
--      Дефект WEB-01: отправка отчёта неатомарна - если загрузка фото падает,
--      наблюдение уже создано, пользователь жмёт "отправить" ещё раз и
--      получает второе такое же наблюдение. Признак - два наблюдения одного
--      пользователя по одному заданию с одинаковым заголовком рядом по времени.
\echo ''
\echo '[O9] ДОКАЗАТЕЛЬСТВО ,  WEB-01 ,  дубликаты наблюдений'
SELECT 'O5' AS check,
       CASE WHEN COUNT(*) = 0
            THEN 'дубликатов нет (либо сценарий сбоя не выполнялся)'
            ELSE 'ДОКАЗАТЕЛЬСТВО ДЕФЕКТА ,  WEB-01 ,  групп: ' || COUNT(*)
       END AS verdict,
       d.user_id, d.mission_id, d.title, d.copies,
       d.first_created_at, d.last_created_at
FROM (
  SELECT user_id, mission_id, title,
         COUNT(*) AS copies,
         MIN(created_at) AS first_created_at,
         MAX(created_at) AS last_created_at
  FROM observations
  GROUP BY user_id, mission_id, title
  HAVING COUNT(*) > 1
) d
ORDER BY d.last_created_at DESC;
