-- ============================================================================
-- Food Delivery Analytics — Snowflake Environment Setup
-- Run this in a worksheet after creating your database in the Snowflake UI
-- ============================================================================

-- 1. Create database and schemas (staging/mart pattern, mirrors dbt structure)
CREATE DATABASE IF NOT EXISTS food_delivery_db;
USE DATABASE food_delivery_db;

CREATE SCHEMA IF NOT EXISTS raw;         -- exactly as uploaded, mess and all
CREATE SCHEMA IF NOT EXISTS staging;     -- cleaned, standardized, deduped
CREATE SCHEMA IF NOT EXISTS intermediate; -- joined, business-logic applied
CREATE SCHEMA IF NOT EXISTS marts;       -- final tables that answer stakeholder questions

USE SCHEMA raw;

-- 2. Warehouse (compute) — XS is plenty for this data volume
CREATE WAREHOUSE IF NOT EXISTS food_delivery_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

USE WAREHOUSE food_delivery_wh;

-- ============================================================================
-- 3. RAW TABLES — load everything as STRING first, cast during cleaning.
-- This is deliberate: loading messy source data straight into typed columns
-- either fails outright or silently coerces bad values. Landing everything
-- as VARCHAR first and casting explicitly in the staging layer is the
-- standard raw-layer pattern in a real warehouse.
-- ============================================================================

CREATE OR REPLACE TABLE raw.orders_raw (
    restaurant_id           VARCHAR,
    restaurant_name         VARCHAR,
    subzone                 VARCHAR,
    city                    VARCHAR,
    order_id                VARCHAR,
    order_placed_at         VARCHAR,
    order_status            VARCHAR,
    delivery                VARCHAR,
    distance                VARCHAR,
    items_in_order          VARCHAR,
    instructions             VARCHAR,
    discount_construct      VARCHAR,
    bill_subtotal            VARCHAR,
    packaging_charges       VARCHAR,
    restaurant_discount_promo VARCHAR,
    restaurant_discount_flat  VARCHAR,
    gold_discount            VARCHAR,
    brand_pack_discount      VARCHAR,
    total                    VARCHAR,
    rating                   VARCHAR,
    review                   VARCHAR,
    cancellation_reason      VARCHAR,
    restaurant_compensation  VARCHAR,
    restaurant_penalty       VARCHAR,
    kpt_duration_minutes     VARCHAR,
    rider_wait_time_minutes  VARCHAR,
    order_ready_marked       VARCHAR,
    customer_complaint_tag   VARCHAR,
    customer_id              VARCHAR
);

CREATE OR REPLACE TABLE raw.restaurants_dim (
    restaurant_id     VARCHAR,
    restaurant_name   VARCHAR,
    subzone           VARCHAR,
    city              VARCHAR
);

CREATE OR REPLACE TABLE raw.delivery_partners_dim (
    partner_id      VARCHAR,
    vehicle_type    VARCHAR,
    home_subzone    VARCHAR,
    join_date       VARCHAR
);

CREATE OR REPLACE TABLE raw.delivery_ops_fact (
    order_id                     VARCHAR,
    partner_id                   VARCHAR,
    promised_sla_minutes         VARCHAR,
    actual_fulfillment_minutes   VARCHAR,
    is_late                      VARCHAR
);

-- ============================================================================
-- 4. FILE FORMAT for CSV loads
-- ============================================================================
CREATE OR REPLACE FILE FORMAT raw.csv_ff
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NaN', 'null', 'NULL')
    EMPTY_FIELD_AS_NULL = TRUE;

-- ============================================================================
-- 5. LOADING VIA SNOWSIGHT UI (simplest path, no local SnowSQL install needed)
-- ============================================================================
-- In Snowsight:
--   Data > Databases > FOOD_DELIVERY_DB > RAW > [table name]
--   Click "Load Data" > select your CSV > select file format csv_ff (or let
--   Snowsight auto-detect, then verify against csv_ff settings above)
--   Repeat for all 4 tables: orders_raw, restaurants_dim,
--   delivery_partners_dim, delivery_ops_fact
--
-- Alternative (SnowSQL CLI, if installed):
--   PUT file:///local/path/orders_raw.csv @%orders_raw;
--   COPY INTO raw.orders_raw FROM @%orders_raw FILE_FORMAT = (FORMAT_NAME = raw.csv_ff);
--   (repeat per table)

-- ============================================================================
-- 6. Sanity check after loading — row counts should match what the
--    Python script printed when it built these files
-- ============================================================================
-- SELECT COUNT(*) FROM raw.orders_raw;              -- expect 21,361
-- SELECT COUNT(*) FROM raw.restaurants_dim;          -- expect 19
-- SELECT COUNT(*) FROM raw.delivery_partners_dim;    -- expect 50
-- SELECT COUNT(*) FROM raw.delivery_ops_fact;        -- expect 21,351
