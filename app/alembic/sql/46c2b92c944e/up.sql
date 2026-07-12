CREATE SCHEMA catalog;

CREATE TABLE catalog.product_categories (
    id   serial PRIMARY KEY,
    name text NOT NULL UNIQUE
);

CREATE TABLE catalog.products (
    id          serial PRIMARY KEY,
    sku         varchar(30)    NOT NULL UNIQUE,
    name        text           NOT NULL,
    price       numeric(12, 2) NOT NULL CHECK (price > 0),
    category_id integer        NOT NULL REFERENCES catalog.product_categories (id)
);

CREATE TABLE catalog.warehouses (
    id         serial  PRIMARY KEY,
    city       text    NOT NULL,
    address    text    NOT NULL,
    label      text,
    is_central boolean NOT NULL DEFAULT false
);

-- не более одного центрального склада
CREATE UNIQUE INDEX warehouses_single_central_idx
    ON catalog.warehouses (is_central) WHERE is_central;
