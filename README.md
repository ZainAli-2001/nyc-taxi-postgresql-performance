# NYC Taxi PostgreSQL Analytics & Query Optimization

Working with real-world NYC TLC Yellow Taxi trip data to explore PostgreSQL database design, advanced SQL querying, query execution plans, indexing strategies, window functions, joins, and performance optimization on large-scale datasets.

## Data Source

NYC TLC Trip Record Data: https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page

- Yellow taxi trip data (Parquet format)
- Taxi zone lookup table (CSV, maps `LocationID` → Borough/Zone) — same page, under "Taxi Zone Maps and Lookup Tables"

## Loading Data: Website → Python → PostgreSQL

1. **Download** the Parquet file directly from the TLC website (no API/direct-to-DB option exists).
2. **Read and load with Python** — pandas reads the Parquet file into a DataFrame, then
   `to_sql` (via SQLAlchemy) writes it straight into Postgres, table created automatically:

```python
import os
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine
from urllib.parse import quote_plus

load_dotenv()
password = quote_plus(os.getenv('DB_PASSWORD'))
engine = create_engine(
    f"postgresql://{os.getenv('DB_USER')}:{password}@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT')}/{os.getenv('DB_NAME')}"
)

df = pd.read_parquet(r'path\to\yellow_tripdata_2024-01.parquet')

with engine.connect() as conn:
    df.to_sql('yellow_trips', conn, if_exists='replace', index=False, chunksize=10000)
    conn.commit()

engine.dispose()
```

**Notes:**
- Credentials live in a `.env` file (never committed — add `.env` to `.gitignore`).
- `to_sql` does **not** preserve primary keys / constraints — these must be added afterward via `ALTER TABLE`.
- One month (~3.8M rows) took several minutes; watch system RAM, since pandas loads the entire file into memory before writing.
- Faster alternative for large loads: `COPY` via `psycopg2.copy_expert`, or stream with DuckDB instead of pandas.

## Schema

```sql
CREATE TABLE taxi_zone_lookup (
    "LocationID" BIGINT PRIMARY KEY,
    "Borough" VARCHAR(100),
    "Zone" VARCHAR(100),
    "service_zone" VARCHAR(100)
);

-- yellow_trips created via pandas to_sql; constraints added after:
ALTER TABLE yellow_trips
    ADD CONSTRAINT fk_pickup_location
    FOREIGN KEY ("PULocationID") REFERENCES taxi_zone_lookup("LocationID");

ALTER TABLE yellow_trips
    ADD CONSTRAINT fk_dropoff_location
    FOREIGN KEY ("DOLocationID") REFERENCES taxi_zone_lookup("LocationID");
```

`yellow_trips` columns (from `to_sql` inference):

| Column | Type |
|---|---|
| VendorID | integer |
| tpep_pickup_datetime | timestamp |
| tpep_dropoff_datetime | timestamp |
| passenger_count | double precision |
| trip_distance | double precision |
| RatecodeID | double precision |
| store_and_fwd_flag | text |
| PULocationID | integer |
| DOLocationID | integer |
| payment_type | bigint |
| fare_amount | double precision |
| extra | double precision |
| mta_tax | double precision |
| tip_amount | double precision |
| tolls_amount | double precision |
| improvement_surcharge | double precision |
| total_amount | double precision |
| congestion_surcharge | double precision |
| Airport_fee | double precision |
| cbd_congestion_fee | double precision |

`yellow_trips` has no primary key — no column or combination is naturally unique per row.

## Useful Diagnostic Queries

```sql
-- Table constraints
SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_name = 'yellow_trips';

-- Column names/types
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'yellow_trips';

-- Indexes on a table
SELECT * FROM pg_indexes WHERE tablename = 'yellow_trips';

-- Index usage stats (idx_scan = how many times it's actually been used)
SELECT * FROM pg_stat_user_indexes WHERE relname = 'yellow_trips';

-- Active/blocked sessions
SELECT pid, state, wait_event_type, wait_event, query, now() - query_start AS duration
FROM pg_stat_activity
WHERE datname = 'nyc_taxi'
ORDER BY duration DESC;

-- Kill a stuck session
SELECT pg_terminate_backend(<pid>);
```

