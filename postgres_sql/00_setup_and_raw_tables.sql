-- =============================================================================
-- Food Delivery Analytics — Postgres/DataGrip Setup
-- Migrated from Snowflake after trial expiry. Same data, same verified logic,
-- translated for Postgres-specific syntax differences (documented inline
-- throughout the other files in this folder).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS marts;

CREATE TABLE raw.orders_raw (
    restaurant_id VARCHAR, restaurant_name VARCHAR, subzone VARCHAR, city VARCHAR,
    order_id VARCHAR, order_placed_at VARCHAR, order_status VARCHAR, delivery VARCHAR,
    distance VARCHAR, items_in_order VARCHAR, instructions VARCHAR, discount_construct VARCHAR,
    bill_subtotal VARCHAR, packaging_charges VARCHAR, restaurant_discount_promo VARCHAR,
    restaurant_discount_flat VARCHAR, gold_discount VARCHAR, brand_pack_discount VARCHAR,
    total VARCHAR, rating VARCHAR, review VARCHAR, cancellation_reason VARCHAR,
    restaurant_compensation VARCHAR, restaurant_penalty VARCHAR, kpt_duration_minutes VARCHAR,
    rider_wait_time_minutes VARCHAR, order_ready_marked VARCHAR, customer_complaint_tag VARCHAR,
    customer_id VARCHAR
);

CREATE TABLE raw.restaurants_dim (
    restaurant_id VARCHAR, restaurant_name VARCHAR, subzone VARCHAR, city VARCHAR
);

CREATE TABLE raw.delivery_partners_dim (
    partner_id VARCHAR, vehicle_type VARCHAR, home_subzone VARCHAR, join_date VARCHAR
);

CREATE TABLE raw.delivery_ops_fact (
    order_id VARCHAR, partner_id VARCHAR, promised_sla_minutes VARCHAR,
    actual_fulfillment_minutes VARCHAR, is_late VARCHAR
);

-- Load order: orders_raw.csv, restaurants_dim.csv, delivery_partners_dim.csv,
-- delivery_ops_fact.csv (Batch 1) via DataGrip import wizard — CONFIRM "first
-- row is header" is checked every time (caught importing a literal header row
-- as data on delivery_partners_dim during this migration).
-- Then APPEND orders_raw_batch2.csv and delivery_ops_fact_batch2.csv into the
-- SAME two tables (no new restaurants/partners in the extension).

-- Verify after Batch 1: 21,361 / 19 / 50 / 21,351
-- Verify after Batch 2 append: 48,864 / 19 / 50 / 48,854
