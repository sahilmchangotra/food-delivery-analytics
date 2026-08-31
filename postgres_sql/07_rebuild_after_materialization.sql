-- =============================================================================
-- REBUILD SCRIPT — run top to bottom in DataGrip against Supabase
-- Converts stg_orders and stg_delivery_ops from VIEWS to TABLES (materialized)
-- to fix DirectQuery/query timeouts caused by re-computing the same expensive
-- dedup + cast + regex logic on every downstream query. Then recreates every
-- marts view that Power BI depends on.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1 — Drop the old views (CASCADE removes every dependent marts view too)
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS staging.stg_orders CASCADE;
DROP VIEW IF EXISTS staging.stg_delivery_ops CASCADE;

-- -----------------------------------------------------------------------------
-- STEP 2 — Recreate staging as TABLES (materialized, computed once)
-- -----------------------------------------------------------------------------
CREATE TABLE staging.stg_orders AS
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
    r.order_id, r.restaurant_id,
    LOWER(TRIM(r.restaurant_name)) AS restaurant_name,
    LOWER(TRIM(r.subzone)) AS subzone,
    LOWER(TRIM(r.city)) AS city,
    CASE
        WHEN r.order_placed_at ~ '^\d{4}-\d{2}-\d{2}'
            THEN TO_TIMESTAMP(r.order_placed_at, 'YYYY-MM-DD HH24:MI:SS')
        ELSE TO_TIMESTAMP(r.order_placed_at, 'HH12:MI AM, FMMonth DD YYYY')
    END AS order_placed_at,
    r.order_status, r.delivery,
    CASE WHEN r.distance = '<1km' THEN 0.5 ELSE REPLACE(r.distance, 'km', '')::FLOAT END AS distance_km,
    r.items_in_order, r.instructions, r.discount_construct,
    r.bill_subtotal::NUMERIC AS bill_subtotal,
    r.packaging_charges::NUMERIC AS packaging_charges,
    r.restaurant_discount_promo::NUMERIC AS restaurant_discount_promo,
    r.restaurant_discount_flat::NUMERIC AS restaurant_discount_flat,
    r.gold_discount::NUMERIC AS gold_discount,
    r.brand_pack_discount::NUMERIC AS brand_pack_discount,
    r.total::NUMERIC AS total,
    r.rating::NUMERIC AS rating,
    r.review, r.cancellation_reason, r.restaurant_compensation, r.restaurant_penalty,
    r.kpt_duration_minutes::NUMERIC AS kpt_duration_minutes,
    r.rider_wait_time_minutes::NUMERIC AS rider_wait_time_minutes,
    r.order_ready_marked, r.customer_complaint_tag, r.customer_id,
    d.restaurant_id IS NULL AS is_restaurant_orphaned,
    r.kpt_duration_minutes::NUMERIC < 0 AS is_kpt_invalid,
    r.rating::NUMERIC > 5 AS is_rating_invalid,
    r.kpt_duration_minutes IS NULL AS is_kpt_missing,
    r.rider_wait_time_minutes IS NULL AS is_rider_wait_missing
FROM ranked_orders r
LEFT JOIN raw.restaurants_dim d ON r.restaurant_id = d.restaurant_id
WHERE r.row_num = 1;

CREATE INDEX idx_stg_orders_customer_id ON staging.stg_orders(customer_id);
CREATE INDEX idx_stg_orders_order_id ON staging.stg_orders(order_id);
CREATE INDEX idx_stg_orders_placed_at ON staging.stg_orders(order_placed_at);

