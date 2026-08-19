-- =============================================================================
-- Arjun Mehta — Ongoing KPIs (6 total)
-- =============================================================================

WITH assigned_partners AS (
    SELECT order_id, COUNT(DISTINCT partner_id) AS partners_assigned
    FROM food_delivery_db.staging.stg_delivery_ops GROUP BY order_id
),
ranked_ops AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY partner_id ASC) AS row_num
    FROM food_delivery_db.staging.stg_delivery_ops
),
deduped_ops AS (
    SELECT r.* EXCLUDE(row_num), a.partners_assigned, a.partners_assigned > 1 AS was_reassigned
    FROM ranked_ops r
    LEFT JOIN assigned_partners a ON r.order_id = a.order_id
    WHERE r.row_num = 1
)

-- KPI 1 — Platform late rate, 7-day rolling average
SELECT
    order_date, daily_deliverable_orders, daily_late_orders,
    SUM(daily_late_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_late_count,
    SUM(daily_deliverable_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_deliverable_count,
    ROUND(SUM(daily_late_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) * 100.0 /
        NULLIF(SUM(daily_deliverable_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 0), 2) AS rolling_7day_late_rate_pct
FROM (
    SELECT o.order_placed_at::DATE AS order_date,
        COUNT_IF(d.is_late IS NOT NULL) AS daily_deliverable_orders,
        COUNT_IF(d.is_late = 1) AS daily_late_orders
    FROM food_delivery_db.staging.stg_orders o
    LEFT JOIN deduped_ops d ON o.order_id = d.order_id
    GROUP BY 1
)
ORDER BY order_date;
/* KPI 1&2 — "is something wrong TODAY" (7-day) vs "sustained drift" (3-month,
same query with ROWS BETWEEN 2 PRECEDING for monthly grain). 3-month view holds
~8.9-10.6% across all 12 months — stable, no runaway trend. */


-- KPI 3 — DLF Phase 1, <=1km late rate, monthly
-- (subzone='dlf phase 1' AND distance_km<=1 filter, GROUP BY month)
/* KPI 3 — Improved from worst (34.55% Sep) to best (12.24% Jul) but relapsed to
25.58% Feb 2025 — never sustainably in the 8-15% peer band. "Meaningfully
better, not resolved." Continue tracking; investigate the Feb relapse cause. */


-- KPI 4 — Monthly partner outlier re-detection (fresh mean/stddev EACH month)
WITH partner_performance_detection AS (
    SELECT
        TO_CHAR(DATE_TRUNC('month', o.order_placed_at), 'YYYY-MM') AS order_month,
        d.partner_id,
        COUNT_IF(d.is_late IS NOT NULL) AS monthly_deliverable_orders,
        ROUND(COUNT_IF(d.is_late = 1) * 100.0 / NULLIF(COUNT_IF(d.is_late IS NOT NULL), 0), 2) AS late_rate_pct,
        COUNT(*) < 20 AS is_low_volume
    FROM food_delivery_db.staging.stg_orders o
    JOIN deduped_ops d ON o.order_id = d.order_id
    WHERE d.partner_id IS NOT NULL
    GROUP BY 1, 2
),
with_stats AS (
    SELECT *, ROUND(AVG(late_rate_pct) OVER (PARTITION BY order_month), 2) AS month_mean,
        ROUND(STDDEV(late_rate_pct) OVER (PARTITION BY order_month), 2) AS month_stddev
    FROM partner_performance_detection
)
SELECT *, late_rate_pct > month_mean + (2 * month_stddev) AS is_flagged
FROM with_stats
ORDER BY order_month, late_rate_pct DESC;
/* KPI 4 — 45 flagged partner-months across 12 independent monthly tests —
EVERY ONE belongs to the original 4 bad-apple partners. Zero new partners,
zero false positives. Stronger validation than the one-time finding.
RECOMMENDATION: 12 straight months of failure = direct intervention, not monitoring. */


-- KPI 5 — Restaurant brand late rate, RELATIVE volume threshold (not fixed —
-- brand monthly volumes range 1-3,016, a fixed cutoff can't work across that spread)
WITH restaurant_performace_detection AS (
    SELECT
        TO_CHAR(DATE_TRUNC('month', o.order_placed_at), 'YYYY-MM') AS order_month,
        o.restaurant_name,
        COUNT_IF(d.is_late IS NOT NULL) AS monthly_deliverable_orders,
        ROUND(COUNT_IF(d.is_late = 1) * 100.0 / NULLIF(COUNT_IF(d.is_late IS NOT NULL), 0), 2) AS late_rate_pct
    FROM food_delivery_db.staging.stg_orders o
    JOIN deduped_ops d ON o.order_id = d.order_id
    GROUP BY 1, 2
)
SELECT
    *,
    AVG(monthly_deliverable_orders) OVER (PARTITION BY restaurant_name) AS brand_avg_monthly_orders,
    monthly_deliverable_orders < (AVG(monthly_deliverable_orders) OVER (PARTITION BY restaurant_name) * 0.3) AS is_low_volume
FROM restaurant_performace_detection
ORDER BY order_month;
/* KPI 5 — tandoori junction & dilli burger adda persistently mid-teens to
high-20s late rate across nearly every month — brand-wide issue has NOT
resolved over 12 months, unlike DLF Phase 1's partial recovery. */


-- KPI 6 — Partner concentration risk (top partner's % share per subzone, monthly)
WITH partner_orders AS (
    SELECT
        TO_CHAR(DATE_TRUNC('month', o.order_placed_at), 'YYYY-MM') AS order_month,
        o.subzone, d.partner_id,
        COUNT(DISTINCT o.order_id) AS partner_orders
    FROM food_delivery_db.staging.stg_orders o
    JOIN deduped_ops d ON o.order_id = d.order_id
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
    ROUND(partner_orders * 100.0 / subzone_total_orders, 2) AS top_partner_pct,
    ROUND(partner_orders * 100.0 / subzone_total_orders, 2) > 30 AS is_concentration_risk,
    subzone_total_orders < 100 AS is_low_volume
FROM top_partners
WHERE row_num = 1
ORDER BY order_month;
/*
FINDING — DP0041 is the top partner in 70+ of 76 subzone-months across 12
months, consistently at 30-45% — a PLATFORM-WIDE, sustained resilience risk,
not an isolated zone issue. The single highest-urgency finding in the project.
RECOMMENDATION: active second-partner build-out per zone, with a stated
remediation target (e.g. "no partner above 30% within 6 months") — not
passive monitoring.
*/
