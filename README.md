# Team Task Manager

Локальный Telegram-бот для создания личных задач и отправки результата на проверку. Объём версии описан в [MVP](MVP.md). Полное целевое ТЗ — [SPEC.md](SPEC.md).

## Локальный Supabase

Требуются работающий Docker и Node.js 20+. CLI закреплён в package.json и package-lock.json; глобальная установка и облачный аккаунт не нужны.

```sh
npm ci
npm run db:start
npm run db:migrate
node scripts/local-env.mjs
```

Studio: http://127.0.0.1:54323

API: http://127.0.0.1:54321

Остановить с сохранением данных:

```sh
npm run db:stop
```

Не использовать `supabase stop --no-backup` или `db reset` для обычной остановки: они удаляют данные.

## Настройки

В `.env` заполнить `TELEGRAM_BOT_TOKEN` из BotFather. Локальные `SUPABASE_URL` и `SUPABASE_SECRET_KEY` заполняются из запущенного Supabase. Не заменять файл целиком при добавлении токена.

Обновить локальные ключи после пересоздания окружения: `node scripts/local-env.mjs`. Команда сохраняет Telegram-токен и не выводит секреты в терминал.

`.env` и `.local/` исключены из Git. В `.env.example` содержатся только имена переменных, без ключей. В TELEGRAM_ALLOWED_IDS перечислите разрешённые числовые Telegram ID через запятую. Пустой список закрывает доступ всем.

Для этого окружения отключены ненужные MVP сервисы Realtime, Edge Runtime, почтовый тестовый сервер и Analytics. Postgres, REST API, Auth, Storage и Studio доступны локально.

Окружение предназначено для разработки на этом компьютере. Для постоянной работы на VPS нужны отдельная конфигурация, секреты и резервное копирование; локальные ключи туда не переносятся.

Официальная инструкция: https://supabase.com/docs/guides/local-development/cli/getting-started


## Telegram-бот

После запуска базы и применения миграций выполните `npm start`. Держите один экземпляр бота запущенным на компьютере. После изменения .env перезапустите процесс. Остановка в терминале — Ctrl+C.

В личном чате отправьте `/start`, выберите «Создать задачу», введите название, описание и дату ДД.ММ.ГГГГ. После подтверждения откройте «Мои задачи». В карточке нажмите «Начать работу», затем «Добавить результат» и отправьте текст или ссылку. Задача перейдёт в «Ожидает проверки».

Команда `/start` восстанавливает текущий шаг формы. Для выхода используйте «Отмена» или `/cancel`. При временной ошибке соединения бот повторяет обработку события. Запись изменений и сохранение ответа для повторной доставки происходят в одной транзакции Postgres.


## Проверка результатов

Первый администратор — Илья, Telegram ID 1287414278. Роль хранится в users.role. Администратор открывает «Все задачи» и карточку задачи на проверке. «Подтвердить» переводит её в «Готово», «Вернуть в работу» запрашивает обязательную причину. Решения и изменения сохраняются в task_reviews и task_events. Кнопки проверки содержат версию задачи, устаревшее решение требует обновить карточку.

## Проекты и редактирование

В «Проектах» администратор создаёт проект и архивирует или восстанавливает существующий. Создатель проекта становится его первым ответственным администратором. Архивирование сохраняет задачи и закрывает выбор проекта для новых задач.

В карточке открытой задачи автор с доступом к ней и администратор видят «Редактировать». Форма позволяет изменить проект, название, описание, флаги, срок и состав исполнителей. При сохранении проверяются версия и актуальные права. Если параллельно задача изменилась, отмените форму и откройте актуальную карточку.

Результаты сохраняются версиями в task_results. Каждое решение в task_reviews ссылается на конкретный результат через result_id.

Проверка редактирования на локальной базе с откатом тестовых записей:

```sh
docker exec -i supabase_db_team-task-manager psql -X -v ON_ERROR_STOP=1 -U postgres < scripts/checks/edit-projects.sql
```

## Вложения результата

На шаге «Добавить результат» можно отправить текст, документ или фото. Файл до 10 МБ сохраняется в закрытом bucket task-results, подпись до 1000 символов становится текстом результата. Каждое сообщение с файлом отправляет отдельную версию результата на проверку. Кнопка вложения в карточке доступна после проверки текущего доступа. Повторная доставка события использует сохранённый ответ.

После возврата в работу новый результат сохраняется отдельной версией даже при одинаковом тексте. Решения администратора относятся к соответствующим версиям.

## Напоминания

