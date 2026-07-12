-- Роли postgres для инвентаризации. Как и остальные роли, создаются
-- из-под суперпользователя, не через миграции.
-- Выполнять ДО alembic upgrade head: миграция с грантами ссылается на эти роли.
-- Запуск: psql -h 127.0.0.1 -U postgres -f db/04_inventory_roles.sql

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inventory_manager') THEN
        CREATE ROLE inventory_manager WITH LOGIN PASSWORD '123456';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'worker') THEN
        CREATE ROLE worker WITH LOGIN PASSWORD '123456';
    END IF;
END
$$;
