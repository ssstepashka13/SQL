"""Начальная схема: product_categories, products, warehouses."""

from alembic import op

# revision identifiers, used by Alembic.
revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE catalog.product_categories (
            id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name text NOT NULL UNIQUE
        )
        """
    )

    op.execute(
        """
        CREATE TABLE catalog.products (
            id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            sku         varchar(30)    NOT NULL UNIQUE,
            name        text           NOT NULL CHECK (length(btrim(name)) > 0),
            price       numeric(12, 2) NOT NULL CHECK (price > 0),
            category_id integer        NOT NULL
                REFERENCES catalog.product_categories (id)
                ON DELETE RESTRICT
        )
        """
    )

    op.execute(
        """
        CREATE TABLE catalog.warehouses (
            id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            city       text    NOT NULL CHECK (length(btrim(city)) > 0),
            address    text    NOT NULL CHECK (length(btrim(address)) > 0),
            label      text,
            is_central boolean NOT NULL DEFAULT false
        )
        """
    )

    # не более одного центрального склада
    op.execute(
        """
        CREATE UNIQUE INDEX warehouses_single_central_idx
            ON catalog.warehouses (is_central)
            WHERE is_central
        """
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS catalog.products")
    op.execute("DROP TABLE IF EXISTS catalog.warehouses")
    op.execute("DROP TABLE IF EXISTS catalog.product_categories")
