# Data Dictionary — Food Delivery Analytics Project

**Source:** Real Zomato-style restaurant order export, Delhi NCR, Sep 2024–Jan 2025
(Kaggle: `sujalsuthar/food-delivery-order-history-data`)
**Warehouse:** Snowflake
**Prepared by:** Sahil Changotra

---

## Table 1 — `raw.orders_raw`
**Grain: one row = one order** (except ~40 deliberately duplicated rows — see Known Issues)
**Source: REAL** (with injected warehouse mess)

| Column | Type | Notes |
|---|---|---|
| Restaurant ID | INT | FK to restaurants_dim — 2 IDs orphaned on purpose |
| Restaurant name | STRING | Messy casing/whitespace on ~4% of rows |
| Subzone | STRING | Messy casing/whitespace on ~4% of rows |
| City | STRING | Messy casing/whitespace on ~4% of rows — all real values are "Delhi NCR" |
| Order ID | BIGINT | Unique in source; ~40 duplicate rows injected |
| Order Placed At | STRING | Two formats mixed: `hh:mm AM/PM, Month DD YYYY` (majority) and `YYYY-MM-DD HH:MI:SS` (~5% of rows, simulated second export batch) |
| Order Status | STRING | Delivered / Rejected / Returned / Return cancelled / Picked up / Timed out |
| Distance | STRING | Bucketed km string, e.g. `"3km"`, `"<1km"` |
| Bill subtotal, Packaging charges, discount columns, Total | FLOAT | `Total = Bill subtotal + Packaging − (all 4 discount cols)` holds exactly in source |
| Rating | FLOAT | Only present for ~11.8% of delivered orders (real non-response, not injected) |
| KPT duration (minutes) | FLOAT | Kitchen prep time. 3 rows have injected negative values |
| Rider wait time (minutes) | FLOAT | Extra nulls injected beyond source nulls |
| Order Ready Marked | STRING | Correctly / Incorrectly / Missed (restaurant-side prep quality flag) |
| Customer complaint tag | STRING | Wrong item(s), missing item(s), poor packaging, etc. |
| Customer ID | STRING (hashed) | 11,607 unique customers |

## Table 2 — `raw.restaurants_dim`
**Grain: one row = one restaurant ID (outlet)**
**Source: REAL**, deliberately incomplete

19 of the 21 real restaurant IDs. **2 IDs removed on purpose** to create orphaned foreign keys in `orders_raw` — a real warehouse scenario (a restaurant closes/merges and the dimension table isn't backfilled before the fact table is).

## Table 3 — `raw.delivery_partners_dim`
**Grain: one row = one delivery partner**
**Source: FULLY SYNTHETIC** — the raw export has no partner/rider identity at all (the `Delivery` column is constant `"Zomato Delivery"` for every row)

| Column | Notes |
|---|---|
| partner_id | DP0001–DP0050 |
| vehicle_type | Bike / Scooter / Bicycle |
| home_subzone | One of the 7 real subzones |
| join_date | Synthetic, spread before and during the order window |

## Table 4 — `raw.delivery_ops_fact`
**Grain: one row = one order's delivery attempt** (contains 30 intentional duplicate order_ids — fan-out trap, see Known Issues)
**Source: FULLY SYNTHETIC, documented derivation** — the raw export has no actual delivery timestamp and no stated SLA promise. This table does not represent observed fact; it's a modeled construction, and should be described as such in any writeup or interview.

| Column | Derivation |
|---|---|
| order_id | FK to orders_raw |
| partner_id | Assigned via weighted random draw (Pareto-skewed volume — a few partners handle disproportionate order counts, like real gig-work platforms) |
| promised_sla_minutes | `= round((38 + 3.2 × distance_km) / 5) × 5` — a stand-in for a real platform delivery promise |
| actual_fulfillment_minutes | `= KPT duration (real) + Rider wait time (real) + synthetic distance-based transit time` |
| is_late | `1` if actual > promised, else `0` |

Only orders with status Delivered / Returned / Return cancelled have ops data — Rejected/Timed out orders never reached a rider, so their ops fields are null (not a data quality issue — a real business rule).

---

## Known Issues (injected on purpose — this is your cleaning checklist)

1. **Duplicate Order IDs** in `orders_raw` (~40 rows) — simulated double webhook fire
2. **Duplicate order_ids** in `delivery_ops_fact` (30 rows) — simulated mid-delivery partner reassignment. **This is the fan-out trap** — joining this table to orders without deduping first will silently multiply order counts.
3. **Mixed date formats** in `Order Placed At` (~5% of rows) — two different string formats need normalizing to one timestamp type before any date logic works
4. **Inconsistent casing/whitespace** in City, Subzone, Restaurant name (~4% of rows) — will fragment GROUP BY results if not cleaned first
5. **Orphaned restaurant IDs** — 2 restaurant IDs appear in orders_raw but not in restaurants_dim — an inner join will silently drop these orders; a left join will show NULLs that need a decision (exclude? impute? flag?)
6. **Extra nulls** in KPT duration and Rider wait time beyond the source's real nulls
7. **Impossible values** — 3 rows with negative KPT duration, 3 rows with Rating = 6 (scale is 1-5)

## Documented Modeling Assumptions (not "issues" — deliberate design choices to defend in interviews)

- No delivery partner identity exists in the real data — `delivery_partners_dim` and the partner assignment in `delivery_ops_fact` are fully synthetic
- No actual delivery timestamp or SLA promise exists in the real data — `promised_sla_minutes` and `actual_fulfillment_minutes` are a documented derivation, calibrated so baseline late rate ≈ 9-10% (in line with published industry SLA-miss ranges), with 4 of 50 partners seeded as "bad apples" producing a materially higher late rate
