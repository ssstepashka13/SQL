-- Проект 2. Сеть ресторанов Gastro Hub.
-- Перед запуском восстановите исходный дамп в отдельную базу с PostGIS.
-- PostgreSQL 15+; public, cafe и raw_data уже созданы дампом.
-- Порядок: справочники -> периоды работы -> продажи -> отчёты.

BEGIN;

CREATE TYPE cafe.restaurant_type AS ENUM
    ('coffee_shop', 'restaurant', 'bar', 'pizzeria');

CREATE TABLE cafe.restaurants (
    restaurant_uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    restaurant_name TEXT NOT NULL UNIQUE,
    location public.geometry(POINT, 4326) NOT NULL,
    restaurant_type cafe.restaurant_type NOT NULL,
    menu JSONB NOT NULL CHECK (jsonb_typeof(menu) = 'object')
);

CREATE TABLE cafe.managers (
    manager_uuid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    manager_name TEXT NOT NULL,
    phone TEXT NOT NULL,
    UNIQUE (manager_name, phone)
);

CREATE TABLE cafe.restaurant_manager_work_dates (
    restaurant_uuid UUID NOT NULL REFERENCES cafe.restaurants(restaurant_uuid),
    manager_uuid UUID NOT NULL REFERENCES cafe.managers(manager_uuid),
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    PRIMARY KEY (restaurant_uuid, manager_uuid),
    CHECK (start_date <= end_date)
);

CREATE TABLE cafe.sales (
    date DATE NOT NULL,
    restaurant_uuid UUID NOT NULL REFERENCES cafe.restaurants(restaurant_uuid),
    avg_check NUMERIC(6,2) NOT NULL CHECK (avg_check >= 0),
    PRIMARY KEY (date, restaurant_uuid)
);

-- DISTINCT удаляет только повторы справочников, а не исходные продажи.
-- Долгота задаётся первой, широта второй; координаты источника в градусах.
INSERT INTO cafe.restaurants (restaurant_name, location, restaurant_type, menu)
SELECT DISTINCT s.cafe_name,
       public.ST_SetSRID(public.ST_MakePoint(s.longitude, s.latitude), 4326),
       s.type::cafe.restaurant_type,
       m.menu
FROM raw_data.sales AS s
JOIN raw_data.menu AS m ON m.cafe_name = s.cafe_name;

-- Однофамильцев не объединяем только по имени: сохраняем пару имя/телефон.
INSERT INTO cafe.managers (manager_name, phone)
SELECT DISTINCT manager, manager_phone
FROM raw_data.sales;

-- По условию каждая пара ресторан/менеджер имеет один непрерывный период.
-- Границы включительные, по первой и последней дате наблюдения в источнике.
INSERT INTO cafe.restaurant_manager_work_dates
    (restaurant_uuid, manager_uuid, start_date, end_date)
SELECT r.restaurant_uuid, m.manager_uuid,
       MIN(s.report_date), MAX(s.report_date)
FROM raw_data.sales AS s
JOIN cafe.restaurants AS r ON r.restaurant_name = s.cafe_name
JOIN cafe.managers AS m
  ON m.manager_name = s.manager AND m.phone = s.manager_phone
GROUP BY r.restaurant_uuid, m.manager_uuid;

INSERT INTO cafe.sales (date, restaurant_uuid, avg_check)
SELECT s.report_date, r.restaurant_uuid, s.avg_check
FROM raw_data.sales AS s
JOIN cafe.restaurants AS r ON r.restaurant_name = s.cafe_name;

CREATE INDEX restaurants_location_gist
    ON cafe.restaurants USING gist (location);
CREATE INDEX sales_restaurant_date_idx
    ON cafe.sales (restaurant_uuid, date);

COMMIT;

-- Задание 1. Ровно три заведения каждого типа по среднему дневному чеку.
-- При равенстве средних выбираем по названию; округляем после ранжирования.
CREATE VIEW cafe.top_restaurants AS
WITH average_checks AS (
    SELECT r.restaurant_uuid, r.restaurant_name, r.restaurant_type,
           AVG(s.avg_check) AS average_check
    FROM cafe.restaurants AS r
    JOIN cafe.sales AS s USING (restaurant_uuid)
    GROUP BY r.restaurant_uuid, r.restaurant_name, r.restaurant_type
), ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY restaurant_type
        ORDER BY average_check DESC, restaurant_name
    ) AS position
    FROM average_checks
)
SELECT restaurant_name, restaurant_type, ROUND(average_check, 2) AS avg_check
FROM ranked
WHERE position <= 3;

SELECT * FROM cafe.top_restaurants
ORDER BY restaurant_type, avg_check DESC, restaurant_name;

