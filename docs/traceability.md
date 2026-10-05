# Трассируемость

Цепочка: требование -> чек-лист -> тест-кейс -> дефект -> артефакт (Newman или SQL). Документ
показывает, что ни один её конец не остался без проверки, а находка - без теста.

Матрица построена **по фактическим данным артефактов**: имена запросов сверены с
`api/postman_collection.json`, ID - с SQL, чек-листов и баг-репортов. Где связь отсутствует, стоит
"нет", а не приукрашивание.

## 1. Покрытие требований

Скоуп из [test-plan.md](test-plan.md#2-объём) без изменений. Формат: кейсы, дефекты,
автоматизация; разделы чек-листов опущены - они видны в самих чек-листах.

1. **Регистрация и авторизация.** TC-API-01...05, TC-UI-01...05; API-06, API-15, WEB-02, WEB-03, WEB-04, WEB-09.
2. **Ролевая модель.** TC-API-09, TC-API-15, TC-UI-07; API-05, API-10, API-15, WEB-07.
3. **Проекты.** TC-API-11...13, TC-UI-06; API-07, API-08, API-14, WEB-08.
4. **Задания (миссии).** Кейсов и дефектов нет; автотесты `05 Missions`.
5. **Наблюдения и модерация.** TC-API-14, TC-UI-08...10; API-07, API-13, WEB-01; SQL `[O4]`, `[O5]`, `[O9]`.
6. **Комментарии.** Кейсов нет; API-09; автотесты `08 Comments`, SQL `[O7]`, `[O8]`.
7. **Файлы.** TC-API-14; API-13; SQL `[O5]`, `[O6]`.
8. **Участие в проекте.** Кейсов нет; API-11; автотесты `09 Participations`, SQL `[U7]`.
9. **API: контракт и сеть.** TC-API-06, TC-API-07; API-01, API-03, API-04, API-12.
10. **Интерфейс и доступность.** TC-UI-11, TC-UI-12; WEB-05, WEB-06, WEB-10...13 и 19 находок.
11. **Персистентность в трёх БД.** Кейсов и дефектов нет; SQL, 25 проверок.

## 2. Семантика префикса `[KNOWN BUG]`

Запрос с префиксом `[KNOWN BUG]` **проверяет текущее ошибочное поведение**: на непочиненном коде он
**проходит**, после исправления дефекта - **падает**. Это единственное место, где "зелёный" отчёт и
"дефекты есть" - одно и то же, и её легко прочитать наоборот.

- Дефект на месте - в отчёте зелёный, ничего делать не нужно.
- Дефект исправлен - красный ровно в одном сценарии: переписать ожидание, снять префикс, закрыть баг-репорт.

`summarize.py` возвращает код `3`, чтобы "дефект починили" нельзя было спутать с регрессией; коды - в [metrics.md](metrics.md#6-коды-newman).

## 3. Папки коллекции -> дефекты и запросы

Формат: папка - всего запросов, из них помеченных `[KNOWN BUG]` - дефект и имена сценариев. Метки:
`API` - сценарий в коллекции, `SQL` - проверка в [sql/](../sql/sql-queries.sql).

- `01 Auth` - 15, 1: **API-15** - Register with role scientist -> 201.
- `02 Authorization` - 12, 6: **API-02** (5) - Anonymous read observations;
  Anonymous read observation detail; Anonymous read comments; Anonymous read files;
  Anonymous read participations. **API-15** (1) - Self-registered scientist creates project -> 201.
- `03 Users` - 5, 2: **API-10** - Public profile leaks email and phone;
  **API-12** - User projects without Content-Type.
- `04 Projects` - 18, 6: **API-06** (1) - Create project. Title 256 chars -> 500; **API-07** (3) -
  Create project. Empty title -> 201; Create project. Arbitrary status; PUT behaves as PATCH;
  **API-08** (1) - by_tags POST -> 405; **API-14** (1) - Filter title with LIKE wildcard.
- `05 Missions` - 4, ни одного: дефектов не заведено.
- `06 Observations` - 9, 3: **API-07** - Empty title accepted on create; Clear title on update;
  Empty PATCH by stranger -> 200.
- `07 Files` - 7, 1: **API-13** - Upload fake image with declared MIME.
- `08 Comments` - 7, 4: **API-09** - Empty comment accepted; Parent in another observation -> 400;
  Delete parent cascades replies; Reply is gone after cascade.
- `09 Participations` - 6, 1: **API-11** - Join non-existent project -> 201.
- `10 Contract` - 11, 7: **API-03** (4) - Malformed JWT -> 500; Expired token -> 500;
  Token with another secret -> 500; Token without exp -> 500; **API-12** (3) - Malformed JSON -> text/plain 400;
  Body over 20 MiB -> text/plain 413; Missing required field -> text/plain 400.

Итого 94 запроса, 31 помеченный, 12 закрытых дефектов; many-to-one - у API-02 пять анонимных
маршрутов, API-07 проявляется и в проектах, и в наблюдениях. **Без автотеста:** API-01 (во
frontend, Newman ходит на gateway `:8080`), API-04 (лимита частоты нет), API-05 (нужно понизить
роль в `users_db` между шагами, то есть `psql`).

## 4. SQL-проверки

Файлы: [users](../sql/00-users-db.sql), [projects](../sql/10-projects-db.sql),
[observations](../sql/20-observations-db.sql); 25 уникальных ID при 26 операторах.

- **users_db:** `[U1]` seed-аккаунты с ролями, `[U2]` пароли как bcrypt, `[U3]` CHECK на роли,
  `[U4]` `stranger` не участник, `[U5]` роль `scientist` у публичного регистра, `[U6]` пара
  "пользователь, проект" один раз, `[U7]` `project_id` есть в `projects_db`.
- **projects_db:** `[P1]` `tags` удалена миграцией, `[P2]` теги уникальны по `lower(name)`, `[P3]`
  задание принадлежит проекту, `[P4]` `user_id` есть в `users_db`, `[P5]` есть задание с
  `[meta:require_photo]`, `[P6]` у каждого проекта есть тег.
- **observations_db:** `[O1]` `user_id` и `mission_id` существуют, `[O2]` комментарий не свой
  родитель, `[O3]` ответ внутри наблюдения, `[O4]` у одобренного есть файл, `[O5]`, `[O5b]`
  `object_key` от id наблюдения, `[O6]`, `[O6b]` поддельный MIME сохранён, `[O7]` комментарий из
  пробелов сохранён, `[O8]`, `[O8b]` каскад ответов, `[O9]` два одинаковых наблюдения.

**Доказательства дефектов:** API-09 - `[O7]`, `[O8]`, `[O8b]`; API-11 - `[U7]`; API-13 - `[O6]`, `[O6b]`;
API-15 - `[U5]`; WEB-01 - `[O9]`. У API-02 его нет принципиально: анонимный доступ виден только
в запросах с чужим токеном, не в данных. Внешних ключей между базами нет, поэтому `[U7]`, `[P4]`
и `[O1]` - ручная сверка.

## 5. Чего не хватает и как перепроверить

**WEB: закрыт 1 из 13 дефектов.** Сценарий `02 Authorization / Create project as volunteer -> 403`
закрывает API-сторону WEB-07, но обход middleware на клиенте не покрыт ничем; TC-UI-03 закрывает
сразу WEB-03 и WEB-09. Остальные 12 находок живут в React: `localStorage`, переключатели, фокус
в модальном окне, связность `label`/`for`. Нужен Playwright или Cypress, а
[checklists/web](../checklists/web.md) фиксирует их как ручные проверки.

`python3 api/validate_collection.py` (94 запроса, 386 проверок, 31 `[KNOWN BUG]`) и
`APP_DIR=/путь/к/gra python3 stand/validate_seed.py`. ID дефекта должен совпадать в баг-репорте, чек-листе и здесь, каждый
`TC-*` - быть в поле **Кейсы** своего отчёта, числа в [metrics.md](metrics.md) - из тех же источников.