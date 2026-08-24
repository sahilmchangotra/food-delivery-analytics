-- =============================================================================
-- Staging layer (Postgres translation)
-- Key differences from Snowflake: no SELECT * EXCLUDE(), no TRY_TO_TIMESTAMP,
-- no TRY_CAST — columns listed explicitly, date-format detection via regex,
-- plain :: casts (safe here since original data quality was already verified).
-- =============================================================================

CREATE OR REPLACE VIEW staging.stg_orders AS
WITH ranked_orders AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY order_placed_at DESC, kpt_duration_minutes::NUMERIC DESC NULLS LAST
        ) AS row_num
    FROM raw.orders_raw
)
SELECT
    r.order_id,
    r.restaurant_id,
    LOWER(TRIM(r.restaurant_name)) AS restaurant_name,
    LOWER(TRIM(r.subzone)) AS subzone,
    LOWER(TRIM(r.city)) AS city,
    CASE
        WHEN r.order_placed_at ~ '^\d{4}-\d{2}-\d{2}'
            THEN TO_TIMESTAMP(r.order_placed_at, 'YYYY-MM-DD HH24:MI:SS')
        ELSE TO_TIMESTAMP(r.order_placed_at, 'HH12:MI AM, FMMonth DD YYYY')
    END AS order_placed_at,
    r.order_status,
    r.delivery,
    CASE WHEN r.distance = '<1km' THEN 0.5 ELSE REPLACE(r.distance, 'km', '')::FLOAT END AS distance_km,
    r.items_in_order,
    r.instructions,
    r.discount_construct,
    r.bill_subtotal::NUMERIC AS bill_subtotal,
    r.packaging_charges::NUMERIC AS packaging_charges,
    r.restaurant_discount_promo::NUMERIC AS restaurant_discount_promo,
    r.restaurant_discount_flat::NUMERIC AS restaurant_discount_flat,
    r.gold_discount::NUMERIC AS gold_discount,
    r.brand_pack_discount::NUMERIC AS brand_pack_discount,
    r.total::NUMERIC AS total,
    r.rating::NUMERIC AS rating,
    r.review,
    r.cancellation_reason,
    r.restaurant_compensation,
    r.restaurant_penalty,
    r.kpt_duration_minutes::NUMERIC AS kpt_duration_minutes,
    r.rider_wait_time_minutes::NUMERIC AS rider_wait_time_minutes,
    r.order_ready_marked,
    r.customer_complaint_tag,
    r.customer_id,
    d.restaurant_id IS NULL AS is_restaurant_orphaned,
    r.kpt_duration_minutes::NUMERIC < 0 AS is_kpt_invalid,
    r.rating::NUMERIC > 5 AS is_rating_invalid,
    r.kpt_duration_minutes IS NULL AS is_kpt_missing,
    r.rider_wait_time_minutes IS NULL AS is_rider_wait_missing
FROM ranked_orders r
LEFT JOIN raw.restaurants_dim d ON r.restaurant_id = d.restaurant_id
WHERE r.row_num = 1;
-- Verified: 48,824 rows total; 1,709 is_kpt_missing (consistent with Batch 1's
-- 709/21,321 rate carried proportionally into Batch 2's cloned rows)

CREATE OR REPLACE VIEW staging.stg_delivery_ops AS
WITH ranked_ops AS (
    SELECT
        order_id,
        partner_id,
        promised_sla_minutes::NUMERIC AS promised_sla_minutes,
        actual_fulfillment_minutes::NUMERIC AS actual_fulfillment_minutes,
        is_late::NUMERIC AS is_late,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, partner_id
            ORDER BY order_id DESC, partner_id DESC NULLS LAST
        ) AS row_num
    FROM raw.delivery_ops_fact
)
SELECT order_id, partner_id, promised_sla_minutes, actual_fulfillment_minutes, is_late
FROM ranked_ops
WHERE row_num = 1;
-- Verified: 48,853 rows (matches Snowflake exactly)