CREATE TABLE staging.stg_delivery_ops AS
WITH ranked_ops AS (
    SELECT
        order_id, partner_id,
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

CREATE INDEX idx_stg_delivery_ops_order_id ON staging.stg_delivery_ops(order_id);
CREATE INDEX idx_stg_delivery_ops_partner_id ON staging.stg_delivery_ops(partner_id);

-- VERIFY before continuing:
-- SELECT COUNT(*) FROM staging.stg_orders;         -- expect 48,824
-- SELECT COUNT(*) FROM staging.stg_delivery_ops;    -- expect 48,853

-- -----------------------------------------------------------------------------
-- STEP 3 — Recreate marts.arjun_delivery_segment (base view for all Arjun marts)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW marts.arjun_delivery_segment AS
WITH assigned_partners AS (
    SELECT order_id, COUNT(DISTINCT partner_id) AS partners_assigned
    FROM staging.stg_delivery_ops GROUP BY order_id
),
ranked_ops AS (
    SELECT
        order_id, partner_id, promised_sla_minutes, actual_fulfillment_minutes, is_late,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY partner_id ASC) AS row_num
    FROM staging.stg_delivery_ops
),
deduped_ops AS (
    SELECT
        r.order_id, r.partner_id, r.promised_sla_minutes, r.actual_fulfillment_minutes, r.is_late,
        a.partners_assigned, a.partners_assigned > 1 AS was_reassigned
    FROM ranked_ops r
    LEFT JOIN assigned_partners a ON r.order_id = a.order_id
    WHERE r.row_num = 1
)
SELECT
    o.*, d.partner_id, d.was_reassigned,
    CASE WHEN d.is_late = 1 THEN 'late' WHEN d.is_late = 0 THEN 'on_time' WHEN d.is_late IS NULL THEN 'not_deliverable' END AS delivery_status,
    CASE
        WHEN o.distance_km <= 1 THEN 'Band_1'
        WHEN o.distance_km <= 3 THEN 'Band_2'
        WHEN o.distance_km <= 5 THEN 'Band_3'
        WHEN o.distance_km > 5 THEN 'Band_4'
    END AS distance_band
FROM staging.stg_orders o
LEFT JOIN deduped_ops d ON o.order_id = d.order_id;

-- -----------------------------------------------------------------------------
-- STEP 4 — Recreate Priya's marts (used on Page 1 and Page 2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW marts.priya_cohort_retention AS
WITH customer_cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
customer_retention AS (
    SELECT
        c.cohort_month, o.customer_id,
        (EXTRACT(YEAR FROM DATE_TRUNC('month', o.order_placed_at)) - EXTRACT(YEAR FROM c.cohort_month)) * 12
            + (EXTRACT(MONTH FROM DATE_TRUNC('month', o.order_placed_at)) - EXTRACT(MONTH FROM c.cohort_month)) AS months_since_first_order
    FROM staging.stg_orders o
    JOIN customer_cohorts c ON o.customer_id = c.customer_id
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(customer_id) AS cohort_size FROM customer_cohorts GROUP BY cohort_month
)
SELECT
    TO_CHAR(ca.cohort_month, 'YYYY-MM') AS cohort_month,
    ca.months_since_first_order,
    COUNT(DISTINCT ca.customer_id) AS active_customers,
    cs.cohort_size,
    ROUND(COUNT(DISTINCT ca.customer_id) * 100.0 / cs.cohort_size, 2) AS retention_rate
FROM customer_retention ca
JOIN cohort_sizes cs ON ca.cohort_month = cs.cohort_month
GROUP BY 1, 2, cs.cohort_size
ORDER BY 1, 2;

CREATE OR REPLACE VIEW marts.priya_rfm_segments AS
WITH ref AS (
    SELECT MAX(order_placed_at::DATE) AS recent_order_date FROM staging.stg_orders
),
customer_base AS (
    SELECT
        customer_id,
        MAX(recent_order_date) - MAX(order_placed_at::DATE) AS recency_days,
        COUNT(DISTINCT order_id) AS frequency_orders,
        SUM(total) AS monetary_total
    FROM staging.stg_orders, ref
    GROUP BY customer_id
),
quantiled AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        CASE
            WHEN frequency_orders = 1 THEN 1
            WHEN frequency_orders = 2 THEN 2
            WHEN frequency_orders BETWEEN 3 AND 4 THEN 3
            WHEN frequency_orders >= 5 THEN 4
        END AS f_score,
        NTILE(5) OVER (ORDER BY monetary_total ASC) AS m_score
    FROM customer_base
)
SELECT
    *,
    CASE
        WHEN r_score = 5 AND f_score = 4 AND m_score = 5 THEN 'Champions'
        WHEN r_score > 3 AND (f_score >= 3 OR m_score > 4) THEN 'Loyal'
        WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3 THEN 'At-risk'
        WHEN r_score = 1 AND f_score = 1 AND m_score = 1 THEN 'Churned'
        ELSE 'Other'
    END AS rfm_segment
