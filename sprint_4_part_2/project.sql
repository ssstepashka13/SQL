-- Gastro Hub Delivery. Проект 4, часть 2.
-- Только SELECT: таблицы, колонки, индексы, ограничения и данные не изменяются.

-- Запрос 9: отсутствие оплаты проверяется один раз хеш-антисоединением.
-- COUNT считает строки исходного соединения, а не уникальные заказы.
-- query:9
SELECT count(*)
FROM order_statuses os
JOIN orders o ON o.order_id = os.order_id
WHERE o.city_id = 1
  AND NOT EXISTS (
      SELECT 1
      FROM order_statuses paid
      WHERE paid.order_id = o.order_id AND paid.status_id = 2
  );

-- Запрос 8: эквивалент datetime::date > CURRENT_DATE, начиная с завтрашней полуночи.
-- Функция над индексированной колонкой убрана; условие за текущий день не расширяется.
-- query:8
SELECT *
FROM user_logs
WHERE datetime >= (CURRENT_DATE + 1)::timestamp;

-- Запрос 7: сохранён исходный запрос. Без индекса по visitor_uuid и без ограничения
-- периода нужен полный просмотр логов. Добавлять индекс запрещено условием.
-- Придуманный период, ONLY, LIMIT или удаление дублей изменили бы результат.
-- Отсутствие ускорения этого случая явно отражено в отчёте.
-- query:7
SELECT event, datetime
FROM user_logs
WHERE visitor_uuid = 'fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'
ORDER BY 2;

-- Запрос 2: сначала отбираются заказы пользователя; статусы читаются один раз.
-- MAX в окне сохраняет все статусы с одинаковым максимальным временем.
-- query:2
WITH selected_orders AS MATERIALIZED (
    SELECT order_id, order_dt, final_cost
    FROM orders
    WHERE user_id = 'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid
), selected_statuses AS (
    SELECT os.order_id, os.status_id, os.status_dt,
           max(os.status_dt) OVER (PARTITION BY os.order_id) AS last_status_dt
    FROM order_statuses os
    WHERE EXISTS (SELECT 1 FROM selected_orders o WHERE o.order_id = os.order_id)
)
SELECT o.order_id, o.order_dt, o.final_cost, s.status_name
FROM selected_orders o
JOIN selected_statuses os ON os.order_id = o.order_id
                         AND os.status_dt = os.last_status_dt
JOIN statuses s ON s.status_id = os.status_id;

-- Запрос 15: суммы по блюдам вычисляются один раз, вместо повторных агрегаций.
-- Делитель COUNT(*) учитывает и группы с NULL-суммой, как в исходном запросе.
-- query:15
WITH item_totals AS MATERIALIZED (
    SELECT item, sum(count) AS total_sales
    FROM order_items
    GROUP BY item
), scored AS (
    SELECT item, total_sales,
           sum(total_sales) OVER () / count(*) OVER () AS average_sales
    FROM item_totals
)
SELECT d.name, sum(s.total_sales) AS orders_quantity
FROM scored s
JOIN dishes d ON d.object_id = s.item
WHERE s.total_sales > s.average_sales
GROUP BY d.name
ORDER BY orders_quantity DESC;

-- Дополнительный запрос 12: три агрегата за один проход вместо трёх веток UNION.
-- Он не подменяет запрос 7 в найденной пятёрке; это отдельное улучшение без DDL.
-- query:12
SELECT v."?column?", v.avg
FROM (
    SELECT avg(dp.price) FILTER (WHERE d.fish = 1) AS fish_price,
           avg(dp.price) FILTER (WHERE d.meat = 1) AS meat_price,
           avg(dp.price) FILTER (WHERE d.spicy = 1) AS spicy_price
    FROM dishes_prices dp
    JOIN dishes d ON d.object_id = dp.dishes_id
    WHERE dp.date_end IS NULL
) a
CROSS JOIN LATERAL (
    VALUES ('average price with fish', a.fish_price),
           ('average price with meat', a.meat_price),
           ('average price of spicy food', a.spicy_price)
) v("?column?", avg)
ORDER BY 2;
