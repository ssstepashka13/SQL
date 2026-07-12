ALTER DEFAULT PRIVILEGES IN SCHEMA inventory REVOKE SELECT ON TABLES FROM worker;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory REVOKE USAGE, SELECT ON SEQUENCES FROM inventory_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA inventory REVOKE ALL ON TABLES FROM inventory_manager;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales REVOKE SELECT ON TABLES FROM inventory_manager;
REVOKE UPDATE (status, processing_by) ON sales.orders FROM inventory_manager;
REVOKE SELECT ON ALL TABLES IN SCHEMA sales FROM inventory_manager;
REVOKE USAGE ON SCHEMA sales FROM inventory_manager;

ALTER TABLE sales.orders DROP COLUMN processing_by;

DROP TABLE inventory.transfer_items;
DROP TABLE inventory.transfers;
DROP TABLE inventory.delivery_items;
DROP TABLE inventory.deliveries;
DROP TABLE inventory.reserves;
DROP TABLE inventory.stock;
DROP TABLE inventory.routes;
DROP SCHEMA inventory;
