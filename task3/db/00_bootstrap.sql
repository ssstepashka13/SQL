-- База данных и пользователь приложения.
-- Запуск: psql -h 127.0.0.1 -U postgres -f db/00_bootstrap.sql

-- пользователь приложения (пароль как в src/db.py)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user WITH LOGIN PASSWORD 'pass';
    END IF;
END
$$;

CREATE DATABASE inventorydb OWNER postgres;

-- схемы catalog и sales создаем миграциями из-под app_user, поэтому нужно право
-- создавать объекты в базе
GRANT CREATE ON DATABASE inventorydb TO app_user;