Обработчик запускается вместе с ботом, проверяет очередь раз в минуту и работает после 09:00 Europe/Moscow. Для активных исполнителей из TELEGRAM_ALLOWED_IDS создаются напоминания на сегодня и одна сводка просрочки за день. Текущее назначение, срок и статус проверяются перед выдачей очередной отправки. После временных ошибок выполняется до пяти попыток. Блокировка Telegram отключает доставку до нового /start. Неопределённый ответ Telegram может привести к повторной доставке.

## Серверный API

Запуск локально: `npm run server`. По умолчанию API слушает 127.0.0.1:3000. APP_ORIGIN задаёт допустимый origin сайта, HOST и PORT — адрес прослушивания. При HTTPS cookie получает Secure. Маршруты текущего этапа: POST /api/login, POST /api/telegram, GET /api/me, POST /api/logout и GET /health.

Пароли проверяет Supabase Auth. Для логина без пользовательского email используется служебный адрес login@accounts.task-manager.internal, связь с профилем хранится в users.auth_id. Открытой регистрации в API нет. Выдача одноразового кода установки пароля и интерфейс сайта реализованы.

Сессия действует сутки. В базе хранится SHA-256 случайного токена, cookie имеет HttpOnly и SameSite=Strict. Состояние активности профиля проверяется при каждом запросе. Изменяющие запросы требуют APP_ORIGIN. Для входа действуют ограничения по IP и логину. Данные Telegram Mini App проверяются HMAC-SHA-256 и принимаются в пределах пяти минут после запуска.

Документация используемых протоколов: https://supabase.com/docs/reference/javascript/auth-signinwithpassword и https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app

## API задач

GET /api/tasks возвращает до 21 записи: двадцать для страницы и одну для признака продолжения. Фильтры — page, mine, project_id, status, important, quick, member и deadline (today, overdue или ISO-дата). GET /api/tasks/номер открывает карточку с текущей проверкой доступа. GET /api/projects и /api/members возвращают доступные справочники.

POST /api/tasks принимает action, data и requestId (UUID). Действия — create, edit, begin, result, approve, return, cancel. Для изменений существующей задачи передаются number и version. Один requestId используется для повторов одного действия. Успешный ответ сохраняется в одной транзакции с изменениями. При конфликте версии API возвращает HTTP 409, при запрете доступа — 403.

Создание принимает title, description, project_id, due_date (ISO), important, quick и assignees (UUID участников). Результат принимает text, возврат — comment. Сервер определяет действующего пользователя из сессии.

## Доступ к сайту

Администратор получает список профилей через GET /api/accounts и выдаёт вход существующему участнику через POST /api/accounts с userId и login. Логин — 3–32 символа, латиница в нижнем регистре, цифры, точка, дефис и подчёркивание. Ответ содержит login, code и type. Передайте участнику код установки пароля по выбранному вами каналу.

POST /api/setup принимает code, type и password (12–256 символов). Код Supabase Auth одноразовый. После установки участник входит через POST /api/login с логином и паролем. Повторная выдача доступа для того же логина формирует код восстановления. Если установка оборвалась после подтверждения кода, администратор выдаёт новый. После успешной установки прежние серверные сессии пользователя удаляются.

PATCH /api/accounts принимает userId и active и/или role (user/admin). Отключение профиля отзывает его серверные сессии. Последнего активного администратора отключить или понизить нельзя.

## Локальный веб-интерфейс

После `npm run server` откройте http://127.0.0.1:3000. Реализованы вход и установка пароля по коду, списки задач и фильтры, карточка, создание и редактирование, текстовый результат и решения администратора. Раздел «Участники» позволяет выдать доступ к сайту, поменять роль и активность профиля.

Веб-интерфейс использует серверные сессии и API того же проекта. В Mini App выполняется вход через подписанные Telegram initData. Загрузка файлов через веб, привязка профилей и публикация HTTPS реализованы.

## Файлы через сайт

В форме результата можно выбрать документ или фото до 10 МБ и добавить текст до 1000 символов. Файл сохраняется в закрытом Storage, результат и запись вложения фиксируются одной транзакцией. Повтор с тем же requestId возвращает сохранённый ответ. Кнопки скачивания в карточке каждый раз проверяют доступ.

POST /api/files передаёт бинарное содержимое, параметры number, version, requestId и заголовки X-File-Name, X-Caption (значения кодируются encodeURIComponent). GET /api/files/UUID отдаёт файл как скачивание после проверки текущих прав. GET /api/history/номер возвращает историю доступной задачи.

Загрузка объекта в Storage предшествует транзакции базы. Если сохранение в базе отклонено, в закрытом Storage может остаться непривязанный объект. Непривязанные загрузки старше суток автоматически очищаются. Сначала путь блокируется для привязки, затем через пять минут объект удаляется из Storage.

