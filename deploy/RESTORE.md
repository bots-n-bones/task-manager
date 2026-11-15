# Восстановление таск-менеджера

Операции выполняются на VPS из /opt/team-task-manager. Снимок содержит database.dump, files.tar и manifest.json. Секреты из deploy/.env.production восстанавливаются отдельно из защищённой копии. Для нового VPS сначала установите Docker, перенесите исходники и конфигурацию, запустите db и выполните python3 deploy/bootstrap-db.py.

## Проверка снимка

Укажите полный путь нужного снимка. Проверка создаёт отдельную временную базу и каталог файлов, проверяет контрольные суммы, восстанавливает базу, распаковывает файлы и сравнивает их содержимое. Рабочие данные при этом сохраняются.

```sh
python3 deploy/verify-backup.py /opt/team-task-manager/backups/ИМЯ_СНИМКА
```

Успешная проверка создаёт restore-verified.json с количеством файлов и временем проверки.

## Возврат рабочего окружения к снимку

Этот шаг заменяет рабочую базу содержимым выбранного снимка. Сначала создайте свежую резервную копию для возможности вернуться к текущему состоянию.

```sh
python3 deploy/backup.py
docker compose --env-file deploy/.env.production -f deploy/supabase.yml -f deploy/compose.yml stop web bot gateway auth rest storage
docker cp /opt/team-task-manager/backups/ИМЯ_СНИМКА/database.dump deploy-db-1:/tmp/restore.dump
docker exec deploy-db-1 pg_restore -U postgres -d postgres --clean --if-exists --exit-on-error /tmp/restore.dump
docker run --rm --entrypoint tar -v deploy_files:/files -v /opt/team-task-manager/backups/ИМЯ_СНИМКА:/backup:ro nginx:alpine -C /files -xf /backup/files.tar
docker compose --env-file deploy/.env.production -f deploy/supabase.yml -f deploy/compose.yml up -d
```

Проверьте состояние контейнеров, HTTPS, вход, список задач, открытие вложения и журнал бота. Для возврата к состоянию перед восстановлением повторите процедуру с новой копией, созданной первым шагом.

Файлы с неизменяемыми путями из более поздних снимков могут физически остаться в томе, но доступ к ним определяется восстановленной базой и текущими правами. Их удаление выполняется отдельной процедурой очистки.

Снимки на том же VPS защищают от ошибок приложения и восстановления данных. Копия вне VPS необходима для восстановления после потери сервера. Первая внешняя копия хранится на Mac владельца в .local/backups проекта. Постоянное внешнее хранилище и срок хранения ожидают согласования.
