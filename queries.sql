-- ============================================================
-- Financial Analytics — BI Query Library
-- Author: Shivani Mishal
-- Dialect: SQL Server 
-- ============================================================

-- ── QUERY 1: Invoice Aging Buckets ──────────────────────────
-- Business question: How old are our unpaid invoices, and how much
-- money is at risk if suppliers start charging late payment fees?
-- Used for: Cash flow risk reporting, escalation prioritisation

SELECT
    vendor_id,
    -- COUNT: total number of open invoices per vendor
    COUNT(*) AS invoice_count,
    -- SUM: total financial exposure — what would we owe if all were due today
    SUM(amount_usd) AS total_exposure_usd,
  
    SUM(CASE WHEN DATEDIFF(day, due_date, CAST(GETDATE() AS DATE)) BETWEEN 1 AND 30
             THEN amount_usd ELSE 0 END) AS aged_0_30,
    -- 31-60 days: BETWEEN includes both endpoints
    SUM(CASE WHEN DATEDIFF(day, due_date, CAST(GETDATE() AS DATE)) BETWEEN 31 AND 60
             THEN amount_usd ELSE 0 END) AS aged_31_60,
    SUM(CASE WHEN DATEDIFF(day, due_date, CAST(GETDATE() AS DATE)) BETWEEN 61 AND 90
             THEN amount_usd ELSE 0 END) AS aged_61_90,
    -- 90+ days: critical — likely to be disputed or escalated
    SUM(CASE WHEN DATEDIFF(day, due_date, CAST(GETDATE() AS DATE)) > 90
             THEN amount_usd ELSE 0 END) AS aged_90_plus
FROM fact_invoice
-- Exclude already resolved invoices — only show what is still open
WHERE status NOT IN ('Paid', 'Rejected')
GROUP BY vendor_id
-- Show highest financial exposure first — this drives escalation priority
ORDER BY total_exposure_usd DESC;

