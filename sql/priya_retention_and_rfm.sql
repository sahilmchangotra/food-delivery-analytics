-- =============================================================================
-- Priya Nair — Head of Customer Retention & Growth
-- Cohort Retention, RFM Segmentation, and Promo-Dependency Analysis
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. COHORT RETENTION
-- Business question: is retention improving or declining as a TREND over time?
-- -----------------------------------------------------------------------------
WITH customer_cohorts AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM food_delivery_db.staging.stg_orders
    GROUP BY customer_id
),
customer_retention AS (
    SELECT
        c.cohort_month,
        o.customer_id,
        DATEDIFF('month', c.cohort_month, DATE_TRUNC('month', o.order_placed_at)) AS months_since_first_order
    FROM food_delivery_db.staging.stg_orders o
    JOIN customer_cohorts c ON o.customer_id = c.customer_id
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(customer_id) AS cohort_size
    FROM customer_cohorts
    GROUP BY cohort_month
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

/*
FINDING — Customer retention drops off steeply and immediately, not gradually.
Retention falls from 100% at month 0 to roughly 20-26% by month 1 alone across
every cohort observed — a structural feature of the business, not a one-off.
RECOMMENDATION: concentrate retention efforts on the immediate post-first-order
window (days, not months) — that's where the overwhelming majority of loss happens.
*/


-- -----------------------------------------------------------------------------
-- 2. RFM SEGMENTATION
-- Business question: who is valuable RIGHT NOW, independent of trend?
-- Note: Frequency uses fixed bands, not quintiles — NTILE(5) broke down because
-- 66% of customers share frequency=1, forcing an arbitrary tie-split across bands.
-- -----------------------------------------------------------------------------
WITH ref AS (
    SELECT MAX(order_placed_at::DATE) AS recent_order_date
    FROM food_delivery_db.staging.stg_orders
),
customer_base AS (
    SELECT
        customer_id,
        MAX(recent_order_date) - MAX(order_placed_at::DATE) AS recency_days,
        COUNT(DISTINCT order_id) AS frequency_orders,
        SUM(total) AS monetary_total
    FROM food_delivery_db.staging.stg_orders, ref
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

/*
FINDING — Four actionable segments: Champions ~394 (3.4%), Loyal ~1,340 (11.5%),
At-risk 247 (2.1%), Churned ~714 (6.1%), Other ~8,910 (76.7%).
ADDENDUM — "Other" share climbs with cohort youth (57%->90% Sep->Jan) purely
because RFM needs elapsed time to classify a customer — NOT a real quality signal.
Never compare RFM segment shares across cohorts of different ages.
*/


-- -----------------------------------------------------------------------------
-- 3. PROMO-DEPENDENCY (CORRECTED — first-order-only, not lifetime %)
-- IMPORTANT: an earlier version using lifetime discount % showed a large,
-- consistent retention gap favoring promo-dependent customers — DISCARDED after
-- being traced to LOOK-AHEAD BIAS (using future orders to explain past retention).
-- This corrected version uses only each customer's FIRST order, known before
-- any retention outcome exists.
-- -----------------------------------------------------------------------------
WITH ranked_orders AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_placed_at ASC) AS row_num
    FROM food_delivery_db.staging.stg_orders
),
first_order_flag AS (
    SELECT
        customer_id,
        discount_construct IS NOT NULL AS first_order_had_discount
    FROM ranked_orders
    WHERE row_num = 1
),
customer_cohorts AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM food_delivery_db.staging.stg_orders GROUP BY customer_id
),
cohorting AS (
    SELECT
        o.customer_id, c.cohort_month,
        DATEDIFF('month', c.cohort_month, o.order_placed_at) AS months_since_first_order
    FROM food_delivery_db.staging.stg_orders o
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

/*
FINDING 1 — Discount status at first order does NOT predict retention. Gaps of
only 1-5pp, inconsistent in direction (flips in December) — no meaningful effect.

FINDING 2 — Promo-dependent revenue share (>50% lifetime discount usage) is real
but threshold-sensitive: 45.27% at the 50% cutoff, ranging 37.72%-52.64% across
40-70% cutoffs (15pp swing). Report as a RANGE (38-53%), not a single number.

FINDING 3 — That revenue is concentrated, not evenly spread: top 10% of
promo-dependent customers by spend generate 30.78% of the segment's revenue;
top 20% generate 46.6%. A targeted response, not a blanket one, is warranted.

RECOMMENDATION: do not pursue blanket discount reduction. Investigate top-decile
spenders directly; treat one-time customers (37% of revenue) as a distinct,
higher-priority problem; reframe KR1 around the 38-53% range.
*/
