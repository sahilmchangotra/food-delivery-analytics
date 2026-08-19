"""
Food Delivery Analytics — Data Preparation Script
Sahil Changotra | Project: Food Delivery Warehouse Simulation (Snowflake)

Source: order_history_kaggle_data.csv (real Zomato-style restaurant order export,
Delhi NCR, Sep 2024 - Jan 2025, 21,321 orders)

This script produces 4 output files, designed to be loaded into a Snowflake
`raw` schema as if they came from 4 different upstream systems:

  1. orders_raw.csv            - the real order export, with warehouse mess injected
  2. restaurants_dim.csv       - clean restaurant dimension (2 IDs deliberately
                                  removed to create an orphaned FK scenario)
  3. delivery_partners_dim.csv - FULLY SYNTHETIC delivery partner dimension
                                  (source data has no partner/rider identity at all)
  4. delivery_ops_fact.csv     - FULLY SYNTHETIC delivery ops fact table
                                  (source data has no actual delivery timestamp
                                  or SLA promise — this is a derived construction,
                                  documented below, not observed fact)

DOCUMENTED ASSUMPTIONS (say this out loud in interviews — don't hide it):
  - promised_sla_minutes = 38 + 3.2 * distance_km, rounded to nearest 5
    (a stand-in for a real platform delivery promise, calibrated so baseline
    late rate lands ~10%, matching published industry SLA-miss ranges)
  - actual_fulfillment_minutes = KPT duration (real) + Rider wait time (real)
    + a synthetic distance-based transit estimate (real distance bucket used
    to drive a believable transit time, since actual transit isn't in the data)
  - 4 of 50 delivery partners are deliberately seeded as "bad apples" with an
    added delay penalty, producing a ~44% late rate vs ~8% for everyone else
  - delivery_ops_fact.csv intentionally contains 30 duplicate order_ids
    (simulating a mid-delivery partner reassignment) to teach the fan-out
    trap: always SELECT DISTINCT before joining fact tables 1:1 to orders

Re-run with the same seed (42) for reproducible results.
"""

import pandas as pd
import numpy as np

np.random.seed(42)

SRC = "/mnt/user-data/uploads/order_history_kaggle_data.csv"
df = pd.read_csv(SRC)
print(f"Loaded source: {df.shape}")

# ---------------------------------------------------------------------------
# Helper: parse distance bucket strings to numeric km
# ---------------------------------------------------------------------------
def parse_km(x):
    return 0.5 if x == "<1km" else float(x.replace("km", ""))

df["distance_km"] = df["Distance"].apply(parse_km)
df["order_placed_at_dt"] = pd.to_datetime(df["Order Placed At"], format="%I:%M %p, %B %d %Y")

n = len(df)

# ===========================================================================
# 1. RESTAURANTS DIM (clean, with 2 IDs deliberately dropped -> orphan FKs)
# ===========================================================================
rest_dim_full = (
    df[["Restaurant ID", "Restaurant name", "Subzone", "City"]]
    .drop_duplicates(subset="Restaurant ID")
    .reset_index(drop=True)
)

# Drop the 2 lowest-volume restaurant IDs from the dimension table only.
# Their orders remain in orders_raw -> orphaned foreign keys, on purpose.
volume_by_id = df["Restaurant ID"].value_counts()
orphan_ids = volume_by_id.sort_values().index[:2].tolist()
rest_dim = rest_dim_full[~rest_dim_full["Restaurant ID"].isin(orphan_ids)].reset_index(drop=True)

print(f"Restaurant dim: {len(rest_dim_full)} total IDs -> {len(rest_dim)} kept, "
      f"{len(orphan_ids)} orphaned on purpose: {orphan_ids}")

rest_dim.to_csv("restaurants_dim.csv", index=False)

# ===========================================================================
# 2. DELIVERY PARTNERS DIM (synthetic)
# ===========================================================================
N_PARTNERS = 50
partner_ids = [f"DP{str(i).zfill(4)}" for i in range(1, N_PARTNERS + 1)]
subzones = df["Subzone"].unique().tolist()
vehicle_types = np.random.choice(["Bike", "Scooter", "Bicycle"], size=N_PARTNERS, p=[0.55, 0.35, 0.10])
home_subzones = np.random.choice(subzones, size=N_PARTNERS)

min_date = df["order_placed_at_dt"].min()
join_days_before = np.random.randint(-30, 200, size=N_PARTNERS)
join_dates = [(min_date - pd.Timedelta(days=int(d))).strftime("%Y-%m-%d") for d in join_days_before]

partners_dim = pd.DataFrame({
    "partner_id": partner_ids,
    "vehicle_type": vehicle_types,
    "home_subzone": home_subzones,
    "join_date": join_dates,
})

BAD_APPLES = ["DP0046", "DP0050", "DP0048", "DP0004"]  # answer key - don't peek early
partners_dim.to_csv("delivery_partners_dim.csv", index=False)
print(f"Saved delivery_partners_dim.csv: {partners_dim.shape}")

# ===========================================================================
# 3. DELIVERY OPS FACT (synthetic, documented derivation)
# ===========================================================================
raw_weights = np.random.pareto(a=2.0, size=N_PARTNERS) + 0.1
weights = raw_weights / raw_weights.sum()
assigned_partners = np.random.choice(partner_ids, size=n, p=weights)

