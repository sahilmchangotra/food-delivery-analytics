-- =============================================================================
-- Arjun Mehta — Head of Delivery Operations
-- Projects 1-3: Root Cause, Counterfactual Impact, Outlier Detection
-- =============================================================================

-- Shared base CTE chain used throughout Arjun's analysis. Grain of
-- stg_delivery_ops is (order_id, partner_id) — NOT order_id alone, since 29
-- orders have legitimate mid-delivery reassignments (2 real rows each).
-- delivery_segement resolves this: first-assigned partner kept, was_reassigned
-- flag preserved, three-way delivery_status (late/on_time/not_deliverable)
-- since Rejected/Timed-out/Picked-up orders never reached a rider.

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
),
delivery_segement AS (
    SELECT o.*, d.partner_id, d.was_reassigned,
        CASE WHEN d.is_late = 1 THEN 'late' WHEN d.is_late = 0 THEN 'on_time' WHEN d.is_late IS NULL THEN 'not_deliverable' END AS delivery_status
    FROM food_delivery_db.staging.stg_orders o
    LEFT JOIN deduped_ops d ON o.order_id = d.order_id
)

-- -----------------------------------------------------------------------------
-- PROJECT 1 — Root-cause breakdown: restaurant, zone, partner
-- -----------------------------------------------------------------------------
SELECT
    restaurant_name,
    ROUND(COUNT_IF(delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM delivery_segement
WHERE delivery_status != 'not_deliverable'
GROUP BY restaurant_name
ORDER BY late_rate_pct DESC;
/*
FINDING — tandoori junction and dilli burger adda: 14-25% late, brand-wide
(every outlet), vs. 5-11% for other brands. 4 of 50 partners run 39.55-50.59%
late — 4-5x platform baseline. Several extreme zone-level rates were volume
artifacts (single-order 100% rates), flagged rather than reported at face value.
*/


-- -----------------------------------------------------------------------------
-- PROJECT 2 — Counterfactual impact: fixing partners vs. fixing restaurants
-- -----------------------------------------------------------------------------
-- (platform_total + bad_apples_total CTEs, comparing actual vs. hypothetical
-- late rate if the 4 bad-apple partners performed at the clean 8.21% baseline)
/*
FINDING — Fixing the 4 partners projects platform late rate 9.49% -> 8.31%
(1.18pp improvement). Fixing the 2 restaurant brands barely moves the platform
number (clean-baseline 9.36% vs actual 9.49%) because they're <2% of volume.
RECOMMENDATION: prioritize the partner fix as the primary KR2 lever; track the
restaurant issue separately as a lower-priority service-quality initiative.
*/


-- -----------------------------------------------------------------------------
-- PROJECT 3 — Partner outlier detection (2-SD, verified robust to self-contamination)
-- -----------------------------------------------------------------------------
WITH aggregating_late_rate AS (
    SELECT
        partner_id,
        COUNT(*) AS delivery_count,
        COUNT(*) < 30 AS is_low_volume,
        ROUND(COUNT_IF(delivery_status = 'late') * 100.0 / NULLIF(COUNT(delivery_status), 0), 2) AS late_rate_pct
    FROM delivery_segement
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
/*
FINDING — 4 partners flagged (mean 11.11%, stddev 10.24%, contaminated by the
outliers themselves). Recomputing the baseline EXCLUDING those 4 (clean mean
8.21%, stddev 2.21% — 4.6x tighter) — all 4 STILL exceed the new, stricter
threshold (12.63%) by a wide margin. Not a detection-method artifact.
RECOMMENDATION: escalate for individual performance review; re-run quarterly.
*/
