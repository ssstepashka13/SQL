-- query:9
SELECT count(*)
FROM order_statuses os
    JOIN orders o ON o.order_id = os.order_id
WHERE (SELECT count(*)
	   FROM order_statuses os1
	   WHERE os1.order_id = o.order_id AND os1.status_id = 2) = 0
	AND o.city_id = 1;

-- query:8
SELECT *
FROM user_logs
WHERE datetime::date > current_date;

-- query:7
SELECT event, datetime
FROM user_logs
WHERE visitor_uuid = 'fd3a4daa-494a-423a-a9d1-03fd4a7f94e0'
ORDER BY 2;

-- query:2
SELECT o.order_id, o.order_dt, o.final_cost, s.status_name
FROM order_statuses os
    JOIN orders o ON o.order_id = os.order_id
    JOIN statuses s ON s.status_id = os.status_id
WHERE o.user_id = 'c2885b45-dddd-4df3-b9b3-2cc012df727c'::uuid
	AND os.status_dt IN (
	SELECT max(status_dt)
	FROM order_statuses
	WHERE order_id = o.order_id
    );

-- query:15
SELECT d.name, SUM(count) AS orders_quantity
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
ORDER BY orders_quantity DESC;

-- query:12
SELECT 'average price with fish', avg(dp.price)
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
ORDER BY 2;