-- Задание 2. Динамика среднего дневного чека по годам без 2023 года.
-- Для первой даты нет предыдущего значения: сохраняем NULL.
-- Процент вычисляется до округления средних, деление на ноль защищено.
CREATE MATERIALIZED VIEW cafe.yearly_average_checks AS
WITH yearly AS (
    SELECT restaurant_uuid, EXTRACT(YEAR FROM date)::INTEGER AS year,
           AVG(avg_check) AS average_check
    FROM cafe.sales
    WHERE EXTRACT(YEAR FROM date) <> 2023
    GROUP BY restaurant_uuid, EXTRACT(YEAR FROM date)
), compared AS (
    SELECT *, LAG(average_check) OVER (
        PARTITION BY restaurant_uuid ORDER BY year
    ) AS previous_average_check
    FROM yearly
)
SELECT c.year, r.restaurant_name, r.restaurant_type,
       ROUND(c.average_check, 2) AS avg_check,
       ROUND(c.previous_average_check, 2) AS previous_avg_check,
       ROUND(100 * (c.average_check - c.previous_average_check)
             / NULLIF(c.previous_average_check, 0), 2) AS avg_check_change_pct
FROM compared AS c
JOIN cafe.restaurants AS r USING (restaurant_uuid);

SELECT * FROM cafe.yearly_average_checks
ORDER BY restaurant_name, year;

-- Задание 3. Первый менеджер -- назначение, а не смена: вычитаем единицу.
SELECT r.restaurant_name, COUNT(*) - 1 AS manager_changes
FROM cafe.restaurant_manager_work_dates AS w
JOIN cafe.restaurants AS r USING (restaurant_uuid)
GROUP BY r.restaurant_uuid, r.restaurant_name
ORDER BY manager_changes DESC, r.restaurant_name
LIMIT 3;

-- Задание 4. Считаем только пиццы, а не напитки; сохраняем все максимумы.
WITH pizza_counts AS (
    SELECT r.restaurant_uuid, r.restaurant_name,
           (SELECT COUNT(*) FROM jsonb_object_keys(r.menu -> 'Пицца')) AS pizza_count
    FROM cafe.restaurants AS r
    WHERE r.restaurant_type = 'pizzeria'
)
SELECT restaurant_name, pizza_count
FROM pizza_counts
WHERE pizza_count = (SELECT MAX(pizza_count) FROM pizza_counts)
ORDER BY restaurant_name;

-- Задание 5. Цена -- число, а не текст. При равных максимумах выводим все пиццы.
WITH pizzas AS (
    SELECT r.restaurant_uuid, r.restaurant_name,
           p.key AS pizza_name, p.value::NUMERIC AS price
    FROM cafe.restaurants AS r
    CROSS JOIN LATERAL jsonb_each_text(r.menu -> 'Пицца') AS p
    WHERE r.restaurant_type = 'pizzeria'
), ranked AS (
    SELECT *, DENSE_RANK() OVER (
        PARTITION BY restaurant_uuid ORDER BY price DESC
    ) AS price_position
    FROM pizzas
)
SELECT restaurant_name, 'Пицца'::TEXT AS dish_type, pizza_name, price
FROM ranked
WHERE price_position = 1
ORDER BY restaurant_name, pizza_name;

-- Задание 6. Глобально ближайшая пара одного типа, без самих себя и повторов.
-- geography даёт метры по поверхности Земли вместо расстояния в градусах.
SELECT r1.restaurant_name AS restaurant_1, r2.restaurant_name AS restaurant_2,
       r1.restaurant_type,
       public.ST_Distance(r1.location::public.geography,
                          r2.location::public.geography) AS distance
FROM cafe.restaurants AS r1
JOIN cafe.restaurants AS r2
  ON r1.restaurant_type = r2.restaurant_type
 AND r1.restaurant_name < r2.restaurant_name
ORDER BY distance, restaurant_1, restaurant_2
LIMIT 1;

-- Задание 7. LEFT JOIN учитывает районы без заведений.
-- ST_Covers включает границу района; каждый ресторан считается один раз в районе.
-- При равных количествах выбираем район по названию, чтобы получить ровно 2 строки.
WITH district_counts AS (
    SELECT d.id, d.district_name, COUNT(r.restaurant_uuid) AS restaurant_count
    FROM cafe.districts AS d
    LEFT JOIN cafe.restaurants AS r
      ON public.ST_Covers(d.district_geom, r.location)
    GROUP BY d.id, d.district_name
), extremes AS (
    (SELECT district_name, restaurant_count, 1 AS position
     FROM district_counts
     ORDER BY restaurant_count DESC, district_name LIMIT 1)
    UNION ALL
    (SELECT district_name, restaurant_count, 2 AS position
     FROM district_counts
     ORDER BY restaurant_count, district_name LIMIT 1)
)
SELECT district_name, restaurant_count
FROM extremes
ORDER BY position;
