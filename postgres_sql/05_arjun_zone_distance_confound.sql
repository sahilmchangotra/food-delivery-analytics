-- =============================================================================
-- Arjun Mehta — Zone/Distance Confound Analysis (Postgres translation)
-- Reconfirmed on 12-month data — same conclusion, more decisive.
-- =============================================================================

-- Late rate by subzone WITHIN the same distance band
SELECT
    subzone, distance_band,
    COUNT(*) AS deliverable_orders,
    ROUND(COUNT(*) FILTER (WHERE delivery_status = 'late') * 100.0 / NULLIF(COUNT(*), 0), 2) AS late_rate_pct,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
GROUP BY subzone, distance_band
ORDER BY late_rate_pct DESC;
-- Verified: DLF Phase 1 Band_1 = 21.84% (down from original 26.07% snapshot,
-- consistent with the improving trend already tracked in KPI 3). Still the
-- clear standout at this distance.
--
-- NEW — shahdara Band_3 (15.22%) and Band_4 (13.84%) now stand out more
-- clearly than in the original 5-month analysis, where shahdara was never
-- flagged. PARKED FOR INVESTIGATION alongside DP0044 — real emerging issue,
-- or noise from shahdara's smaller overall volume in this dataset?

-- KPT duration by subzone + distance band
SELECT
    subzone, distance_band, COUNT(*) AS order_count,
    ROUND(AVG(kpt_duration_minutes), 2) AS avg_kpt_minutes,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
GROUP BY 1, 2 ORDER BY avg_kpt_minutes DESC;
-- DLF Phase 1 Band_1: 19.6 min vs its own other bands (18.61-19.06) — ~1 min
-- gap, same small magnitude as original finding. Not the driver.

-- Rider pickup wait by subzone + distance band
SELECT
    subzone, distance_band, COUNT(*) AS order_count,
    ROUND(AVG(rider_wait_time_minutes), 2) AS avg_rider_wait_minutes,
    COUNT(*) < 30 AS is_low_volume
FROM marts.arjun_delivery_segment
WHERE delivery_status != 'not_deliverable'
GROUP BY 1, 2 ORDER BY avg_rider_wait_minutes DESC;
-- DLF Phase 1 Band_1: 6.08 min vs its own other bands (5.43-5.94) — same
-- sub-1-minute gap. Confirms: not the driver.

-- Partner assignment mix within DLF Phase 1 Band_1
SELECT
    partner_id, COUNT(*) AS order_count,
    ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS pct_of_dlf_band1_orders
FROM marts.arjun_delivery_segment
WHERE subzone = 'dlf phase 1' AND distance_band = 'Band_1' AND delivery_status != 'not_deliverable'
GROUP BY 1 ORDER BY pct_of_dlf_band1_orders DESC;
-- DP0041 at 36.86% (vs original 39.69%) — still by far the dominant partner
-- in this slice, next closest DP0043 at 8.36%. DP0044 (the new outlier
-- candidate from Project 3) is NOT concentrated here (only 3 orders, 0.51%)
-- — its emerging problem is unrelated to this specific zone/band.

/*
FINDING RECONFIRMED on 12-month data — DLF Phase 1's short-distance late rate 
is a genuine, isolated zone effect (not distance, not KPT, not rider wait, 
not partner mix), now more decisively supported by 12x the original volume. 
The residual gap remains genuinely unexplained by anything measurable in 
this dataset — same honest conclusion as the original 5-month finding, 
strengthened rather than contradicted by more data.
*/
