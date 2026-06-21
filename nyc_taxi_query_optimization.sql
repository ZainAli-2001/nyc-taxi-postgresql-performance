CREATE TABLE taxi_zone_lookup
(LocationID BIGINT PRIMARY KEY,
Borough varchar(100),
Zone varchar(100),
service_zone varchar(100)
);

ALTER TABLE taxi_zone_lookup
ADD CONSTRAINT taxi_zone_lookup_pk PRIMARY KEY ("LocationID");

ALTER TABLE yellow_trips
ADD CONSTRAINT fk_pickup_location
FOREIGN KEY ("PULocationID")
REFERENCES taxi_zone_lookup("LocationID");

ALTER TABLE yellow_trips
ADD CONSTRAINT fk_dropoff_location
FOREIGN KEY ("DOLocationID")
REFERENCES taxi_zone_lookup("LocationID");

SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_name = 'taxi_zone_lookup';

SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_name = 'yellow_trips';


SELECT COUNT(*) FROM yellow_trips;

SELECT * FROM taxi_zone_lookup;

SELECT pid, state, wait_event_type, wait_event, query, now() - query_start AS duration
FROM pg_stat_activity
WHERE datname = 'nyc_taxi'
ORDER BY duration DESC;

-- Kill any process with id
-- SELECT pg_terminate_backend(1232);
-- SELECT pg_terminate_backend(18296);
-- SELECT pg_terminate_backend(8228);


-- Check date range to confirm it's the right month
SELECT MIN(tpep_pickup_datetime), MAX(tpep_pickup_datetime) FROM yellow_trips;

-- Peek at a few rows
SELECT * FROM yellow_trips LIMIT 5;

-- Check for nulls in key columns
SELECT COUNT(*) FROM yellow_trips WHERE trip_distance IS NULL;

-- Check for the type of data in the columns
SELECT column_name, data_type  FROM information_schema.columns
WHERE table_name = 'yellow_trips';

-- Indexes
-- Check how indexing helps improve query processing time
EXPLAIN ANALYZE SELECT * FROM yellow_trips
WHERE total_amount > 10.0;

CREATE INDEX amount_index
ON yellow_trips (total_amount);

EXPLAIN ANALYZE 
SELECT MAX(total_amount) FROM yellow_trips;

CREATE INDEX vendor_to_amount_index
ON yellow_trips ("VendorID", total_amount);

CREATE INDEX amount_to_vendor_index
ON yellow_trips (total_amount, "VendorID");

EXPLAIN ANALYZE 
SELECT * FROM yellow_trips
WHERE "VendorID" = 1;

EXPLAIN ANALYZE 
SELECT * FROM yellow_trips
WHERE total_amount = 1.0;

EXPLAIN ANALYZE 
SELECT * FROM yellow_trips
WHERE total_amount = 13.0 AND "VendorID" = 2;

EXPLAIN ANALYZE 
SELECT * FROM yellow_trips
WHERE total_amount > 500.0 AND "VendorID" = 2;

-- Check index_tables that are present in the table and their usage
SELECT * FROM pg_indexes
WHERE tablename = 'yellow_trips';

SELECT * FROM pg_stat_user_indexes
WHERE relname = 'yellow_trips';

-- Drop the amount_to_vendor_index as it is computationally expensive
DROP INDEX amount_to_vendor_index;


-- Windows Functions

SELECT "VendorID", COUNT(total_amount) AS total
FROM yellow_trips
GROUP BY "VendorID";

SET work_mem = '4MB';
EXPLAIN ANALYZE
SELECT "VendorID", 
		total_amount,
		RANK () OVER(
			PARTITION BY "VendorID"
			ORDER BY total_amount DESC 
		) AS spending_rank 
FROM yellow_trips;

SHOW work_mem;

-- Joins
EXPLAIN ANALYZE
SELECT 
	y."VendorID", 
	y.tpep_pickup_datetime, 
	y.tpep_dropoff_datetime,
	y.trip_distance,
	t."Zone" AS pickup_zone,
	ta."Zone" AS dropoff_zone,
	y.tip_amount,
	y.tolls_amount,
	y.fare_amount,
	y.total_amount
FROM yellow_trips y
LEFT JOIN taxi_zone_lookup t 
ON t."LocationID" = y."PULocationID" 
LEFT JOIN taxi_zone_lookup ta
ON ta."LocationID" = y."DOLocationID";

CREATE INDEX pickup_index
ON yellow_trips ("PULocationID");

EXPLAIN ANALYZE
SELECT 
	y."VendorID", 
	y.tpep_pickup_datetime, 
	y.tpep_dropoff_datetime,
	y.trip_distance,
	t."Zone" AS pickup_zone,
	ta."Zone" AS dropoff_zone,
	y.tip_amount,
	y.tolls_amount,
	y.fare_amount,
	y.total_amount