FROM quantiled;

-- Optimized version: each window function computed ONCE, on top of an
-- already-aggregated result, instead of re-scanning the full join twice.
CREATE OR REPLACE VIEW marts.priya_promo_dependency AS
WITH ranked_orders AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_placed_at ASC) AS row_num
    FROM staging.stg_orders
),
first_order_flag AS (
    SELECT customer_id, discount_construct IS NOT NULL AS first_order_had_discount
    FROM ranked_orders WHERE row_num = 1
),
customer_cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
cohorting AS (
    SELECT
        o.customer_id, c.cohort_month,
        (EXTRACT(YEAR FROM o.order_placed_at) - EXTRACT(YEAR FROM c.cohort_month)) * 12
            + (EXTRACT(MONTH FROM o.order_placed_at) - EXTRACT(MONTH FROM c.cohort_month)) AS months_since_first_order
    FROM staging.stg_orders o
    JOIN customer_cohorts c ON o.customer_id = c.customer_id
),
grouped AS (
    SELECT
        f.first_order_had_discount, c.cohort_month, c.months_since_first_order,
        COUNT(DISTINCT c.customer_id) AS active_customers
    FROM cohorting c
    JOIN first_order_flag f ON c.customer_id = f.customer_id
    GROUP BY f.first_order_had_discount, c.cohort_month, c.months_since_first_order
)
SELECT
    first_order_had_discount,
    TO_CHAR(cohort_month, 'YYYY-MM') AS cohort_month,
    months_since_first_order,
    active_customers,
    FIRST_VALUE(active_customers) OVER (
        PARTITION BY first_order_had_discount, cohort_month ORDER BY months_since_first_order
    ) AS cohort_size,
    ROUND(active_customers * 100.0 / NULLIF(FIRST_VALUE(active_customers) OVER (
        PARTITION BY first_order_had_discount, cohort_month ORDER BY months_since_first_order
    ), 0), 2) AS retention_rate
FROM grouped;

CREATE OR REPLACE VIEW marts.priya_kpi4_discount_share AS
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    SUM(total) AS total_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END), 2) AS promo_dependent_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END) * 100.0 / NULLIF(SUM(total), 0), 2) AS pct_promo_dependent
FROM staging.stg_orders
GROUP BY 1;

CREATE OR REPLACE VIEW marts.priya_kpi7_complaint_rate AS
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    COUNT(order_id) AS total_orders,
    COUNT(*) FILTER (WHERE customer_complaint_tag IS NOT NULL) AS complaint_count,
    ROUND(COUNT(*) FILTER (WHERE customer_complaint_tag IS NOT NULL) * 100.0 / COUNT(*), 2) AS complaint_rate_per_100
FROM staging.stg_orders
WHERE order_status NOT IN ('Timed out', 'Rejected')
GROUP BY 1;

-- -----------------------------------------------------------------------------
-- STEP 5 — Recreate Arjun's remaining marts
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW marts.arjun_restaurant_late_rate AS
SELECT
    restaurant_name,
    ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
GROUP BY restaurant_name;

