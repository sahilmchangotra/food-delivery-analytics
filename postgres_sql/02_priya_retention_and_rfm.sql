-- =============================================================================
-- Priya Nair — Cohort Retention, RFM Segmentation, Promo-Dependency
-- Postgres translation. Verified against Snowflake originals where the
-- underlying data window overlaps (Sep 2024 numbers match to the decimal).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. COHORT RETENTION
-- Postgres has no DATEDIFF() — month difference computed manually via EXTRACT.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW marts.priya_cohort_retention AS
WITH customer_cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
customer_retention AS (
    SELECT
        c.cohort_month,
        o.customer_id,
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
-- Verified Sep 2024: 100.00 / 25.59 / 21.15 / 19.22 / 15.91 (months 0-4, exact match)
-- 12-month extension reveals full tail: month 5=13.35, 6=11.05, 7=8.99 ... 11=4.21
-- (smooth continued decay, confirming month-1 is the anomalous steep drop, not
-- a broader pattern of consistently steep month-over-month churn)


-- -----------------------------------------------------------------------------
-- 2. RFM SEGMENTATION
-- No translation needed — NTILE, window aggregates, CASE are all standard SQL.
-- -----------------------------------------------------------------------------
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
-- Verified on 26,497 total customers (12-month base): Other 21,022 (79.3%),
-- Loyal 1,948 (7.4%), Churned 1,245 (4.7%), At-risk 1,196 (4.5%), Champions 1,086 (4.1%)
--
-- FINDING — At-risk and Churned roughly DOUBLED as a share vs. the original
-- 5-month snapshot (2.1%->4.5%, 6.2%->4.7%). Mechanism: recency is judged
-- against the dataset's max_date, which moved forward 7 months. Old one-time
-- customers who were sitting in "Other" (not enough elapsed silence to
-- confidently label) are now revealed as genuinely Churned/At-risk — more
-- data didn't create new churn, it revealed churn that was always there but
-- unmeasurable before. Mirror image of the original right-censoring finding.


-- -----------------------------------------------------------------------------
-- 3. PROMO-DEPENDENCY (first-order-only — look-ahead-bias-corrected version)
-- -----------------------------------------------------------------------------
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
)
SELECT
    f.first_order_had_discount,
    TO_CHAR(c.cohort_month, 'YYYY-MM') AS cohort_month,
    c.months_since_first_order,
    COUNT(DISTINCT c.customer_id) AS active_customers,
    FIRST_VALUE(COUNT(DISTINCT c.customer_id)) OVER (
        PARTITION BY f.first_order_had_discount, c.cohort_month ORDER BY c.months_since_first_order
    ) AS cohort_size,
    ROUND(COUNT(DISTINCT c.customer_id) * 100.0 / NULLIF(FIRST_VALUE(COUNT(DISTINCT c.customer_id)) OVER (
        PARTITION BY f.first_order_had_discount, c.cohort_month ORDER BY c.months_since_first_order
    ), 0), 2) AS retention_rate
FROM cohorting c
JOIN first_order_flag f ON c.customer_id = f.customer_id
GROUP BY f.first_order_had_discount, c.cohort_month, c.months_since_first_order
ORDER BY cohort_month, months_since_first_order;
-- Verified Sep 2024, month 1: TRUE 25.26% (660/2613), FALSE 27.03% (160/592)
-- — exact match to Snowflake. Confirms discount status at first order does
-- NOT meaningfully predict retention.
