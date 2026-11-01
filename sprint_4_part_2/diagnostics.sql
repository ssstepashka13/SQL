-- Выполнять после восстановления отдельной тестовой БД.
-- pg_stat_statements должен быть заранее подключён администратором окружения.
SELECT version(), CURRENT_DATE;
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_stat_statements';

-- В выделенном тестовом окружении сначала можно сбросить статистику:
-- SELECT pg_stat_statements_reset();
-- Затем выполнить все 15 SELECT из workload.sql ровно по одному разу.
SELECT queryid, calls, total_exec_time, mean_exec_time, rows, query
FROM pg_stat_statements
WHERE query LIKE 'SELECT%'
  AND query NOT LIKE '%pg_stat_statements%'
ORDER BY mean_exec_time DESC;

-- Каталог индексов: сравнить до и после выполнения project.sql.
SELECT tablename, indexname, indexdef
FROM pg_indexes WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- Пример: для каждого выбранного SQL из original.sql / project.sql
-- выполнить EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- Cost — оценка планировщика, Execution Time — фактическое время в миллисекундах.
