CREATE SCHEMA sales;

CREATE TABLE sales.orders (
    id           serial PRIMARY KEY,
    status       text NOT NULL DEFAULT 'unpublished'
                 CHECK (status IN ('unpublished', 'new', 'processing',
                                   'pending', 'packing', 'shipped')),
    total_amount numeric(12, 2) NOT NULL DEFAULT 0,
    created_at   timestamptz    NOT NULL DEFAULT now(),
    warehouse_id integer        NOT NULL REFERENCES catalog.warehouses (id)
);

-- order_item -- слабая сущность: идентифицируется заказом и товаром
CREATE TABLE sales.order_items (
    order_id   integer        NOT NULL REFERENCES sales.orders (id) ON DELETE CASCADE,
    product_id integer        NOT NULL REFERENCES catalog.products (id),
    price      numeric(12, 2) NOT NULL CHECK (price > 0),
    quantity   integer        NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);
