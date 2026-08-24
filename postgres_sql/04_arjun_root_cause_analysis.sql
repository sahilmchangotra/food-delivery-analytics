-- =============================================================================
-- Arjun Mehta — Root Cause Analysis (Postgres translation)
-- STATUS: Base view + Project 1 + Project 3 verified on 12-month data.
-- PENDING: Project 2 (counterfactual impact), zone/distance confound, 6 KPIs.
-- OPEN QUESTION (parked): investigate DP0044 as a possible 5th outlier partner.
-- =============================================================================

-- Shared base view — reused by every Arjun query. Key translation: explicit
-- column list instead of SELECT * EXCLUDE(row_num). distance_band folded in
-- here (was a separate step in the Snowflake version) since multiple
-- downstream queries need it.
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
-- Verified: 48,824 total; late=4,631, on_time=43,783 (48,414 deliverable,
-- matches Snowflake exactly), not_deliverable=410.

-- -----------------------------------------------------------------------------
-- PROJECT 1 — Root-cause breakdown by restaurant brand
-- -----------------------------------------------------------------------------
SELECT
    restaurant_name,
    ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
GROUP BY restaurant_name
ORDER BY late_rate_pct DESC;
-- Verified 12-month result: dilli burger adda 16.16%, tandoori junction 14.67%
-- — both still well above aura pizzas (9.5%), swaad (9.36%), the chicken
-- junction (8.47%), masala junction (2.78%). Brand-wide issue persists across
-- the full 12 months, not just the original 5-month window.

-- -----------------------------------------------------------------------------
-- PROJECT 3 — Partner outlier detection (2-SD, self-contamination-checked)
-- -----------------------------------------------------------------------------
WITH aggregating_late_rate AS (
    SELECT
        partner_id,
        COUNT(*) AS delivery_count,
        COUNT(*) < 30 AS is_low_volume,
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
SELECT f.*, c.clean_mean, c.clean_stddev,
    f.late_rate_pct > c.clean_mean + (2 * c.clean_stddev) AS flagged_on_clean_baseline
FROM flagged_partners f CROSS JOIN clean_baseline_stats c
ORDER BY late_rate_pct DESC;
-- Verified 12-month result: original 4 (DP0004 55.91%, DP0048 46.03%,
-- DP0050 45.62%, DP0046 44.41%) still flagged on both thresholds, now on
-- much larger volumes (186-769 deliveries each). Clean baseline: mean 8.01%,
-- stddev 1.34% (close to the original 5-month clean baseline of 8.21%/2.21%).
--
-- NEW FINDING — DP0044 emerges as a possible 5th outlier: 12.68% late rate on
-- 347 deliveries. Fails the CLEAN threshold (10.69% = 8.01 + 2*1.34) but not
-- the original contaminated one (33.43%) — exactly the scenario the
-- self-contamination check exists to catch. Not present in the original
-- 5-month analysis. PARKED FOR INVESTIGATION: which months did DP0044's
-- lateness concentrate in — newly developed, or previously below detection
-- threshold on less data?
