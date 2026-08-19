-- =============================================================================
-- Priya Nair — Ongoing KPIs (7 total)
-- STANDING CAVEAT: any metric depending on elapsed time since a customer's
-- first order (KPIs 1, 3, 5, 6) looks artificially worse for younger cohorts —
-- not real behavior, just insufficient time to be fairly measured. This is
-- right-censoring, confirmed independently across three KPIs below.
-- =============================================================================

-- KPI 1 — Repeat-order rate within 30 days of first order (monthly, per cohort)
WITH customer_first_order AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM food_delivery_db.staging.stg_orders GROUP BY customer_id
),
cohorting AS (
    SELECT o.customer_id, o.order_id, r.cohort_month,
        DATEDIFF('month', r.cohort_month, o.order_placed_at) AS months_since_first_order
    FROM food_delivery_db.staging.stg_orders o
    JOIN customer_first_order r ON o.customer_id = r.customer_id
),
customer_cohorts AS (
    SELECT customer_id, MIN(order_placed_at::DATE) AS first_order_date,
        DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM food_delivery_db.staging.stg_orders GROUP BY customer_id
),
returned_customers AS (
    SELECT customer_id, order_placed_at::DATE AS order_date,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_placed_at::DATE) AS rn
    FROM food_delivery_db.staging.stg_orders
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM customer_cohorts GROUP BY cohort_month
),
order_summary AS (
    SELECT c.cohort_month, c.first_order_date, r.order_date AS second_order_date, cz.cohort_size
    FROM customer_cohorts c
    JOIN cohort_sizes cz ON c.cohort_month = cz.cohort_month
    LEFT JOIN returned_customers r ON c.customer_id = r.customer_id AND r.rn = 2
)
SELECT
    TO_CHAR(cohort_month, 'YYYY-MM') AS cohort_month,
    MAX(cohort_size) AS cohort_size,
    COUNT_IF(DATEDIFF('day', first_order_date, second_order_date) <= 30) AS repeat_within_30d_count,
    ROUND(COUNT_IF(DATEDIFF('day', first_order_date, second_order_date) <= 30) * 100.0 /
        NULLIF(MAX(cohort_size), 0), 2) AS repeat_rate_30d_pct
FROM order_summary
GROUP BY cohort_month
ORDER BY cohort_month;
/* KPI 1 — Sep 30.42% -> Dec 18.43% real decline (Sep-Dec windows never censored,
already fully inside original data). Extended-data caveat: NOT reliable for
day-level rolling windows past Jan 2025 — see 12-month extension notes. */


-- KPI 2 — Month-1 retention rate (calendar-month grain — immune to censoring)
-- (reuse the cohort retention query above, filtered to months_since_first_order = 1)
/* KPI 2 — Sep 25.59% -> Dec 15.36%, confirmed REAL (not censoring artifact) on
re-test with 12-month extension: Sep-Dec unchanged, Jan resolved (17.60%).
Most trustworthy trend signal in the whole KPI set. */


-- KPI 3 — % of revenue from one-time customers, by cohort
WITH customer_cohort AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM food_delivery_db.staging.stg_orders GROUP BY customer_id
),
orders_with_discount AS (
    SELECT customer_id, COUNT(*) AS total_orders, SUM(total) AS total_revenue
    FROM food_delivery_db.staging.stg_orders GROUP BY customer_id
)
SELECT
    TO_CHAR(c.cohort_month, 'YYYY-MM') AS cohort_month,
    ROUND(SUM(CASE WHEN o.total_orders = 1 THEN o.total_revenue ELSE 0 END), 2) AS one_time_customer_revenue,
    ROUND(SUM(o.total_revenue), 2) AS total_cohort_revenue,
    ROUND(SUM(CASE WHEN o.total_orders = 1 THEN o.total_revenue ELSE 0 END) * 100.0 / SUM(o.total_revenue), 2) AS pct_one_time
FROM customer_cohort c
JOIN orders_with_discount o ON c.customer_id = o.customer_id
GROUP BY c.cohort_month ORDER BY c.cohort_month;
/* KPI 3 — 17.93% Sep -> 72.02% Jan. Right-censoring artifact — original 37%
static baseline was a blend of mature and censored cohorts. Only report/act
on cohort-months with 2+ months of history. */


-- KPI 4 — Discount-dependent revenue share, monthly (order-level, NOT censored)
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    SUM(total) AS total_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END), 2) AS promo_dependent_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END) * 100.0 / NULLIF(SUM(total), 0), 2) AS pct_promo_dependent
FROM food_delivery_db.staging.stg_orders
GROUP BY 1 ORDER BY 1;
/* KPI 4 — Stable 65-80% band, no trend. Order-level + month-scoped, so it's
structurally immune to right-censoring — the one KPI safe to compare directly
across all months by design, not just luck. Flag any month outside 65-80%. */


-- KPI 5 — New Champions conversion rate, by cohort (rate, not raw count)
-- (customer_labels/segmenting CTE from priya_retention_and_rfm.sql, joined to
-- customer_cohorts, GROUP BY cohort_month, COUNT(DISTINCT customer_id) WHERE
-- rfm_segment = 'Champions' / cohort_size)
/* KPI 5 — 7.33% Sep -> 1.64% Dec, even after controlling for cohort size.
Champions requires 5+ orders + top-quintile spend + high recency — real elapsed
time to accumulate. Only Sep has had the full window; treat Oct-Dec as
provisional floors, not final quality readings. */


-- KPI 6 — At-risk count, mature cohorts only (2+ months old)
/* KPI 6 — 250 customers restricted to mature cohorts vs. 247 unrestricted —
minimal practical difference, since At-risk requires low recency by definition
(naturally concentrated in older cohorts already). Breakdown: Sep 190 (76%),
Oct 58, Nov 2. Track by cohort_month — concentration is the actionable insight. */


-- KPI 7 — Complaint rate per 100 orders, monthly
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    COUNT(order_id) AS total_orders,
    COUNT_IF(customer_complaint_tag IS NOT NULL) AS complaint_count,
    ROUND(COUNT_IF(customer_complaint_tag IS NOT NULL) * 100.0 / COUNT(*), 2) AS complaint_rate_per_100
FROM food_delivery_db.staging.stg_orders
WHERE order_status NOT IN ('Timed out', 'Rejected')
GROUP BY 1 ORDER BY 1;
/* KPI 7 — 1.38% Sep, peaks 2.81% Nov, eases to 2.34% Jan. Worth checking if
November's peak correlates with any known operational event. */
