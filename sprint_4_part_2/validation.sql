-- Только чтение: проверки выполняются на CTE с тестовыми данными.
-- Во всех строках mismatches должно быть 0. EXCEPT ALL сохраняет кратность дублей.

-- Проверка запроса 9
WITH orders(order_id,city_id) AS (VALUES (1::bigint,1),(2,1),(3,1),(4,1),(5,2),(6,1)),
order_statuses(order_id,status_id) AS (VALUES
(1::bigint,1),(1,2),(1,3),(2,1),(2,1),(2,NULL),(3,1),(3,3),(4,2),(5,1),(NULL,1)),
before_query AS (SELECT count(*)
FROM order_statuses os
    JOIN orders o ON o.order_id = os.order_id
WHERE (SELECT count(*)
	   FROM order_statuses os1
	   WHERE os1.order_id = o.order_id AND os1.status_id = 2) = 0
	AND o.city_id = 1),
after_query AS (SELECT count(*)
FROM order_statuses os
JOIN orders o ON o.order_id = os.order_id
WHERE o.city_id = 1
  AND NOT EXISTS (
      SELECT 1
      FROM order_statuses paid
      WHERE paid.order_id = o.order_id AND paid.status_id = 2
  ))
SELECT 'query_9' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

-- Проверка запроса 8
WITH user_logs(datetime) AS (VALUES
((CURRENT_DATE-1)::timestamp), (CURRENT_DATE::timestamp),
((CURRENT_DATE+1)::timestamp-INTERVAL '1 microsecond'),
((CURRENT_DATE+1)::timestamp),((CURRENT_DATE+1)::timestamp+INTERVAL '1 microsecond'),
(NULL::timestamp),('infinity'::timestamp),('-infinity'::timestamp)),
before_query AS (SELECT *
FROM user_logs
WHERE datetime::date > current_date),
after_query AS (SELECT *
FROM user_logs
WHERE datetime >= (CURRENT_DATE + 1)::timestamp)
SELECT 'query_8' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

-- Проверка запроса 7
WITH user_logs(event,datetime,visitor_uuid) AS (VALUES
('open',TIMESTAMP '2021-05-01','fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'),
('open',TIMESTAMP '2021-05-01','fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'),
('close',TIMESTAMP '2021-05-02','fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'),
('other',TIMESTAMP '2021-05-01','00000000-0000-0000-0000-000000000000'),
('missing',NULL,NULL)),
before_query AS (SELECT event, datetime
FROM user_logs
WHERE visitor_uuid = 'fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'
ORDER BY 2),
after_query AS (SELECT event, datetime
FROM user_logs
WHERE visitor_uuid = 'fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'
ORDER BY 2)
SELECT 'query_7' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

-- Проверка запроса 2
WITH orders(order_id,order_dt,final_cost,user_id,city_id) AS (VALUES
(1::bigint,TIMESTAMPTZ '2021-01-01',100::numeric,'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid,1),
(1,TIMESTAMPTZ '2021-01-01',100,'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid,1),
(2,TIMESTAMPTZ '2021-01-02',200,'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid,1),
(3,TIMESTAMPTZ '2021-01-03',300,'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid,1),
(4,TIMESTAMPTZ '2021-01-04',400,'00000000-0000-0000-0000-000000000004'::uuid,1)),
order_statuses(order_id,status_id,status_dt) AS (VALUES
(1::bigint,1,TIMESTAMPTZ '2021-01-01'),(1,2,TIMESTAMPTZ '2021-01-02'),
(1,3,TIMESTAMPTZ '2021-01-02'),(1,3,TIMESTAMPTZ '2021-01-02'),
(2,1,NULL),(3,1,TIMESTAMPTZ '2021-01-03'),(4,2,TIMESTAMPTZ '2021-01-04')),
statuses(status_id,status_name) AS (VALUES (1,'created'),(2,'paid'),(3,'delivered')),
before_query AS (SELECT o.order_id, o.order_dt, o.final_cost, s.status_name
FROM order_statuses os
    JOIN orders o ON o.order_id = os.order_id
    JOIN statuses s ON s.status_id = os.status_id
WHERE o.user_id = 'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid
	AND os.status_dt IN (
	SELECT max(status_dt)
	FROM order_statuses
	WHERE order_id = o.order_id
    )),
after_query AS (WITH selected_orders AS MATERIALIZED (
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
JOIN statuses s ON s.status_id = os.status_id)
SELECT 'query_2' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

-- Проверка запроса 15
WITH order_items(item,count) AS (VALUES
(1::bigint,1::bigint),(1,3),(2,NULL),(3,0),(4,-2),(5,10),(NULL,2)),
dishes(object_id,name) AS (VALUES (1::bigint,'A'),(1,'B'),(5,'A'),(2,'C')),
before_query AS (SELECT d.name, SUM(count) AS orders_quantity
FROM order_items oi
    JOIN dishes d ON d.object_id = oi.item
WHERE oi.item IN (
	SELECT item
	FROM (SELECT item, SUM(count) AS total_sales
		  FROM order_items oi
		  GROUP BY 1) dishes_sales
	WHERE dishes_sales.total_sales > (
		SELECT SUM(t.total_sales)/ COUNT(*)
		FROM (SELECT item, SUM(count) AS total_sales
			FROM order_items oi
			GROUP BY
				1) t)
)
GROUP BY 1
ORDER BY orders_quantity DESC),
after_query AS (WITH item_totals AS MATERIALIZED (
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
ORDER BY orders_quantity DESC)
SELECT 'query_15' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

-- Проверка запроса 12
WITH dishes(object_id,fish,meat,spicy) AS (VALUES (1::bigint,1,0,1),(2,1,1,0),(3,NULL,NULL,NULL)),
dishes_prices(dishes_id,price,date_end) AS (VALUES
(1::bigint,100::numeric,NULL::timestamptz),(2,300,NULL),(3,NULL,NULL),
(1,900,TIMESTAMPTZ '2020-01-01')),
before_query AS (SELECT 'average price with fish', avg(dp.price)
FROM dishes_prices dp
    JOIN dishes d ON d.object_id = dp.dishes_id
WHERE dp.date_end IS NULL AND d.fish = 1
UNION
SELECT 'average price with meat', avg(dp.price)
FROM dishes_prices dp
    JOIN dishes d ON d.object_id = dp.dishes_id
WHERE dp.date_end IS NULL AND d.meat = 1
UNION
SELECT 'average price of spicy food', avg(dp.price)
FROM dishes_prices dp
    JOIN dishes d ON d.object_id = dp.dishes_id
WHERE dp.date_end IS NULL AND d.spicy = 1
ORDER BY 2),
after_query AS (SELECT v."?column?", v.avg
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
ORDER BY 2)
SELECT 'query_12' AS test, count(*) AS mismatches
FROM ((SELECT * FROM before_query EXCEPT ALL SELECT * FROM after_query)
      UNION ALL
      (SELECT * FROM after_query EXCEPT ALL SELECT * FROM before_query)) differences;

