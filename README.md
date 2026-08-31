# Food Delivery Analytics — End-to-End SQL Project

A simulated data-warehouse engagement for a food delivery platform, built on **real order data** (21,321 orders, Delhi NCR, Sep 2024–Jan 2025, extended to 48,864 orders / 12 months) with a documented synthetic delivery-ops layer, run for two stakeholders end to end: business objective → data cleaning → diagnosis → root cause → quantified recommendation → ongoing KPIs.

**Stack:** Snowflake → **migrated to PostgreSQL** (trial expiry) · dbt (staging models, Snowflake-era) · Python (synthetic data generation) · Power BI (dashboard, in progress)

📄 **[Full Project Charter (PDF)](docs/Food_Delivery_Project_Charter.pdf)** — stakeholder briefs, every finding, Amazon Leadership Principles mapping, and the general analysis framework used throughout.

**⚠️ Note on `sql/` vs `postgres_sql/`:** the project started on Snowflake (`sql/`) and was migrated to Postgres (`postgres_sql/`) after the Snowflake trial expired. Both are kept — the migration itself is a legitimate part of the project, demonstrating translation of Snowflake-specific syntax (`COUNT_IF`→`FILTER(WHERE...)`, `SELECT * EXCLUDE()`→explicit columns, `DATEDIFF()`→manual `EXTRACT` math) with every query cross-verified against the original results. **`postgres_sql/` is the current, actively maintained version**, running on the full 12-month extended dataset.

---

## The two stakeholders

| | Priya Nair — Head of Retention & Growth | Arjun Mehta — Head of Delivery Operations |
|---|---|---|
| **Objective** | Build a customer base that stays because they love the service, not the discount | Make on-time delivery a promise customers can rely on |
| **Techniques** | Cohort retention, RFM segmentation, look-ahead-bias correction, threshold sensitivity testing | Root-cause breakdown, counterfactual impact projection, 2-SD outlier detection with self-contamination check, confound control |
| **Headline finding** | Discount status at first order does **not** predict retention — an earlier version showing it did was traced to look-ahead bias and discarded | DP0041 handles 30–45% of orders in nearly every zone, every month, for a full year — a platform-wide resilience risk, not an isolated issue |

## Dashboard Preview

Live-connected Power BI dashboard (DirectQuery → Supabase), 4 pages, 12 visuals total.

### Retention & Growth — Diagnostics
![Retention diagnostics](dashboard_previews/dashboard_retention_diagnostics.png)

### Retention & Growth — Trends
![Retention trends](dashboard_previews/dashboard_retention_trends.png)

### Delivery Operations — Health
![Operations health](dashboard_previews/dashboard_ops_health.png)

### Delivery Operations — Root Cause & Risk
![Operations root cause](dashboard_previews/dashboard_ops_root_cause.png)

## What's actually interesting here (not just what's in the tables)

- **A wrong finding was caught and corrected in public.** The first version of the promo-dependency analysis showed a large, clean gap — it was wrong, built on a look-ahead bias (using future orders to explain past retention). The corrected version is in the repo, with the discarded version documented as a lesson, not hidden.
- **A statistical detection method was stress-tested against itself.** The 4 flagged delivery partners could theoretically be inflating the very baseline used to detect them — so the baseline was recomputed excluding them, and they still failed the stricter threshold. Re-run independently across 12 separate months, they failed every single time.
- **A dataset extension revealed its own limitation.** Extending from 5 to 12 months of data corrected one right-censoring diagnosis (proving a decline was real) and *created* a new, documented one (a KPI that only works at day-level granularity broke on month-level simulated data) — both are written up as findings, not swept under the rug.

## Repo structure

```
sql/            Snowflake-era analysis queries (original, 5-month dataset)
postgres_sql/   CURRENT — Postgres translations, verified, 12-month dataset,
                includes migration notes and 2 new findings only visible
                with more data (DP0044 outlier, shahdara zone concern — both
                flagged as open investigations, not yet resolved)
scripts/        Python: synthetic data generation (reproducible, seeded) + Snowflake DDL
data/           Source CSVs (raw + 12-month extension batch)
docs/           Data dictionary (what's real vs. synthetic, and why) + full project charter
models/         dbt staging models (Snowflake-era, kept for reference)
```

## Data note

The order data is real. The delivery-partner identity, SLA promise, and lateness outcome are **fully synthetic** — the source export has no partner-level data at all — built to make Arjun's questions answerable in a way the raw data doesn't support. Every synthetic assumption is documented in [`docs/DATA_DICTIONARY.md`](docs/DATA_DICTIONARY.md), including which of the injected data-quality issues were deliberate (dedup, casing, mixed date formats, orphaned keys) vs. real.

## Status

Both stakeholders' full analysis, findings, and ongoing KPI dashboards are complete (13 KPIs total), migrated and re-verified on Postgres after the Snowflake trial expired. Two new findings emerged from the 12-month extension and are under active investigation: a possible 5th outlier delivery partner (DP0044) and a possible emerging zone issue (shahdara). Power BI dashboard in progress (Snowflake connection previously proven via DirectQuery; reconnecting to Postgres).