## Indexing — Key Findings

- **Sequential scan vs index scan** is decided by the query planner based on
  **selectivity** (what % of rows match). Low-selectivity filters (e.g. `total_amount > 10`,
  matching ~98% of rows) are *cheaper* via seq scan — the planner correctly ignores an
  existing index in that case.
- **Index-only scans**: if a query only needs columns already in the index (e.g. `MAX(total_amount)`),
  Postgres never touches the table at all (`Heap Fetches: 0`). B-tree lookups for min/max
  are effectively O(log n).
- **Composite indexes** `(A, B)` follow the **leftmost-prefix rule** — usable for filters on
  `A` alone or `A + B` together, but not efficiently for `B` alone unless cardinality/cost
  considerations favor it anyway.
- **Bitmap scans** appear when a moderate number of rows match — Postgres builds a bitmap
  of matching disk pages first, then visits each page once, avoiding repeated random I/O.
- Unused indexes have real costs (write overhead, storage) and should be dropped if
  `pg_stat_user_indexes.idx_scan` stays at 0.

```sql
CREATE INDEX amount_index ON yellow_trips (total_amount);
CREATE INDEX vendor_to_amount_index ON yellow_trips ("VendorID", total_amount);
DROP INDEX amount_to_vendor_index; -- redundant/unused index, removed after checking usage stats
```

## Window Functions — Key Findings

- Unlike `GROUP BY`, window functions preserve every row and add a calculated column.
- `RANK() OVER (PARTITION BY ... ORDER BY ...)` requires sorted data per partition.
  If an index already provides partial sort order (e.g. `VendorID` ascending), Postgres
  uses **Incremental Sort** — sorting only within each partition rather than the whole table.
- Sorting that exceeds `work_mem` spills to disk (`external merge`). Increasing `work_mem`
  helps only up to a point — driven by actual data skew (e.g. one vendor having ~80% of
  rows), not naive even-split assumptions. Beyond a certain point, more `work_mem` showed
  diminishing/inconsistent returns — the bottleneck shifted elsewhere (I/O, CPU, system load).

```sql
SET work_mem = '4MB'; -- session-scoped only
SHOW work_mem;

EXPLAIN ANALYZE
SELECT "VendorID", total_amount,
       RANK() OVER (PARTITION BY "VendorID" ORDER BY total_amount DESC) AS spending_rank
FROM yellow_trips;
```

## Joins — Key Findings

- **Hash Join**: Postgres builds a hash table from the *smaller* table (e.g. 265-row
  `taxi_zone_lookup`), then streams the larger table through it. Efficient when most/all
  rows of the large table are needed regardless (no selective `WHERE` filter).
- **Nested Loop Join**: wins when one side is filtered down to very few rows *and* the
  large table has a matching index — Postgres looks up only the matching rows directly,
  instead of scanning everything.
- A foreign key constraint does **not** automatically create an index on the referencing
  column — `PULocationID`/`DOLocationID` needed explicit indexes to enable Nested Loop plans.
- **Memoize**: caches repeated lookups within a query (e.g. repeated `DOLocationID` values),
  avoiding duplicate index searches for the same key.

```sql
CREATE INDEX pickup_index ON yellow_trips ("PULocationID");

EXPLAIN ANALYZE
SELECT y."VendorID", y.tpep_pickup_datetime, y.tpep_dropoff_datetime, y.trip_distance,
       t."Zone" AS pickup_zone, ta."Zone" AS dropoff_zone,
       y.tip_amount, y.tolls_amount, y.fare_amount, y.total_amount
FROM yellow_trips y
LEFT JOIN taxi_zone_lookup t  ON t."LocationID" = y."PULocationID"
LEFT JOIN taxi_zone_lookup ta ON ta."LocationID" = y."DOLocationID"
WHERE t."Zone" = 'Bath Beach';
-- Unfiltered: Hash Join, ~10.8s (touches all 3.8M rows)
-- Filtered + pickup_index: Nested Loop, ~10ms (touches ~285 rows)
```

