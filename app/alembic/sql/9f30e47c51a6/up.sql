-- В таблице уже могут быть заказы, поэтому в три шага:
-- сначала колонка допускает NULL, потом старые заказы получают первого
-- пользователя, и только затем включается NOT NULL.
ALTER TABLE sales.orders
    ADD COLUMN created_by integer REFERENCES auth.users (id);

UPDATE sales.orders
SET created_by = (SELECT min(id) FROM auth.users)
WHERE created_by IS NULL;

ALTER TABLE sales.orders
    ALTER COLUMN created_by SET NOT NULL;
