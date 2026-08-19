-- =============================================================================
-- Arjun Mehta — Zone/Distance Confound Analysis
-- Business question: is DLF Phase 1 / Sector 4's escalation a real zone problem,
-- or just because those zones' deliveries tend to be further? Only a same-
-- distance-band comparison isolates a real zone effect from a distance effect.
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
),
delivery_segement AS (
    SELECT o.*, d.partner_id, d.was_reassigned,
        CASE WHEN d.is_late = 1 THEN 'late' WHEN d.is_late = 0 THEN 'on_time' WHEN d.is_late IS NULL THEN 'not_deliverable' END AS delivery_status,
        CASE
            WHEN o.distance_km <= 1 THEN 'Band_1'
            WHEN o.distance_km <= 3 THEN 'Band_2'
            WHEN o.distance_km <= 5 THEN 'Band_3'
            WHEN o.distance_km > 5 THEN 'Band_4'
        END AS distance_band
    FROM food_delivery_db.staging.stg_orders o
    LEFT JOIN deduped_ops d ON o.order_id = d.order_id
)

-- Late rate by subzone WITHIN the same distance band
SELECT
    subzone, distance_band,
    COUNT(*) AS deliverable_orders,
    ROUND(COUNT_IF(delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM delivery_segement
WHERE delivery_status != 'not_deliverable'
GROUP BY subzone, distance_band
ORDER BY late_rate_pct DESC;
/*
FINDING — DLF Phase 1 at 26.07% late for <=1km deliveries vs. 8-15% for every
other zone at the same distance — a REAL zone effect, shrinking sharply at
longer distances (10.37%, 10.99%, 8.31% for bands 2-4). Sector 4 shows NO such
pattern at any distance — its escalations are explained by distance/volume,
not a genuine zone issue.

Three candidate explanations tested:
1. KPT duration: elevated only ~1-1.5 min in DLF Band_1 vs its own other bands.
2. Rider wait: elevated only ~0.7-0.8 min.
3. Partner mix: ruled out entirely — the 4 bad-apple partners are NOT
   overrepresented in this zone/band (2 have zero deliveries here); DP0041
   handles 39.69% of this slice — a separate concentration-risk finding.
Combined KPT+wait account for ~2-2.5 min against a 15-20pp gap — a small
fraction of the effect. Traffic/road conditions are plausible but structurally
UNTESTABLE with this data (synthetic transit model has no zone-specific term).

RECOMMENDATION: escalate for on-the-ground investigation (physical route/
traffic audit) — the honest limit of what SQL analysis alone can resolve.
*/


-- Restaurant prep time (KPT) by subzone + distance band — testing hypothesis 1
SELECT
    subzone, distance_band,
    COUNT(*) AS order_count,
    ROUND(AVG(kpt_duration_minutes), 2) AS avg_kpt_minutes,
    COUNT(*) < 30 AS is_low_volume
FROM delivery_segement
WHERE delivery_status != 'not_deliverable'
GROUP BY 1, 2
ORDER BY avg_kpt_minutes DESC;


-- Rider pickup wait by subzone + distance band — testing hypothesis 2
SELECT
    subzone, distance_band,
    COUNT(*) AS order_count,
    ROUND(AVG(rider_wait_time_minutes), 2) AS avg_rider_wait_minutes,
    COUNT(*) < 30 AS is_low_volume
FROM delivery_segement
WHERE delivery_status != 'not_deliverable'
GROUP BY 1, 2
ORDER BY avg_rider_wait_minutes DESC;


-- Partner assignment mix within DLF Phase 1 Band_1 — testing hypothesis 3
SELECT
    partner_id,
    COUNT(*) AS order_count,
    ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS pct_of_dlf_band1_orders
FROM delivery_segement
WHERE subzone = 'dlf phase 1' AND distance_band = 'Band_1' AND delivery_status != 'not_deliverable'
GROUP BY 1
ORDER BY pct_of_dlf_band1_orders DESC;