## Core Takeaway

Indexes help when a query needs a small, selective subset of rows. When a query
necessarily touches most/all of a table (no filter, or low-selectivity filter), a
sequential or hash-based scan is cheaper — and the planner will correctly choose that
over an existing index. Always verify with `EXPLAIN ANALYZE` rather than assuming.

## Partitioning — Investigation and Findings

Before partitioning any table, checked whether real columns in `yellow_trips` had a
distribution that would actually benefit from it. Partitioning only pays off when:
data is reasonably balanced across partitions, **and** queries consistently filter on
the partition key. Three candidate columns were tested — none qualified.

```sql
-- Check distribution in VendorID
SELECT "VendorID", COUNT(total_amount) AS total
FROM yellow_trips
GROUP BY "VendorID";
-- Skewed: a single vendor holds ~98% of rows. Partitioning by VendorID
-- would produce one massive partition and several near-empty ones.

-- Check time distribution
SELECT DISTINCT(tpep_pickup_datetime)
FROM yellow_trips
ORDER BY tpep_pickup_datetime ASC;
-- Only one month of data is loaded, so a date-range partition would
-- contain ~99.9% of rows in a single "April" partition — no pruning benefit.
-- (Would become worthwhile once multiple months/years are loaded.)

-- CREATE TABLE yellow_trips_by_time
-- (LIKE yellow_trips)
-- PARTITION BY RANGE (tpep_pickup_datetime);
-- ^ left unused for the reason above

-- Check distribution in total_amount ($10 buckets)
SELECT COUNT(*) AS Buckets
FROM yellow_trips
GROUP BY ((FLOOR(total_amount / 10)) * 10);
-- Heavily right-skewed: a couple of buckets in the $10-30 range absorb
-- the overwhelming majority of rows, while dozens of high-fare buckets
-- have single-digit counts. Equal-width range partitions would be useless;
-- unequal-width partitions would still leave a few dominant partitions.

-- Check distribution in PULocationID
SELECT "PULocationID", COUNT(*) AS Count
FROM yellow_trips
GROUP BY "PULocationID"
ORDER BY COUNT DESC;
-- Also skewed: top zones (e.g. 237, 161, 236) hold 150K-180K+ rows each,
-- while the long tail of 200+ zones holds a handful of rows each.
-- Partitioning by zone would mean creating 265 partitions, most nearly
-- empty, for no real pruning benefit — not worth the overhead.
```

**Conclusion:** none of VendorID, total_amount, or PULocationID have a distribution
that justifies partitioning at the current data scale. Partitioning would only become
worthwhile with multiple months/years of data partitioned by pickup date (the column
the source files are already organized by), where genuine range-based pruning and
archiving become possible.

### Index vs. partition trade-off check (PULocationID)

Even though partitioning didn't make sense for `PULocationID`, tested whether an index
on it helps for a single dense zone (`PULocationID = 237`, ~183K matching rows out of
~3.8M, ~5% selectivity):

```sql
-- With pickup_index in place — bitmap scan, partially "lossy" (falls back to
-- page-level tracking when too many matches to track exactly), with recheck overhead
EXPLAIN ANALYZE
SELECT * FROM yellow_trips
WHERE "PULocationID" = 237;
-- Execution Time: ~2837 ms

DROP INDEX pickup_index;

-- Without the index — parallel sequential scan
EXPLAIN ANALYZE
SELECT * FROM yellow_trips
WHERE "PULocationID" = 237;
-- Execution Time: ~1275 ms
```

**Finding:** for this moderately-common zone (~5% selectivity), the plain sequential
scan beat the bitmap index scan by more than 2x. This selectivity range sits in a
middle zone — too large a result set for the index to win cleanly (unlike a rare
zone matching a few hundred rows), but the index lookup and recheck overhead still
costs more than just scanning straight through. Confirms the broader lesson from
earlier sections: an index's value depends on the specific values being queried,
not just whether the column is indexed in general.
