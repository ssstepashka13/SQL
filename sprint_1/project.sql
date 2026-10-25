-- Автосалон «Врум-Бум». Выполнять в заранее созданной БД sprint_1.
-- Исходный cars.csv должен находиться на сервере PostgreSQL по пути /tmp/cars.csv.
-- Скрипт рассчитан на пустую БД: существующие данные он не удаляет.
BEGIN;

CREATE SCHEMA raw_data;
CREATE TABLE raw_data.sales (
    id integer PRIMARY KEY, -- Идентификатор покупки из CSV; не генерируем заново.
    auto varchar(100) NOT NULL, -- Составное название из букв, цифр и разделителей.
    gasoline_consumption numeric, -- Сохраняем исходную точность; NULL для электромобилей.
    price numeric NOT NULL, -- В сыром слое сохраняем все исходные десятичные знаки.
    sale_date date NOT NULL, -- В источнике есть только календарная дата покупки.
    person_name varchar(100) NOT NULL, -- Имя может состоять из нескольких слов.
    phone varchar(50) NOT NULL, -- Телефон содержит +, скобки, дефисы и добавочный номер.
    discount smallint NOT NULL, -- Целое число процентов, достаточно диапазона smallint.
    brand_origin varchar(50) -- Страна может состоять из нескольких слов или быть неизвестна.
);

COPY raw_data.sales (id, auto, gasoline_consumption, price, sale_date,
                     person_name, phone, discount, brand_origin)
FROM '/tmp/cars.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', NULL 'null', ENCODING 'UTF8');

CREATE SCHEMA car_shop;

CREATE TABLE car_shop.countries (
    country_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоинкрементный суррогатный ключ.
    country_name varchar(50) NOT NULL UNIQUE -- Текстовое название страны, включая пробелы.
);

CREATE TABLE car_shop.brands (
    brand_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоинкрементный ключ бренда.
    brand_name varchar(50) NOT NULL UNIQUE, -- Бренд может содержать буквы и цифры.
    country_id integer REFERENCES car_shop.countries(country_id) -- Ключ страны; NULL означает неизвестное происхождение.
);

CREATE TABLE car_shop.models (
    model_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоинкрементный ключ модели.
    brand_id integer NOT NULL REFERENCES car_shop.brands(brand_id), -- Целочисленный внешний ключ бренда.
    model_name varchar(100) NOT NULL, -- Название модели может состоять из нескольких слов и цифр.
    gasoline_consumption numeric(3, 1) CHECK (gasoline_consumption >= 0), -- До 99.9 л/100 км; NULL для электромобилей.
    UNIQUE (brand_id, model_name)
);

CREATE TABLE car_shop.colors (
    color_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоинкрементный ключ цвета.
    color_name varchar(30) NOT NULL UNIQUE -- Одно текстовое название цвета.
);

CREATE TABLE car_shop.cars (
    car_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Ключ варианта «модель + цвет», без VIN в исходных данных.
    model_id integer NOT NULL REFERENCES car_shop.models(model_id), -- Целочисленный ключ модели.
    color_id integer NOT NULL REFERENCES car_shop.colors(color_id), -- Целочисленный ключ цвета.
    UNIQUE (model_id, color_id)
);

CREATE TABLE car_shop.customers (
    customer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Автоинкрементный ключ покупателя.
    person varchar(100) NOT NULL, -- Полное имя; одинаковые имена не запрещены.
    phone varchar(50) NOT NULL UNIQUE -- Стабильный телефон идентифицирует покупателя; сохраняем формат.
);

CREATE TABLE car_shop.sales (
    sale_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, -- Собственный автоинкремент, не копия исходного id.
    car_id integer NOT NULL REFERENCES car_shop.cars(car_id), -- Целочисленный ключ варианта автомобиля.
    customer_id integer NOT NULL REFERENCES car_shop.customers(customer_id), -- Целочисленный ключ покупателя.
    sale_date date NOT NULL, -- Дата продажи без времени суток.
    price numeric(9, 2) NOT NULL CHECK (price > 0), -- Точная денежная сумма до 9 999 999.99, уже со скидкой.
    discount smallint NOT NULL CHECK (discount BETWEEN 0 AND 99) -- Целый процент; 100% исключён для восстановления исходной цены.
);

-- В исходном файле одно потребление на модель и одна страна на бренд.
-- Неизвестную страну Porsche не подменяем предположением; сохраняем NULL.
INSERT INTO car_shop.countries (country_name)
SELECT DISTINCT brand_origin FROM raw_data.sales
WHERE brand_origin IS NOT NULL ORDER BY brand_origin;

INSERT INTO car_shop.brands (brand_name, country_id)
SELECT DISTINCT split_part(s.auto, ' ', 1), c.country_id
FROM raw_data.sales AS s
LEFT JOIN car_shop.countries AS c ON c.country_name = s.brand_origin
ORDER BY 1;

INSERT INTO car_shop.models (brand_id, model_name, gasoline_consumption)
SELECT DISTINCT b.brand_id,
       substr(split_part(s.auto, ',', 1), strpos(s.auto, ' ') + 1),
       s.gasoline_consumption
