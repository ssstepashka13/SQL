-- Схема catalog и права для app_user.
-- Запуск: psql -h 127.0.0.1 -U postgres -d inventorydb -f db/01_schema.sql

CREATE SCHEMA IF NOT EXISTS catalog AUTHORIZATION postgres;

-- доступ к самой схеме
GRANT USAGE ON SCHEMA catalog TO app_user;

-- права на уже созданные таблицы и последовательности
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA catalog TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA catalog TO app_user;

-- права на объекты, которые будут созданы в схеме позже (миграцией от postgres)
ALTER DEFAULT PRIVILEGES IN SCHEMA catalog
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA catalog
    GRANT USAGE, SELECT ON SEQUENCES TO app_user;
