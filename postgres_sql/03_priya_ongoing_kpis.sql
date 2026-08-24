-- =============================================================================
-- Priya Nair — Ongoing KPIs (7 total), Postgres translation, 12-month data
-- =============================================================================

-- KPI 1 — Repeat-order rate within 30 days of first order
CREATE OR REPLACE VIEW marts.priya_kpi1_repeat_30d AS
WITH customer_cohorts AS (
    SELECT customer_id, MIN(order_placed_at::DATE) AS first_order_date,
        DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
returned_customers AS (
    SELECT customer_id, order_placed_at::DATE AS order_date,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_placed_at::DATE) AS rn
    FROM staging.stg_orders
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
    COUNT(*) FILTER (WHERE second_order_date - first_order_date <= 30) AS repeat_within_30d_count,
    ROUND(COUNT(*) FILTER (WHERE second_order_date - first_order_date <= 30) * 100.0 / NULLIF(MAX(cohort_size), 0), 2) AS repeat_rate_30d_pct
FROM order_summary
GROUP BY cohort_month ORDER BY cohort_month;
-- Verified Sep 2024: 30.42% (975/3205) — exact match. Note: date subtraction
-- on two DATE columns returns plain integer days in Postgres, no DATEDIFF needed.

-- KPI 2 — Month-1 retention (reuse priya_cohort_retention, filter months_since_first_order = 1)

-- KPI 3 — % revenue from one-time customers, by cohort
CREATE OR REPLACE VIEW marts.priya_kpi3_onetime_revenue AS
WITH customer_cohort AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
orders_with_discount AS (
    SELECT customer_id, COUNT(*) AS total_orders, SUM(total) AS total_revenue
    FROM staging.stg_orders GROUP BY customer_id
)
SELECT
    TO_CHAR(c.cohort_month, 'YYYY-MM') AS cohort_month,
    ROUND(SUM(CASE WHEN o.total_orders = 1 THEN o.total_revenue ELSE 0 END), 2) AS one_time_customer_revenue,
    ROUND(SUM(o.total_revenue), 2) AS total_cohort_revenue,
    ROUND(SUM(CASE WHEN o.total_orders = 1 THEN o.total_revenue ELSE 0 END) * 100.0 / SUM(o.total_revenue), 2) AS pct_one_time
FROM customer_cohort c
JOIN orders_with_discount o ON c.customer_id = o.customer_id
GROUP BY c.cohort_month ORDER BY c.cohort_month;
-- Verified Sep 2024: 14.68% on 12-month data (vs 17.93% on original 5-month).
-- INVESTIGATED, not a bug: one-time revenue numerator is FROZEN at 972,874.33
-- because ZERO of September's 1,585 one-time customers ever placed a second
-- order in the following 7 months (confirmed via direct bypass query). The
-- % dropped purely because the denominator (repeat-customer revenue) kept
-- growing. FINDING: "one-time" customers appear to be a stable, near-permanent
-- classification once established, not a transitional state.

-- KPI 4 — Discount-dependent revenue share, monthly (order-level, no translation needed)
CREATE OR REPLACE VIEW marts.priya_kpi4_discount_share AS
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    SUM(total) AS total_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END), 2) AS promo_dependent_revenue,
    ROUND(SUM(CASE WHEN discount_construct IS NOT NULL THEN total ELSE 0 END) * 100.0 / NULLIF(SUM(total), 0), 2) AS pct_promo_dependent
FROM staging.stg_orders
GROUP BY 1 ORDER BY 1;
-- Verified Sep-Dec 2024: 79.96/75.42/77.09/65.01 — exact match to Snowflake.

-- KPI 5 — New Champions conversion rate, by cohort (RATE, controlled for cohort size)
CREATE OR REPLACE VIEW marts.priya_kpi5_champions_rate AS
WITH customer_cohort AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM customer_cohort GROUP BY cohort_month
)
SELECT
    TO_CHAR(c.cohort_month, 'YYYY-MM') AS cohort_month,
    cz.cohort_size,
    COUNT(*) FILTER (WHERE s.rfm_segment = 'Champions') AS new_champions_count,
    ROUND(COUNT(*) FILTER (WHERE s.rfm_segment = 'Champions') * 100.0 / cz.cohort_size, 2) AS champion_conversion_rate
FROM customer_cohort c
JOIN cohort_sizes cz ON c.cohort_month = cz.cohort_month
JOIN marts.priya_rfm_segments s ON c.customer_id = s.customer_id
GROUP BY c.cohort_month, cz.cohort_size
ORDER BY c.cohort_month;
-- 12-month result: Nov 2024 is the low point (3.4%), rises to 9.7% by Apr 2025,
-- then May-Aug 2025 show a HARD 0.00% — VERIFIED as mathematically correct,
-- not a bug: max frequency across these cohorts tops out at 1-4 orders
-- (Champions requires f_score=4, i.e. 5+ orders — structurally impossible
-- yet given how little time these cohorts have had).

-- KPI 6 — At-risk count, mature cohorts only (2+ months old)
CREATE OR REPLACE VIEW marts.priya_kpi6_atrisk_mature AS
WITH ref AS (
    SELECT MAX(order_placed_at::DATE) AS recent_order_date FROM staging.stg_orders
),
customer_cohort AS (
    SELECT customer_id, DATE_TRUNC('month', MIN(order_placed_at)) AS cohort_month
    FROM staging.stg_orders GROUP BY customer_id
)
SELECT
    TO_CHAR(c.cohort_month, 'YYYY-MM') AS cohort_month,
    COUNT(*) FILTER (
        WHERE s.rfm_segment = 'At-risk'
        AND (EXTRACT(YEAR FROM r.recent_order_date) - EXTRACT(YEAR FROM c.cohort_month)) * 12
            + (EXTRACT(MONTH FROM r.recent_order_date) - EXTRACT(MONTH FROM c.cohort_month)) >= 2
    ) AS at_risk_count
FROM customer_cohort c
CROSS JOIN ref r
JOIN marts.priya_rfm_segments s ON c.customer_id = s.customer_id
GROUP BY c.cohort_month ORDER BY c.cohort_month;
-- 12-month result: Sep 618 -> Jan 55, then Feb-Aug 2025 all show 0 — VERIFIED
-- genuine (not a filter bug): Feb 2025 cohort (2,273 real customers) has
-- ZERO customers labeled At-risk at all, even before the maturity filter.
-- Consistent with the core finding that attrition happens fast (month 1) —
-- a cohort either churns immediately (visible as Churned) or stays active;
-- At-risk may be a narrower, more transient window than assumed.

-- KPI 7 — Complaint rate per 100 orders, monthly (no translation needed)
CREATE OR REPLACE VIEW marts.priya_kpi7_complaint_rate AS
SELECT
    TO_CHAR(DATE_TRUNC('month', order_placed_at), 'YYYY-MM') AS order_month,
    COUNT(order_id) AS total_orders,
    COUNT(*) FILTER (WHERE customer_complaint_tag IS NOT NULL) AS complaint_count,
    ROUND(COUNT(*) FILTER (WHERE customer_complaint_tag IS NOT NULL) * 100.0 / COUNT(*), 2) AS complaint_rate_per_100
FROM staging.stg_orders
WHERE order_status NOT IN ('Timed out', 'Rejected')
GROUP BY 1 ORDER BY 1;
-- Verified Sep 2024-Jan 2025: 1.38/2.44/2.81/2.09/2.34 — exact match.
