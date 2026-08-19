"""
Delivery Ops Extension — Batch 2
Applies the EXACT same synthetic derivation as the original
build_project_data.py to the new orders_raw_batch2.csv rows:
same 50 partners, same Pareto volume skew, same 4 bad-apple partners,
same SLA/transit formula. No new partners, no new assumptions.
"""

import pandas as pd
import numpy as np

np.random.seed(43)  # consistent with the extension's own seed

orders = pd.read_csv("orders_raw_batch2.csv")
partners_dim = pd.read_csv("delivery_partners_dim.csv")

def parse_km(x):
    return 0.5 if x == "<1km" else float(x.replace("km", ""))

orders["distance_km"] = orders["Distance"].apply(parse_km)
n = len(orders)

partner_ids = partners_dim["partner_id"].tolist()
N_PARTNERS = len(partner_ids)
BAD_APPLES = ["DP0046", "DP0048", "DP0050", "DP0004"]

# Reuse Batch 1's ACTUAL empirical partner volume distribution as sampling
# weights, rather than redrawing a fresh random Pareto distribution. This
# guarantees Batch 2 is statistically consistent with Batch 1 (same partner
# mix, same implied overall late rate) rather than accidentally introducing
# an unexplained jump purely from re-randomizing weights with a new seed.
batch1_ops = pd.read_csv("delivery_ops_fact.csv").dropna(subset=["partner_id"])
empirical_share = batch1_ops["partner_id"].value_counts(normalize=True)
weights = np.array([empirical_share.get(pid, 0.0) for pid in partner_ids])
weights = weights / weights.sum()
assigned_partners = np.random.choice(partner_ids, size=n, p=weights)

delivered_mask = orders["Order Status"].isin(["Delivered", "Returned", "Return cancelled"])

transit_minutes = (6 + 2.3 * orders["distance_km"] + np.random.normal(0, 2.5, size=n)).clip(lower=3)
promised_sla_minutes = np.round((38 + 3.2 * orders["distance_km"]) / 5) * 5

kpt = orders["KPT duration (minutes)"].fillna(orders["KPT duration (minutes)"].median())
rider_wait = orders["Rider wait time (minutes)"].fillna(orders["Rider wait time (minutes)"].median())
actual_fulfillment_minutes = kpt + rider_wait + transit_minutes

bad_apple_mask = pd.Series(assigned_partners).isin(BAD_APPLES).values
extra_delay = np.where(bad_apple_mask, np.random.normal(14, 4, size=n).clip(min=5), 0)
actual_fulfillment_minutes = actual_fulfillment_minutes + extra_delay

is_late = (actual_fulfillment_minutes > promised_sla_minutes).astype(int)

ops_fact = pd.DataFrame({
    "order_id": orders["Order ID"],
    "partner_id": assigned_partners,
    "promised_sla_minutes": promised_sla_minutes.round(1),
    "actual_fulfillment_minutes": actual_fulfillment_minutes.round(1),
    "is_late": is_late,
})
ops_fact.loc[~delivered_mask, ["partner_id", "promised_sla_minutes", "actual_fulfillment_minutes", "is_late"]] = np.nan

check = ops_fact.dropna(subset=["partner_id"]).copy()
check["is_bad_apple"] = check["partner_id"].isin(BAD_APPLES)
print("Late rate by bad-apple flag (Batch 2):\n", check.groupby("is_bad_apple")["is_late"].mean())
print("Overall late rate (Batch 2):", check["is_late"].mean().round(3))

ops_fact.to_csv("delivery_ops_fact_batch2.csv", index=False)
print(f"\nSaved delivery_ops_fact_batch2.csv: {ops_fact.shape}")