FROM yellow_trips y
LEFT JOIN taxi_zone_lookup t 
ON t."LocationID" = y."PULocationID" 
LEFT JOIN taxi_zone_lookup ta
ON ta."LocationID" = y."DOLocationID"
WHERE t."Zone" = 'Bath Beach';

Select * from taxi_zone_lookup


-- Partition
-- Lets check if there is any column worth partitioning here

-- Check for distribution in VendorID
SELECT "VendorID", COUNT(total_amount) AS total
FROM yellow_trips
GROUP BY "VendorID";
-- VendorID is also skewed with a single vendor taking 98% of data
-- check for time distribution
SELECT DISTINCT(tpep_pickup_datetime)
FROM yellow_trips
ORDER BY tpep_pickup_datetime ASC;

-- timestamp is not the ideal for partitioning here
-- CREATE TABLE yellow_trips_by_time
-- (LIKE yellow_trips) 
-- PARTITION BY RANGE (tpep_pickup_datetime);

-- Check for distribution in total_amount
SELECT COUNT(*) AS Buckets
FROM yellow_trips
GROUP BY ((FLOOR(total_amount/10))*10);
-- Data is right skewed 
-- a single bucket range is absorbing the overwhelming majority of rows
-- while dozens of buckets at the high end have single-digit counts

-- Check for distribution in PULocationID
SELECT "PULocationID", COUNT(*) AS Count
FROM yellow_trips
GROUP BY "PULocationID"
ORDER BY COUNT DESC;
-- Data is also skewed here 

-- Hence, we should not use partition here


-- Check if adding index to PULocationID benefit query
EXPLAIN ANALYZE
SELECT * FROM yellow_trips
WHERE "PULocationID" = 237;

DROP INDEX pickup_index;

EXPLAIN ANALYZE
SELECT * FROM yellow_trips
WHERE "PULocationID" = 237;


-- Common Table Expression (CTE)

-- First with materialize
EXPLAIN ANALYZE
WITH vendor_cte AS MATERIALIZED(
	SELECT * FROM yellow_trips
	WHERE "VendorID" = 2
) SELECT * FROM vendor_cte WHERE total_amount > 1000;

-- Now with inline
EXPLAIN ANALYZE
WITH vendor_cte AS NOT MATERIALIZED(
	SELECT * FROM yellow_trips
	WHERE "VendorID" = 2
) SELECT * FROM vendor_cte WHERE total_amount > 1000;

-- Check index tables 
SELECT * FROM pg_indexes
WHERE tablename = 'yellow_trips';

-- Using cte for PULocationID
SELECT "PULocationID", COUNT(*) AS count
FROM yellow_trips
GROUP BY "PULocationID"
ORDER BY count DESC;

EXPLAIN ANALYZE
WITH pickup_cte AS MATERIALIZED(
	SELECT * FROM yellow_trips
	WHERE "PULocationID" IN (138, 50, 98, 187, 199, 165)
) SELECT * FROM pickup_cte WHERE total_amount > 100;


EXPLAIN ANALYZE
WITH pickup_cte AS NOT MATERIALIZED(
	SELECT * FROM yellow_trips
	WHERE "PULocationID" IN (138, 50, 98, 187, 199, 165)
) SELECT * FROM pickup_cte WHERE total_amount > 100;

CREATE INDEX pickup_index
ON yellow_trips ("PULocationID");

-- Now after creating pickup index
EXPLAIN ANALYZE
WITH pickup_cte AS NOT MATERIALIZED(
	SELECT * FROM yellow_trips
	WHERE "PULocationID" IN (138, 50, 98, 187, 199, 165)
) SELECT * FROM pickup_cte WHERE total_amount > 100;

-- Table Bloat ,VACUUM and ANALYZE

-- Check for any dead row count
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relname = 'yellow_trips';

EXPLAIN ANALYZE
SELECT "VendorID", COUNT(*)
FROM yellow_trips
GROUP BY "VendorID";

-- We pick a vendor with lower row count
-- Update vendorID 6 to 999 to observe any bloat in the table
EXPLAIN ANALYZE
UPDATE yellow_trips
SET "VendorID" = 999
WHERE "VendorID" = 6;

-- Once again pick for bloat
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relname = 'yellow_trips';
-- 9863 dead rows detected

-- VACUUM the dead rows
VACUUM yellow_trips;

SELECT n_dead_tup FROM pg_stat_user_tables
WHERE relname = 'yellow_trips';
-- The dead rows got deleted

-- Revert the updated rows back
EXPLAIN ANALYZE
UPDATE yellow_trips
SET "VendorID" = 6
WHERE "VendorID" = 999;

ANALYZE yellow_trips;

EXPLAIN ANALYZE
SELECT "VendorID", COUNT(*)
FROM yellow_trips
GROUP BY "VendorID";
