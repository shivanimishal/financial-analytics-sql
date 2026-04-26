#Financial Analytics — SQL Portfolio Project
 
## Business Problem
A procurement and payments function operating across multiple invoicing
platforms and global regions needs visibility into invoice aging, SLO
compliance, vendor spend concentration, and early payment discount
opportunity. This project models that environment in SQL — from schema
design through to the analytical queries that drive operational decisions.
 
## Business Skills Demonstrated
- **Domain expertise:** Schema designed around real P2P workflows — aging
  buckets, SLO compliance, EPD opportunity sizing, and bridge analysis
- **Stakeholder thinking:** Queries structured to answer the questions
  that MD-level audiences actually ask in monthly reporting cycles
- **Data governance:** CHECK constraints, referential integrity, and NULL
  handling reflect production-standard data quality thinking
 
## Technical Skills Demonstrated
- Star schema design with dimension and fact tables
- Window functions: LAG(), RANK(), SUM() OVER (PARTITION BY ...)
- CTEs for readable, maintainable query structure
- Conditional aggregation (CASE WHEN inside SUM)
- NULL-safe arithmetic with NULLIF()
 
## Schema
| Table | Type | Grain |
|-------|------|-------|
| dim_vendor | Dimension | One row per vendor |
| dim_date | Dimension | One row per calendar date |
| fact_invoice | Fact | One row per invoice |
| fact_slo_log | Fact | One row per approval event |
 
## Queries
| # | Query | Business Purpose |
|---|-------|-----------------|
| 1 | Invoice Aging Buckets | Cash flow risk, escalation priority |
| 2 | SLO Compliance by Region | Monthly management reporting |
| 3 | Period-over-Period Volume | Bridge analysis, trend reporting |
| 4 | Vendor Spend + EPD Opportunity | EPD programme feasibility |
| 5 | Platform Exception Rate | Root cause, data quality |
| 6 | SLO Breach Root Cause | MD-level deep dive analysis |
| 7 | Cumulative YTD Spend | Budget tracking, forecasting |
| 8 | Payment Behaviour Segmentation | EPD effectiveness analysis |
 
## How to Run
No installation required. Paste the schema and queries into
[DB Fiddle](https://www.db-fiddle.com) — a free browser-based SQL tool.
Select PostgreSQL as the engine.
 
## Tools
SQL (PostgreSQL) · Python (synthetic data generation)
 
## Author
Shivani Mishal
