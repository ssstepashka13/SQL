ALTER TABLE catalog.warehouses ADD COLUMN city text;

UPDATE catalog.warehouses w
SET city = c.name
FROM catalog.cities c
WHERE c.id = w.city_id;

ALTER TABLE catalog.warehouses ALTER COLUMN city SET NOT NULL;
ALTER TABLE catalog.warehouses DROP COLUMN city_id;

DROP TABLE catalog.cities;
