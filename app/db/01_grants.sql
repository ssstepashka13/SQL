-- Права для app_user внутри inventorydb.
-- Запуск: psql -h 127.0.0.1 -U postgres -d inventorydb -f db/01_grants.sql

-- alembic хранит текущую ревизию в таблице в схеме public, а миграции мы
-- выполняем из-под app_user, поэтому даем ему право создавать объекты в public
GRANT CREATE ON SCHEMA public TO app_user;
