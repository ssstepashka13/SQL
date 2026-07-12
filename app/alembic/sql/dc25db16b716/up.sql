-- catalog_manager: любые операции в схеме catalog
GRANT USAGE ON SCHEMA catalog TO catalog_manager;
GRANT ALL ON ALL TABLES IN SCHEMA catalog TO catalog_manager;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA catalog TO catalog_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA catalog GRANT ALL ON TABLES TO catalog_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA catalog GRANT USAGE, SELECT ON SEQUENCES TO catalog_manager;

-- sales_manager: любые операции в схеме sales
GRANT USAGE ON SCHEMA sales TO sales_manager;
GRANT ALL ON ALL TABLES IN SCHEMA sales TO sales_manager;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA sales TO sales_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT ALL ON TABLES TO sales_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales GRANT USAGE, SELECT ON SEQUENCES TO sales_manager;

-- чтение catalog должно быть у всех ролей, включая будущие
GRANT USAGE ON SCHEMA catalog TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA catalog TO PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA catalog GRANT SELECT ON TABLES TO PUBLIC;
