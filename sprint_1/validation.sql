-- Выполнять после project.sql. Проверки только читают данные.
-- Все восемь строк должны иметь actual = expected.
SELECT 'raw_sales' AS object_name, count(*) AS actual, 1000 AS expected FROM raw_data.sales
UNION ALL SELECT 'countries', count(*), 4 FROM car_shop.countries
UNION ALL SELECT 'brands', count(*), 7 FROM car_shop.brands
UNION ALL SELECT 'models', count(*), 19 FROM car_shop.models
UNION ALL SELECT 'colors', count(*), 8 FROM car_shop.colors
UNION ALL SELECT 'cars', count(*), 152 FROM car_shop.cars
UNION ALL SELECT 'customers', count(*), 894 FROM car_shop.customers
UNION ALL SELECT 'sales', count(*), 1000 FROM car_shop.sales;

-- Нормализованная БД должна восстановить каждую исходную продажу.
-- EXCEPT ALL сохраняет кратность повторных покупок. Ожидается 0 расхождений.
WITH original AS (
    SELECT auto, gasoline_consumption, round(price, 2) AS price, sale_date,
           person_name, phone, discount, brand_origin
    FROM raw_data.sales
), restored AS (
    SELECT b.brand_name || ' ' || m.model_name || ', ' || color.color_name AS auto,
           m.gasoline_consumption, s.price, s.sale_date,
           customer.person, customer.phone, s.discount, country.country_name
    FROM car_shop.sales AS s
    JOIN car_shop.cars AS c USING (car_id)
    JOIN car_shop.models AS m USING (model_id)
    JOIN car_shop.brands AS b USING (brand_id)
    JOIN car_shop.colors AS color USING (color_id)
    JOIN car_shop.customers AS customer USING (customer_id)
    LEFT JOIN car_shop.countries AS country USING (country_id)
), missing AS (
    SELECT * FROM original EXCEPT ALL SELECT * FROM restored
), extra AS (
    SELECT * FROM restored EXCEPT ALL SELECT * FROM original
)
SELECT (SELECT count(*) FROM missing) AS missing_rows,
       (SELECT count(*) FROM extra) AS extra_rows;

-- Каждый первичный ключ нормализованного слоя должен быть IDENTITY.
-- Ожидается 7 строк с is_identity = YES.
SELECT table_name, column_name, is_identity
FROM information_schema.columns
WHERE table_schema = 'car_shop' AND column_name IN (
    'country_id', 'brand_id', 'model_id', 'color_id',
    'car_id', 'customer_id', 'sale_id'
) AND is_identity = 'YES'
ORDER BY table_name;