FROM raw_data.sales AS s
JOIN car_shop.brands AS b ON b.brand_name = split_part(s.auto, ' ', 1)
ORDER BY 1, 2;

INSERT INTO car_shop.colors (color_name)
SELECT DISTINCT trim(split_part(auto, ',', 2))
FROM raw_data.sales ORDER BY 1;

INSERT INTO car_shop.cars (model_id, color_id)
SELECT DISTINCT m.model_id, c.color_id
FROM raw_data.sales AS s
JOIN car_shop.brands AS b ON b.brand_name = split_part(s.auto, ' ', 1)
JOIN car_shop.models AS m
  ON m.brand_id = b.brand_id
 AND m.model_name = substr(split_part(s.auto, ',', 1), strpos(s.auto, ' ') + 1)
JOIN car_shop.colors AS c ON c.color_name = trim(split_part(s.auto, ',', 2))
ORDER BY 1, 2;

INSERT INTO car_shop.customers (person, phone)
SELECT DISTINCT person_name, phone FROM raw_data.sales ORDER BY phone;

INSERT INTO car_shop.sales (car_id, customer_id, sale_date, price, discount)
SELECT car.car_id, customer.customer_id, s.sale_date, s.price, s.discount
FROM raw_data.sales AS s
JOIN car_shop.brands AS b ON b.brand_name = split_part(s.auto, ' ', 1)
JOIN car_shop.models AS m
  ON m.brand_id = b.brand_id
 AND m.model_name = substr(split_part(s.auto, ',', 1), strpos(s.auto, ' ') + 1)
JOIN car_shop.colors AS c ON c.color_name = trim(split_part(s.auto, ',', 2))
JOIN car_shop.cars AS car ON car.model_id = m.model_id AND car.color_id = c.color_id
JOIN car_shop.customers AS customer ON customer.phone = s.phone
ORDER BY s.id;

COMMIT;

-- Задание 1. Доля моделей, а не продаж или цветовых вариантов.
SELECT round(100.0 * count(*) FILTER (WHERE gasoline_consumption IS NULL)
             / NULLIF(count(*), 0), 2) AS nulls_percentage_gasoline_consumption
FROM car_shop.models;

-- Задание 2. Цена в sales уже содержит скидку: повторно её не применяем.
-- Выводим все годы 2015-2023 из задания, даже если продаж в году нет.
-- В исходном файле последняя продажа датирована 2022-12-30;
-- отсутствие средней цены за 2023 год обозначаем NULL, не фиктивным нулём.
WITH annual_prices AS (
    SELECT m.brand_id, extract(year FROM s.sale_date)::integer AS year,
           round(avg(s.price), 2) AS price_avg
    FROM car_shop.sales AS s
    JOIN car_shop.cars AS c USING (car_id)
    JOIN car_shop.models AS m USING (model_id)
    GROUP BY m.brand_id, extract(year FROM s.sale_date)
)
SELECT b.brand_name, y.year, p.price_avg
FROM car_shop.brands AS b
CROSS JOIN generate_series(2015, 2023) AS y(year)
LEFT JOIN annual_prices AS p ON p.brand_id = b.brand_id AND p.year = y.year
ORDER BY b.brand_name, y.year;

-- Задание 3. Средняя фактическая цена продажи по месяцам 2022 года.
SELECT extract(month FROM sale_date)::integer AS month,
       extract(year FROM sale_date)::integer AS year,
       round(avg(price), 2) AS price_avg
FROM car_shop.sales
WHERE sale_date >= DATE '2022-01-01' AND sale_date < DATE '2023-01-01'
GROUP BY extract(month FROM sale_date), extract(year FROM sale_date)
ORDER BY month;

-- Задание 4. Группируем по покупателю, сохраняем повторные покупки.
SELECT customer.person,
       string_agg(b.brand_name || ' ' || m.model_name, ', ') AS cars
FROM car_shop.sales AS s
JOIN car_shop.customers AS customer USING (customer_id)
JOIN car_shop.cars AS c USING (car_id)
JOIN car_shop.models AS m USING (model_id)
JOIN car_shop.brands AS b USING (brand_id)
GROUP BY customer.customer_id, customer.person
ORDER BY customer.person;

-- Задание 5. Восстанавливаем цену до скидки делением на (1 - скидка/100).
-- Неизвестная страна остаётся отдельной NULL-группой, её продажи не теряются.
SELECT country.country_name AS brand_origin,
       round(max(s.price / (1 - s.discount / 100.0)), 2) AS price_max,
       round(min(s.price / (1 - s.discount / 100.0)), 2) AS price_min
FROM car_shop.sales AS s
JOIN car_shop.cars AS c USING (car_id)
JOIN car_shop.models AS m USING (model_id)
JOIN car_shop.brands AS b USING (brand_id)
LEFT JOIN car_shop.countries AS country USING (country_id)
GROUP BY country.country_name
ORDER BY brand_origin NULLS LAST;

-- Задание 6. Считаем покупателей, а не покупки; строго префикс +1 из условия.
SELECT count(*) AS persons_from_usa_count
FROM car_shop.customers
WHERE phone LIKE '+1%';
