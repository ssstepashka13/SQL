-- Схема auth и таблица пользователей. По заданию auth не относится к домену
-- приложения и управляется извне, поэтому все делается из-под суперпользователя
-- и не через миграции.
-- Выполнять ДО alembic upgrade head: миграция orders.created_by ссылается
-- на auth.users и заполняет старые заказы первым пользователем из таблицы.
-- Запуск: psql -h 127.0.0.1 -U postgres -d inventorydb -f db/03_auth.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id       serial PRIMARY KEY,
    username text NOT NULL UNIQUE,
    password text NOT NULL,
    role     text NOT NULL CHECK (role IN ('catalog_manager', 'sales_manager'))
);

-- читать auth должны все роли, в том числе будущие
GRANT USAGE ON SCHEMA auth TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA auth TO PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT SELECT ON TABLES TO PUBLIC;

-- миграции (app_user) ссылаются на users через внешний ключ orders.created_by
GRANT REFERENCES ON auth.users TO app_user;

INSERT INTO auth.users (username, password, role) VALUES
    ('cat_man', crypt('123456', gen_salt('bf')), 'catalog_manager'),
    ('sale_man', crypt('123456', gen_salt('bf')), 'sales_manager')
ON CONFLICT (username) DO NOTHING;
