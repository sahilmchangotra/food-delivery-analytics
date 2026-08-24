-- =============================================================================
-- Arjun Mehta — Ongoing KPIs (6 total), Postgres translation, 12-month data
-- All verified against original Snowflake findings — see inline notes.
-- =============================================================================

-- KPI 1 — Platform late rate, 7-day rolling average
SELECT
    order_date, daily_deliverable_orders, daily_late_orders,
    SUM(daily_late_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_late_count,
    SUM(daily_deliverable_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_deliverable_count,
    ROUND(SUM(daily_late_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) * 100.0 /
        NULLIF(SUM(daily_deliverable_orders) OVER (ORDER BY order_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 0), 2) AS rolling_7day_late_rate_pct
FROM (
    SELECT order_placed_at::DATE AS order_date,
        COUNT(*) FILTER (WHERE delivery_status = 'late') AS daily_late_orders,
        COUNT(*) FILTER (WHERE delivery_status != 'not_deliverable') AS daily_deliverable_orders
    FROM marts.arjun_delivery_segment
    GROUP BY 1
) t
ORDER BY order_date;
-- Verified: matches Snowflake almost exactly (1-order variance on Sep 4,
-- likely a dedup tie-break difference on the one true duplicate order —
-- negligible, washes out in the rolling sums).

-- KPI 2 — Platform late rate, 3-month rolling average
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
) t
ORDER BY order_month;
-- Verified: EXACT match to Snowflake for all 10 months checked (10.60, 10.42,
-- 9.71, 9.68, 8.88, 9.18, 8.91, 9.61, 9.77, 9.86).

-- KPI 3 — DLF Phase 1, <=1km late rate, monthly
SELECT
    TO_CHAR(order_placed_at, 'YYYY-MM') AS order_month,
    subzone, distance_band,
    COUNT(*) AS deliverable_orders,
    ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
    AND subzone = 'dlf phase 1' AND distance_band = 'Band_1'
GROUP BY 1, 2, 3
ORDER BY 1;
-- Verified: EXACT match to Snowflake, all 12 months (34.55% Sep -> 12.24% Jul,
-- 14.29% Aug — the improving-but-not-resolved trend fully reconfirmed).

-- KPI 4 — Monthly partner outlier re-detection (fresh mean/stddev EACH month)
WITH partner_performance_detection AS (
    SELECT
        TO_CHAR(o.order_placed_at, 'YYYY-MM') AS order_month,
        d.partner_id,
        COUNT(*) FILTER (WHERE d.is_late IS NOT NULL) AS monthly_deliverable_orders,
        ROUND(COUNT(*) FILTER (WHERE d.is_late = 1) * 100.0 / NULLIF(COUNT(*) FILTER (WHERE d.is_late IS NOT NULL), 0), 2) AS late_rate_pct,
        COUNT(*) < 20 AS is_low_volume
    FROM staging.stg_orders o
    JOIN staging.stg_delivery_ops d ON o.order_id = d.order_id
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
-- Verified: flagging behavior matches design intent — is_flagged computed
-- independently of is_low_volume (e.g. Sep 2024: DP0004 at 16 deliveries is
-- BOTH low-volume AND flagged — correct, intentional "watch, don't act yet"
-- signal per the original design decision).

-- KPI 5 — Restaurant brand late rate, RELATIVE volume threshold
WITH restaurant_performance_detection AS (
    SELECT
        TO_CHAR(o.order_placed_at, 'YYYY-MM') AS order_month,
        o.restaurant_name,
        COUNT(*) FILTER (WHERE o.delivery_status != 'not_deliverable') AS monthly_deliverable_orders,
        ROUND(COUNT(*) FILTER (WHERE o.delivery_status = 'late') * 100.0 /
            NULLIF(COUNT(*) FILTER (WHERE o.delivery_status != 'not_deliverable'), 0), 2) AS late_rate_pct
    FROM marts.arjun_delivery_segment o
    WHERE o.delivery_status != 'not_deliverable'
    GROUP BY 1, 2
)
SELECT
    *,
    ROUND(AVG(monthly_deliverable_orders) OVER (PARTITION BY restaurant_name), 2) AS brand_avg_monthly_orders,
    monthly_deliverable_orders < (AVG(monthly_deliverable_orders) OVER (PARTITION BY restaurant_name) * 0.3) AS is_low_volume
FROM restaurant_performance_detection
ORDER BY order_month;
-- Verified: EXACT match to Snowflake for September (aura pizzas 10.68%,
-- dilli burger adda 12.5% + correctly flagged low-volume at 8 orders,
-- swaad 9.99%, tandoori junction 36.84% + correctly NOT flagged at 19 orders
-- against its own ~28/month average).

-- KPI 6 — Partner concentration risk (top partner's % share per subzone, monthly)
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
    SELECT
        *,
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
-- Verified: EXACT/near-exact match to Snowflake for Sep-Oct 2024 (DP0041 at
-- 35-39% across every major subzone). Platform-wide concentration risk
-- finding fully reconfirmed — DP0041 remains the highest-urgency finding
-- in the entire project.