## Новые участники и привязка Telegram

Администратор добавляет профиль в разделе «Участники», затем выдаёт ему логин и код установки пароля. Telegram ID при создании профиля необязателен. Задачи и права связаны с UUID профиля, поэтому участник может работать на сайте до привязки Telegram.

Кнопка «Привязать Telegram» выдаёт команду /link с одноразовым кодом на 15 минут. Отправьте её боту из нужного Telegram-аккаунта. Новый код отменяет предыдущий. Повторное использование и просроченный код отклоняются, привязанный к другому Telegram профиль перепривязать этим способом нельзя.

Активные связанные профили допускаются в бот независимо от TELEGRAM_ALLOWED_IDS. Эта переменная сохраняет начальный доступ старых участников. Напоминания учитывают все активные связанные профили.

## Ответственные и проекты на сайте

В разделе «Проекты» администратор создаёт проекты, архивирует и восстанавливает их, выбирает одного или нескольких ответственных администраторов. Их состав копируется в новые задачи. При редактировании задачи администратор может назначить отдельный состав ответственных.

## Проверка VPS перед развёртыванием

10 ноября 2026 подтверждён доступ к Hostinger VPS srv1681126 (187.124.164.63), Ubuntu 24.04, Docker и Traefik. На момент проверки свободно около 5,8 ГБ диска, доступно около 1 ГБ памяти. На сервере работают другие проекты. После этой проверки окружение развёрнуто на tasks.molotilka.site. Данные перенесены, HTTPS и автоперезапуск настроены. Восстановление базы и файлов проверено в изолированном окружении.

## Контейнеры приложения

Dockerfile запускает сервер от непривилегированного пользователя. deploy/compose.yml содержит отдельные процессы сайта и бота с автоперезапуском, ограничением ресурсов и ротацией журналов. Домен публикации — tasks.molotilka.site. DNS на VPS подтверждён 10 ноября 2026.

Перед запуском нужен отдельный Supabase эксплуатации с резервным копированием. Заполните deploy/.env.production по примеру. Локальные ключи среды разработки не переносятся. Само приложение запускается командой docker compose -f deploy/compose.yml up -d --build. Перед запуском production-бота остановите локальный polling, чтобы избежать конфликта Telegram.

## Публикация на VPS

Сайт опубликован на https://tasks.molotilka.site. A-запись tasks указывает на 187.124.164.63. HTTPS обслуживает Traefik с сертификатом Let's Encrypt. В Telegram настроена кнопка меню «Задачи», открывающая Mini App.

Каталог проекта на VPS — /opt/team-task-manager. Используются оба файла Compose: deploy/supabase.yml и deploy/compose.yml, переменные — deploy/.env.production. Команды эксплуатации выполняются из каталога проекта с префиксом:

```sh
docker compose --env-file deploy/.env.production -f deploy/supabase.yml -f deploy/compose.yml
```

Добавьте ps для статуса, logs --tail 100 web bot для журнала, up -d --build web bot для обновления приложения. Локальный бот остановлен после переноса, рабочий polling выполняет deploy-bot-1 на VPS. Все контейнеры используют restart unless-stopped.

Снимок после переноса — backups/20261110T110049666982Z на VPS. Он восстановлен в отдельную временную базу, проверены таблицы приложения, Auth, Storage и целостность ссылок вложений. Копия сохранена на Mac в .local/backups. Секреты эксплуатации находятся отдельно в закрытом файле deploy/.env.production на VPS и .local/production.env на Mac.

Таймер task-manager-backup.timer запускает копирование ежедневно около 06:00 Москвы. Файлы снимка защищены правами владельца. Автоматическое удаление старых копий пока отключено. Срок хранения, целевое время восстановления и постоянное внешнее хранилище ожидают согласования.

## Конфликты и фильтры бота

Кнопки начала работы и добавления результата содержат версию карточки. Если задача изменилась, бот просит открыть её заново. Версия проверяется повторно при отправке текста или файла результата.

В списках администратора кнопка «Фильтры» позволяет выбрать статус, проект или исполнителя. Фильтр сохраняется в кнопках постраничного перехода.

## Срок формы и состав задачи

Незавершённая форма хранится семь дней с последнего изменения. После истечения срока /start открывает меню, старый шаг загрузки результата недоступен. После перезапуска в пределах срока форма восстанавливается.

Отложенные ограничения базы проверяют состав задачи при завершении транзакции. У задачи должен остаться хотя бы один исполнитель и ответственный администратор. Изменение роли назначенного ответственного требует сначала переназначить его обязанности.

