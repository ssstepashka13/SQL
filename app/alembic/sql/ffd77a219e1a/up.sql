CREATE SCHEMA inventory;

-- маршруты перемещения товаров, определяются городами складов
CREATE TABLE inventory.routes (
    from_city_id    integer NOT NULL REFERENCES catalog.cities (id),
    to_city_id      integer NOT NULL REFERENCES catalog.cities (id),
    duration        interval       NOT NULL,
    total_threshold numeric(12, 2) NOT NULL CHECK (total_threshold >= 0),
    PRIMARY KEY (from_city_id, to_city_id),
    CHECK (from_city_id <> to_city_id)
);

-- остатки товаров по складам
CREATE TABLE inventory.stock (
    warehouse_id integer NOT NULL REFERENCES catalog.warehouses (id),
    product_id   integer NOT NULL REFERENCES catalog.products (id),
    quantity     integer NOT NULL CHECK (quantity >= 0),
    PRIMARY KEY (warehouse_id, product_id)
);

-- резервы товаров под заказы
CREATE TABLE inventory.reserves (
    id           serial PRIMARY KEY,
    order_id     integer NOT NULL REFERENCES sales.orders (id),
    product_id   integer NOT NULL REFERENCES catalog.products (id),
    warehouse_id integer NOT NULL REFERENCES catalog.warehouses (id),
    quantity     integer NOT NULL CHECK (quantity > 0),
    UNIQUE (order_id, product_id)
);

-- накладные на доставку заказа покупателю
CREATE TABLE inventory.deliveries (
    id         serial PRIMARY KEY,
    order_id   integer NOT NULL UNIQUE REFERENCES sales.orders (id),
    status     text NOT NULL DEFAULT 'planned'
               CHECK (status IN ('planned', 'shipping', 'shipped')),
    created_at timestamptz NOT NULL DEFAULT now(),
    shipped_at timestamptz
);

CREATE TABLE inventory.delivery_items (
    delivery_id integer NOT NULL REFERENCES inventory.deliveries (id) ON DELETE CASCADE,
    product_id  integer NOT NULL REFERENCES catalog.products (id),
    quantity    integer NOT NULL CHECK (quantity > 0),
    status      text NOT NULL DEFAULT 'planned'
                CHECK (status IN ('planned', 'shipped')),
    PRIMARY KEY (delivery_id, product_id)
);

-- накладные на перемещение товаров между складами
CREATE TABLE inventory.transfers (
    id                serial PRIMARY KEY,
    from_warehouse_id integer NOT NULL REFERENCES catalog.warehouses (id),
    to_warehouse_id   integer NOT NULL REFERENCES catalog.warehouses (id),
    status            text NOT NULL DEFAULT 'planned'
                      CHECK (status IN ('planned', 'shipping', 'in_transit',
                                        'arrived', 'received')),
    total_amount      numeric(12, 2) NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),
    started_at        timestamptz,
    arriving_at       timestamptz,
    received_at       timestamptz,
    CHECK (from_warehouse_id <> to_warehouse_id)
);

CREATE TABLE inventory.transfer_items (
    id           serial PRIMARY KEY,
    transfer_id  integer NOT NULL REFERENCES inventory.transfers (id) ON DELETE CASCADE,
    product_id   integer NOT NULL REFERENCES catalog.products (id),
    -- резерв, ради которого запрошен товар; NULL значит перемещение "прозапас"
    reserve_id   integer REFERENCES inventory.reserves (id),
    quantity     integer NOT NULL CHECK (quantity > 0),
    requested_by integer NOT NULL REFERENCES auth.users (id),
    status       text NOT NULL DEFAULT 'planned'
                 CHECK (status IN ('planned', 'shipped', 'received'))
);

-- заказ берет в обработку конкретный inventory_manager
ALTER TABLE sales.orders
    ADD COLUMN processing_by integer REFERENCES auth.users (id);

-- права inventory_manager: все на inventory, чтение sales, обновление статуса заказа
GRANT USAGE ON SCHEMA inventory TO inventory_manager;
GRANT ALL ON ALL TABLES IN SCHEMA inventory TO inventory_manager;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA inventory TO inventory_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory GRANT ALL ON TABLES TO inventory_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory GRANT USAGE, SELECT ON SEQUENCES TO inventory_manager;

GRANT USAGE ON SCHEMA sales TO inventory_manager;
GRANT SELECT ON ALL TABLES IN SCHEMA sales TO inventory_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT SELECT ON TABLES TO inventory_manager;
GRANT UPDATE (status, processing_by) ON sales.orders TO inventory_manager;

-- права worker: читать inventory, весь stock, обновлять резервы и статусы с датами
GRANT USAGE ON SCHEMA inventory TO worker;
GRANT SELECT ON ALL TABLES IN SCHEMA inventory TO worker;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory GRANT SELECT ON TABLES TO worker;
GRANT SELECT, INSERT, UPDATE, DELETE ON inventory.stock TO worker;
GRANT UPDATE (quantity) ON inventory.reserves TO worker;
GRANT UPDATE (status, shipped_at) ON inventory.deliveries TO worker;
GRANT UPDATE (status) ON inventory.delivery_items TO worker;
GRANT UPDATE (status, started_at, arriving_at, received_at) ON inventory.transfers TO worker;
GRANT UPDATE (status) ON inventory.transfer_items TO worker;