-- ── QUERY 2: SLO Compliance Rate by Region & Month ───────────
-- Business question: Are our regions meeting the 7-day approval SLO?
-- Which months show deterioration that needs root-cause investigation?
-- Used for: Monthly management reporting, OKR tracking, MD-level briefings
SELECT
    region,
    DATEADD(month, DATEDIFF(month, 0, submitted_date), 0) AS month,
    COUNT(*) AS total_processes,

    SUM(CASE WHEN slo_met = 1 THEN 1 ELSE 0 END) AS slo_met_count,
    -- Compliance percentage: met_count / total * 100,
    ROUND(100.0 * SUM(CASE WHEN slo_met = 1 THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS slo_compliance_pct,
    -- Average days to approve — shows whether breaches are marginal (8+ days) or severe (15+)
    ROUND(AVG(CAST(days_to_approve AS FLOAT)), 1) AS avg_days_to_approve
FROM fact_slo_log
GROUP BY region, DATEADD(month, DATEDIFF(month, 0, submitted_date), 0)
ORDER BY month, region;

-- ── QUERY 3: Period-over-Period Invoice Volume (Bridge) ───────
-- Business question: What changed between this month and last month?
-- How much of the change is volume-driven vs value-driven?
-- Used for: Bridge analysis 
-- LAG() over self-join for MoM change, self-join would be slower and harder to read
WITH monthly_volume AS (
    SELECT
        DATEADD(month, DATEDIFF(month, 0, invoice_date), 0) AS month,
        COUNT(*) AS invoice_count,
        SUM(amount_usd) AS total_amount
    FROM fact_invoice
    GROUP BY DATEADD(month, DATEDIFF(month, 0, invoice_date), 0)
),
monthly_with_lag AS (
    SELECT
        month,
        invoice_count,
        total_amount,
        -- LAG(): returns the value from the previous row
        -- OVER (ORDER BY month): defines the sequence — previous means chronologically earlier
        LAG(invoice_count) OVER (ORDER BY month) AS prev_month_count,
        LAG(total_amount)  OVER (ORDER BY month) AS prev_month_amount
    FROM monthly_volume
)
SELECT
    month,
    invoice_count,
    total_amount,
    prev_month_count,
    prev_month_amount,
    invoice_count - prev_month_count AS count_change,
    -- Percentage change: divide by prior month using NULLIF to prevent division by zero
    -- NULLIF(x, 0) returns NULL instead of error when dividing by zero
    ROUND(100.0 * (invoice_count - prev_month_count)
          / NULLIF(prev_month_count, 0), 1) AS pct_change
FROM monthly_with_lag
ORDER BY month;

-- ── QUERY 4: Vendor Spend Concentration & Discounting Opportunity ────
-- Business question: Which vendors represent the largest share of spend?
-- Of those, which are discounting-eligible — i.e. where is the discount opportunity largest?
-- Used for: Discounting programme feasibility
SELECT
    v.vendor_name,
    v.category,
    v.region,
    v.is_discounting_eligible,
    v.payment_terms_days,
    COUNT(i.invoice_id)  AS invoice_count,
    SUM(i.amount_usd)    AS total_spend_usd,
    -- calculates grand total across all vendors
    -- Dividing individual vendor spend by this gives each vendor's share of total
    ROUND(100.0 * SUM(i.amount_usd) /
          SUM(SUM(i.amount_usd)) OVER (), 2) AS spend_share_pct,
    -- to identify top-10 vendors for discounting targeting
    RANK() OVER (ORDER BY SUM(i.amount_usd) DESC) AS spend_rank,
    -- Potential savings at 2% early payment discount rate
    ROUND(SUM(i.amount_usd) * 0.02, 2) AS potential_2pct_saving
FROM fact_invoice i
-- JOIN: links invoice records to their vendor attributes
JOIN dim_vendor v ON i.vendor_id = v.vendor_id
WHERE i.status = 'Paid'
GROUP BY v.vendor_name, v.category, v.region, v.is_discounting_eligible, v.payment_terms_days
ORDER BY total_spend_usd DESC;

-- ── QUERY 5: Platform Exception Rate Analysis ────────────────
-- Business question: Which invoicing platforms have the highest rates of
-- disputes and rejections — and where should we focus data quality effort?
-- Used for: Root-cause analysis, platform risk flagging, technology investment cases
SELECT
    platform,
    COUNT(*) AS total_invoices,
    SUM(CASE WHEN status = 'Disputed'  THEN 1 ELSE 0 END) AS disputed_count,
    SUM(CASE WHEN status = 'Rejected'  THEN 1 ELSE 0 END) AS rejected_count,
    -- Overdue: pending AND past due date — highest urgency
    SUM(CASE WHEN status = 'Pending'
              AND due_date < CAST(GETDATE() AS DATE) THEN 1 ELSE 0 END) AS overdue_count,
    -- Exception rate: sum of disputed + rejected as a % of all invoices on that platform
    -- This is the KPI that identifies which platforms need remediation
    ROUND(100.0 * SUM(CASE WHEN status IN ('Disputed','Rejected')
          THEN 1 ELSE 0 END) / COUNT(*), 1) AS exception_rate_pct
FROM fact_invoice
GROUP BY platform
-- Show worst-performing platforms first — drives prioritisation conversation
ORDER BY exception_rate_pct DESC;

-- ── QUERY 6: SLO Breach Root Cause Breakdown ─────────────────
-- Business question: When SLOs are breached, WHERE is it happening?
-- Is it a specific region, platform, or approver level causing the delay?
-- Used for: Bridge/root-cause analysis 
SELECT
    region,
    platform,
    approver_type,
    COUNT(*) AS breach_count,
    ROUND(AVG(CAST(days_to_approve AS FLOAT)), 1) AS avg_days_to_approve,
    MAX(days_to_approve) AS max_days_to_approve,
    -- How many days over the SLO on average — contextualises severity
    ROUND(AVG(CAST(days_to_approve - slo_target_days AS FLOAT)), 1) AS avg_days_over_slo
FROM fact_slo_log
WHERE slo_met = 0
GROUP BY region, platform, approver_type
ORDER BY breach_count DESC;

-- ── QUERY 7: Cumulative YTD Spend by Quarter ─────────────────
-- Business question: What is our cumulative spend trajectory by region?
-- Are we tracking to budget? Where is spend accelerating?
-- Used for: Budget tracking, year-end forecasting, quarterly business reviews
SELECT
    DATEADD(quarter, DATEDIFF(quarter, 0, invoice_date), 0) AS quarter,
    region,
    SUM(amount_usd) AS quarterly_spend,
    SUM(SUM(amount_usd)) OVER (
        PARTITION BY region
        ORDER BY DATEADD(quarter, DATEDIFF(quarter, 0, invoice_date), 0)
    ) AS cumulative_spend_ytd
FROM fact_invoice
WHERE status = 'Paid'
GROUP BY DATEADD(quarter, DATEDIFF(quarter, 0, invoice_date), 0), region
ORDER BY quarter, region;

-- ── QUERY 8: Vendor Payment Behaviour Segmentation ───────────
-- Business question: Do vendors who are discounting-eligible actually pay faster?
-- How does payment timing correlate with vendor category and region?
-- Used for: Discounting programme effectiveness analysis, vendor negotiation strategy
WITH payment_timing AS (
    SELECT
        i.vendor_id,
        v.vendor_name,
        v.category,
        v.region,
        v.is_discounting_eligible,
        v.payment_terms_days,
        -- Days to pay: actual payment date minus invoice date
        -- Negative means paid before invoice date (data quality flag)
        -- Greater than payment_terms_days means paid late
        DATEDIFF(day, i.invoice_date, i.paid_date) AS days_to_pay,
        -- Early = paid before due date
        CASE WHEN i.paid_date < i.due_date THEN 1 ELSE 0 END AS paid_early
    FROM fact_invoice i
    JOIN dim_vendor v ON i.vendor_id = v.vendor_id
    WHERE i.status = 'Paid'   -- Only analyse completed payments
      AND i.paid_date IS NOT NULL
)
SELECT
    category,
    region,
    is_discounting_eligible,
    COUNT(*) AS payment_count,
    ROUND(AVG(CAST(days_to_pay AS FLOAT)), 1) AS avg_days_to_pay,
    ROUND(AVG(CAST(payment_terms_days AS FLOAT)), 0) AS avg_terms_days,
    -- Early payment rate: what % of invoices were paid before due date
    ROUND(100.0 * SUM(CASE WHEN paid_early = 1 THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS early_payment_rate_pct
FROM payment_timing
GROUP BY category, region, is_discounting_eligible
ORDER BY avg_days_to_pay;