Полная инструкция восстановления — [deploy/RESTORE.md](deploy/RESTORE.md). Проверка от 10 ноября 2026 включает распаковку контрольного файла Storage и сравнение его содержимого.


## Ответственные в боте

В списке проектов администратор нажимает «Ответственные» возле нужного проекта. В карточке открытой задачи доступна отдельная кнопка «Ответственные». Отметьте одного или нескольких администраторов и сохраните выбор. Пустой состав отклоняется. Устаревшая версия задачи требует заново открыть карточку.

Очистка Storage выполняется сервером раз в пять минут. Файлы с существующей связью с результатом сохраняются. Если загрузка уже помечена для очистки, отправьте файл новым сообщением или заново откройте форму сайта.

### Member projects, personal task archive and task navigation

Active members can create projects from Projects → Create project and choose an active responsible administrator. Creating a project does not change the creator’s role. Archiving projects, changing project administrators and deleting projects retain their existing administrator checks. Calls without an explicit administrator keep the existing self-assignment for administrators; member calls default to active administrators.

Archive is available to every signed-in user and lists only their assigned tasks in Done or Cancelled status. Its status filter contains only those two states. The server enforces this personal archive scope even for administrator accounts. Entering Archive clears filters from other tabs.

Task details include Back to the task list. Task history, editing, due-date changes and result entry include Back to the task details; Close and Escape follow the same return path for those nested views. The list filters and pagination are preserved when returning from task history.

Validation: `scripts/checks/member-projects-archive.sql` runs in a rolled-back transaction and checks member creation, administrator validation, unchanged role restrictions and personal archive isolation.

### Review feedback

When an administrator requests changes, a comment is mandatory. The assignee sees a Changes requested badge in the task list and a feedback panel near the top of task details with the administrator’s name, timestamp and comment. The underlying status remains In progress. Resubmit for review starts the next review cycle; the pending-changes badge clears and the previous feedback remains visible while awaiting review. Approval moves the task to Done. History includes all review decisions and comments, newest first, separately from general task changes. History reloads feedback when opened so it does not rely on a previously opened card’s snapshot.

The review summary is returned only through the existing task-access checks. No public read permission is granted on review data. `scripts/checks/review-feedback.sql` verifies a full two-round return/resubmission/approval flow, mandatory comments, retry idempotency and privacy in a rolled-back transaction. `scripts/checks/review-flow-preview.mjs` serves an isolated in-memory UI fixture for member/admin browser checks; it never connects to the production database or sends messages.

### Embedded-browser dialogs

Member creation, password recovery and task cancellation use the app’s HTML dialog rather than native JavaScript prompt/confirm windows, which are unsupported in some embedded browsers. The member form trims names and enforces a 120-character limit; failures are shown inside the form. New profiles still require the separate Invite member step. No invitation is sent automatically when a profile is created.

### Browser compatibility handling

Shared browser helpers in `web/browser.mjs` provide secure request IDs without relying exclusively on randomUUID, tolerate legacy theme listeners and normalize network/non-JSON response errors. Messages raised while a dialog is open are rendered inside that dialog. Expired-session errors preserve the current form and explain how to sign in again. Validation and remaining device-specific limits are documented in `BROWSER_COMPATIBILITY.md`.

### Delete members

Administrators can use Members → Delete for any member role, including their own profile, and confirm a different active administrator to take over remaining responsibilities. The last active administrator cannot be removed without another active administrator. An ordinary member cannot call the deletion endpoint.

Deletion revokes sessions and invitations immediately and removes the profile from Members. Open tasks with no other active assignee transfer to the chosen administrator; shared tasks retain their other active assignees. Project/task administrator responsibilities are transferred where needed. Completed/cancelled tasks, authorship, submissions and review comments retain their historical identities. Deleted profiles cannot be re-enabled or assigned new work. A newly invited profile can explicitly relink a former Telegram identity.

The historical profile is retained with deleted_at; its email/login/auth link is cleared. Supabase Auth login deletion is attempted immediately and recorded in a service-only cleanup queue for retry if Auth is temporarily unavailable. Access is denied throughout cleanup. Self-deletion also clears the session cookie.

Validation: `scripts/checks/delete-members.sql` uses a rolled-back transaction and tests role checks, deletion of members/admins/self, replacement validation, assignment transfer, preserved history, revoked sessions, repeat requests, reactivation denial and Telegram relinking. The core deletion checks run as service_role. `scripts/checks/member-login-cleanup.mjs` tests credential cleanup, retries and already-removed login records. No real member was deleted during implementation or UI verification.
