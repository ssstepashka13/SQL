-- Роли postgres для приложения. Управление ролями идет не через миграции,
-- а из-под суперпользователя.
-- Выполнять ДО alembic upgrade head: миграция с грантами ссылается на эти роли.
-- Запуск: psql -h 127.0.0.1 -U postgres -f db/02_roles.sql

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'catalog_manager') THEN
        CREATE ROLE catalog_manager WITH LOGIN PASSWORD '123456';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sales_manager') THEN
        CREATE ROLE sales_manager WITH LOGIN PASSWORD '123456';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supervisor') THEN
        CREATE ROLE supervisor WITH LOGIN PASSWORD '123456';
    END IF;
END
$$;

-- supervisor получает все возможности обеих ролей через членство
GRANT catalog_manager TO supervisor;
GRANT sales_manager TO supervisor;