CREATE OR REPLACE VIEW marts.arjun_kpi6_partner_concentration AS
WITH partner_orders AS (
    SELECT
        TO_CHAR(o.order_placed_at, 'YYYY-MM') AS order_month,
        o.subzone, d.partner_id,
        COUNT(DISTINCT o.order_id) AS partner_orders
    FROM staging.stg_orders o
    JOIN staging.stg_delivery_ops d ON o.order_id = d.order_id
    GROUP BY 1, 2, 3
),
top_partners AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY order_month, subzone ORDER BY partner_orders DESC) AS row_num,
        SUM(partner_orders) OVER (PARTITION BY order_month, subzone) AS subzone_total_orders
    FROM partner_orders
)
SELECT
    order_month, subzone, partner_id AS top_partner_id, partner_orders AS top_partner_orders,
    subzone_total_orders,
    ROUND(partner_orders * 100.0 / subzone_total_orders, 2) AS top_partner_pct
FROM top_partners
WHERE row_num = 1;

CREATE OR REPLACE VIEW marts.arjun_kpi2_rolling_3month AS
SELECT
    order_month, monthly_deliverable_orders, monthly_late_orders,
    SUM(monthly_late_orders) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS rolling_late_count,
    SUM(monthly_deliverable_orders) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS rolling_deliverable_count,
    ROUND(SUM(monthly_late_orders) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) * 100.0 /
        NULLIF(SUM(monthly_deliverable_orders) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0), 2) AS rolling_3month_late_rate_pct
FROM (
    SELECT TO_CHAR(order_placed_at, 'YYYY-MM') AS order_month,
        COUNT(*) FILTER (WHERE delivery_status = 'late') AS monthly_late_orders,
        COUNT(*) FILTER (WHERE delivery_status != 'not_deliverable') AS monthly_deliverable_orders
    FROM marts.arjun_delivery_segment
    GROUP BY 1
) t;

CREATE OR REPLACE VIEW marts.arjun_partner_outliers AS
WITH aggregating_late_rate AS (
    SELECT
        partner_id, COUNT(*) AS delivery_count, COUNT(*) < 30 AS is_low_volume,
        ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct
    FROM marts.arjun_delivery_segment
    WHERE delivery_status != 'not_deliverable'
    GROUP BY partner_id
),
calculated_stats AS (
    SELECT *, ROUND(AVG(late_rate_pct) OVER (), 2) AS late_rate_mean, ROUND(STDDEV(late_rate_pct) OVER (), 2) AS late_rate_stddev
    FROM aggregating_late_rate
),
flagged_partners AS (
    SELECT *, late_rate_pct > late_rate_mean + (2 * late_rate_stddev) AS late_rate_flag
    FROM calculated_stats
),
clean_baseline_stats AS (
    SELECT ROUND(AVG(late_rate_pct), 2) AS clean_mean, ROUND(STDDEV(late_rate_pct), 2) AS clean_stddev
    FROM flagged_partners WHERE late_rate_flag = FALSE
)
SELECT f.partner_id, f.delivery_count, f.is_low_volume, f.late_rate_pct,
    c.clean_mean, c.clean_stddev,
    ROUND(c.clean_mean + (2 * c.clean_stddev), 2) AS clean_threshold,
    f.late_rate_pct > c.clean_mean + (2 * c.clean_stddev) AS flagged_on_clean_baseline
FROM flagged_partners f CROSS JOIN clean_baseline_stats c;

CREATE OR REPLACE VIEW marts.arjun_kpi3_dlf_band1 AS
SELECT
    TO_CHAR(order_placed_at, 'YYYY-MM') AS order_month,
    COUNT(*) AS deliverable_orders,
    ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
    AND subzone = 'dlf phase 1' AND distance_band = 'Band_1'
GROUP BY 1;

-- =============================================================================
-- DONE. Verify each mart returns rows before going back to Power BI:
-- SELECT COUNT(*) FROM marts.arjun_delivery_segment;
-- SELECT * FROM marts.priya_promo_dependency LIMIT 10;
-- (etc. for each view above)
-- Then in Power BI: Refresh — all existing visuals should still work (same
-- view names), and Get Data again if any new views aren't showing yet.
-- =============================================================================