delivered_mask = df["Order Status"].isin(["Delivered", "Returned", "Return cancelled"])

transit_minutes = (6 + 2.3 * df["distance_km"] + np.random.normal(0, 2.5, size=n)).clip(lower=3)
promised_sla_minutes = np.round((38 + 3.2 * df["distance_km"]) / 5) * 5

kpt = df["KPT duration (minutes)"].fillna(df["KPT duration (minutes)"].median())
rider_wait = df["Rider wait time (minutes)"].fillna(df["Rider wait time (minutes)"].median())
actual_fulfillment_minutes = kpt + rider_wait + transit_minutes

bad_apple_mask = pd.Series(assigned_partners).isin(BAD_APPLES).values
extra_delay = np.where(bad_apple_mask, np.random.normal(14, 4, size=n).clip(min=5), 0)
actual_fulfillment_minutes = actual_fulfillment_minutes + extra_delay

is_late = (actual_fulfillment_minutes > promised_sla_minutes).astype(int)

ops_fact = pd.DataFrame({
    "order_id": df["Order ID"],
    "partner_id": assigned_partners,
    "promised_sla_minutes": promised_sla_minutes.round(1),
    "actual_fulfillment_minutes": actual_fulfillment_minutes.round(1),
    "is_late": is_late,
})
ops_fact.loc[~delivered_mask, ["partner_id", "promised_sla_minutes", "actual_fulfillment_minutes", "is_late"]] = np.nan

check = ops_fact.dropna(subset=["partner_id"]).copy()
check["is_bad_apple"] = check["partner_id"].isin(BAD_APPLES)
print("Late rate by bad-apple flag:\n", check.groupby("is_bad_apple")["is_late"].mean())
print("Overall late rate:", check["is_late"].mean().round(3))

# Fan-out trap: 30 duplicate order_ids simulating mid-delivery reassignment
# NOTE: sample from ops_fact (not `check`) to avoid leaking the is_bad_apple
# answer-key column into the shipped file via the concat below.
dup_candidates = ops_fact.dropna(subset=["partner_id"]).sample(30, random_state=7).copy()
dup_candidates["partner_id"] = np.random.choice(partner_ids, size=30)
ops_fact_final = pd.concat([ops_fact, dup_candidates], ignore_index=True)
print(f"delivery_ops_fact.csv shape (incl. 30 fan-out duplicates): {ops_fact_final.shape}")

ops_fact_final.to_csv("delivery_ops_fact.csv", index=False)

# ===========================================================================
# 4. ORDERS RAW (real data + injected warehouse mess)
# ===========================================================================
orders_messy = df.drop(columns=["distance_km", "order_placed_at_dt"]).copy()
idx = np.arange(n)

# --- (a) Casing / whitespace mess in City, Subzone, Restaurant name (~4% of rows) ---
mess_idx_case = np.random.choice(idx, size=int(0.04 * n), replace=False)
def mess_case(v):
    choice = np.random.choice(["upper", "lower", "pad"])
    if choice == "upper":
        return str(v).upper()
    elif choice == "lower":
        return str(v).lower()
    else:
        return f"  {v}  "

for i in mess_idx_case:
    col = np.random.choice(["City", "Subzone", "Restaurant name"])
    orders_messy.loc[i, col] = mess_case(orders_messy.loc[i, col])

# --- (b) Duplicate order_id rows (~40 rows, simulated double webhook fire) ---
dup_rows = orders_messy.sample(40, random_state=11).copy()
orders_messy = pd.concat([orders_messy, dup_rows], ignore_index=True)

# --- (c) Mixed date format for a batch of rows (simulate a different export batch) ---
mess_idx_date = np.random.choice(orders_messy.index, size=int(0.05 * len(orders_messy)), replace=False)
def reformat_date(s):
    dt = pd.to_datetime(s, format="%I:%M %p, %B %d %Y")
    return dt.strftime("%Y-%m-%d %H:%M:%S")  # ISO format, no AM/PM

orders_messy.loc[mess_idx_date, "Order Placed At"] = orders_messy.loc[mess_idx_date, "Order Placed At"].apply(reformat_date)

# --- (d) Extra dropped-event nulls in KPT / rider wait (~2% additional) ---
for col in ["KPT duration (minutes)", "Rider wait time (minutes)"]:
    extra_null_idx = np.random.choice(orders_messy.index, size=int(0.02 * len(orders_messy)), replace=False)
    orders_messy.loc[extra_null_idx, col] = np.nan

# --- (e) A few impossible values ---
impossible_idx = np.random.choice(orders_messy.index, size=6, replace=False)
for i, kind in zip(impossible_idx, ["neg_kpt", "neg_kpt", "rating6", "rating6", "neg_kpt", "rating6"]):
    if kind == "neg_kpt":
        orders_messy.loc[i, "KPT duration (minutes)"] = -abs(np.random.uniform(5, 20))
    else:
        orders_messy.loc[i, "Rating"] = 6.0

# --- (f) Orphaned restaurant IDs already present naturally (orphan_ids dropped from dim above) ---

orders_messy.to_csv("orders_raw.csv", index=False)
print(f"orders_raw.csv shape (incl. injected mess + 40 dup rows): {orders_messy.shape}")

print("\nAll 4 files written to /home/claude/fd_project/")
