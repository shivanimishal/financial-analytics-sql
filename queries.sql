-- ============================================================
-- P2P Financial Analytics — BI Query Library
-- Author: Shivani Mishal
-- Each query answers a real operational question a procurement
-- team would ask — these are not academic exercises
-- ============================================================
 
-- ── QUERY 1: Invoice Aging Buckets ──────────────────────────
-- Business question: How old are our unpaid invoices, and how much
-- money is at risk if suppliers start charging late payment fees?
-- Used for: Cash flow risk reporting, escalation prioritisation
-- Interview talking point: Aging analysis was one of the first
-- reporting frameworks I built at GS — this query type is the
-- foundation of any P2P reporting infrastructure
SELECT
    vendor_id,
    -- COUNT: total number of open invoices per vendor
    COUNT(*) AS invoice_count,
    -- SUM: total financial exposure — what would we owe if all were due today
    SUM(amount_usd) AS total_exposure_usd,
    -- CASE WHEN inside SUM: this is 'conditional aggregation'
    -- It sums amounts only for rows matching the date condition
    -- 0–30 days overdue: manageable, but flag for attention
    SUM(CASE WHEN CURRENT_DATE - due_date <= 30
             THEN amount_usd ELSE 0 END) AS aged_0_30,
    -- 31–60 days: BETWEEN includes both endpoints
    SUM(CASE WHEN CURRENT_DATE - due_date BETWEEN 31 AND 60
             THEN amount_usd ELSE 0 END) AS aged_31_60,
    SUM(CASE WHEN CURRENT_DATE - due_date BETWEEN 61 AND 90
             THEN amount_usd ELSE 0 END) AS aged_61_90,
    -- 90+ days: critical — likely to be disputed or escalated
    SUM(CASE WHEN CURRENT_DATE - due_date > 90
             THEN amount_usd ELSE 0 END) AS aged_90_plus
FROM fact_invoice
-- Exclude already resolved invoices — only show what is still open
WHERE status NOT IN ('Paid', 'Rejected')
GROUP BY vendor_id
-- Show highest financial exposure first — this drives escalation priority
ORDER BY total_exposure_usd DESC;
 
-- ── QUERY 2: SLO Compliance Rate by Region & Month ───────────
-- Business question: Are our three regions meeting the 7-day approval SLO?
-- Which months show deterioration that needs root-cause investigation?
-- Used for: Monthly management reporting, OKR tracking, MD-level briefings
SELECT
    region,
    -- DATE_TRUNC: rounds a date down to the start of the month
    -- This groups all rows in the same month together for aggregation
    DATE_TRUNC('month', submitted_date) AS month,
    COUNT(*) AS total_processes,
    -- Count only the processes where SLO was met (slo_met = TRUE)
    SUM(CASE WHEN slo_met THEN 1 ELSE 0 END) AS slo_met_count,
    -- Compliance percentage: met_count / total * 100, rounded to 1 decimal
    -- ROUND prevents output like 87.33333... which looks messy in a dashboard
    ROUND(100.0 * SUM(CASE WHEN slo_met THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS slo_compliance_pct,
    -- Average days to approve — shows whether breaches are marginal (8 days) or severe (15+)
    ROUND(AVG(days_to_approve), 1) AS avg_days_to_approve
FROM fact_slo_log
GROUP BY region, DATE_TRUNC('month', submitted_date)
ORDER BY month, region;
 
-- ── QUERY 3: Period-over-Period Invoice Volume (Bridge) ───────
-- Business question: What changed between this month and last month?
-- How much of the change is volume-driven vs value-driven?
-- Used for: Bridge analysis — the exact analysis type on your resume
-- Interview talking point: LAG() is a window function — it looks at the
-- previous row in a defined sequence. This is how you calculate MoM change
-- without a self-join, which would be slower and harder to read
WITH monthly_volume AS (
    -- CTE (Common Table Expression): a named temporary result set
    -- Think of it as a named subquery you can reference by name below
    -- Best practice: use CTEs instead of nested subqueries for readability
    SELECT
        DATE_TRUNC('month', invoice_date) AS month,
        COUNT(*) AS invoice_count,
        SUM(amount_usd) AS total_amount
    FROM fact_invoice
    GROUP BY DATE_TRUNC('month', invoice_date)
)
SELECT
    month,
    invoice_count,
    total_amount,
    -- LAG(): returns the value from the previous row
    -- OVER (ORDER BY month): defines the sequence — previous means chronologically earlier
    LAG(invoice_count) OVER (ORDER BY month) AS prev_month_count,
    LAG(total_amount)  OVER (ORDER BY month) AS prev_month_amount,
    -- Absolute change: this month minus last month
    invoice_count - LAG(invoice_count) OVER (ORDER BY month) AS count_change,
    -- Percentage change: divide by prior month using NULLIF to prevent division by zero
    -- NULLIF(x, 0) returns NULL instead of error when dividing by zero
    ROUND(100.0 * (invoice_count -
          LAG(invoice_count) OVER (ORDER BY month))
          / NULLIF(LAG(invoice_count) OVER (ORDER BY month), 0), 1) AS pct_change
FROM monthly_volume
ORDER BY month;
 
-- ── QUERY 4: Vendor Spend Concentration & EPD Opportunity ────
-- Business question: Which vendors represent the largest share of spend?
-- Of those, which are EPD-eligible — i.e. where is the discount opportunity largest?
-- Used for: EPD programme feasibility — the analysis behind your $6M impact
SELECT
    v.vendor_name,
    v.category,
    v.region,
    v.is_epd_eligible,
    v.payment_terms_days,
    COUNT(i.invoice_id)  AS invoice_count,
    SUM(i.amount_usd)    AS total_spend_usd,
    -- SUM() OVER (): window function — calculates grand total across ALL vendors
    -- Dividing individual vendor spend by this gives each vendor's share of total
    ROUND(100.0 * SUM(i.amount_usd) /
          SUM(SUM(i.amount_usd)) OVER (), 2) AS spend_share_pct,
    -- RANK(): assigns rank 1 to highest spend, 2 to second, etc.
    -- Useful for identifying top-10 vendors for EPD targeting
    RANK() OVER (ORDER BY SUM(i.amount_usd) DESC) AS spend_rank,
    -- Potential savings at 2% early payment discount rate
    ROUND(SUM(i.amount_usd) * 0.02, 2) AS potential_2pct_saving
FROM fact_invoice i
-- JOIN: links invoice records to their vendor attributes
JOIN dim_vendor v ON i.vendor_id = v.vendor_id
WHERE i.status = 'Paid'
GROUP BY v.vendor_name, v.category, v.region, v.is_epd_eligible, v.payment_terms_days
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
              AND due_date < CURRENT_DATE THEN 1 ELSE 0 END) AS overdue_count,
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
-- Used for: The exact bridge/root-cause analysis described on your resume
SELECT
    region,
    platform,
    approver_type,
    COUNT(*) AS breach_count,
    ROUND(AVG(days_to_approve), 1) AS avg_days_to_approve,
    -- MAX shows the worst-case breach — useful for executive escalation framing
    MAX(days_to_approve) AS max_days_to_approve,
    -- How many days over the SLO on average — contextualises severity
    ROUND(AVG(days_to_approve - slo_target_days), 1) AS avg_days_over_slo
FROM fact_slo_log
-- Filter to breaches only — this query is about what went wrong
WHERE slo_met = FALSE
GROUP BY region, platform, approver_type
ORDER BY breach_count DESC;
 
-- ── QUERY 7: Cumulative YTD Spend by Quarter ─────────────────
-- Business question: What is our cumulative spend trajectory by region?
-- Are we tracking to budget? Where is spend accelerating?
-- Used for: Budget tracking, year-end forecasting, quarterly business reviews
SELECT
    DATE_TRUNC('quarter', invoice_date) AS quarter,
    region,
    SUM(amount_usd) AS quarterly_spend,
    -- SUM() OVER with PARTITION + ORDER: running total within each region
    -- PARTITION BY region: restart the running total for each region separately
    -- ORDER BY quarter: accumulate in chronological order
    -- This creates a YTD cumulative spend figure without any self-joins
    SUM(SUM(amount_usd)) OVER (
        PARTITION BY region
        ORDER BY DATE_TRUNC('quarter', invoice_date)
    ) AS cumulative_spend_ytd
FROM fact_invoice
WHERE status = 'Paid'
GROUP BY DATE_TRUNC('quarter', invoice_date), region
ORDER BY quarter, region;
 
-- ── QUERY 8: Vendor Payment Behaviour Segmentation ───────────
-- Business question: Do vendors who are EPD-eligible actually pay faster?
-- How does payment timing correlate with vendor category and region?
-- Used for: EPD programme effectiveness analysis, vendor negotiation strategy
WITH payment_timing AS (
    SELECT
        i.vendor_id,
        v.vendor_name,
        v.category,
        v.region,
        v.is_epd_eligible,
        v.payment_terms_days,
        -- Days to pay: actual payment date minus invoice date
        -- Negative means paid before invoice date (data quality flag)
        -- Greater than payment_terms_days means paid late
        DATEDIFF('day', i.invoice_date, i.paid_date) AS days_to_pay,
        -- Early = paid before due date
        CASE WHEN i.paid_date < i.due_date THEN TRUE ELSE FALSE END AS paid_early
    FROM fact_invoice i
    JOIN dim_vendor v ON i.vendor_id = v.vendor_id
    WHERE i.status = 'Paid'   -- Only analyse completed payments
      AND i.paid_date IS NOT NULL
)
SELECT
    category,
    region,
    is_epd_eligible,
    COUNT(*) AS payment_count,
    ROUND(AVG(days_to_pay), 1) AS avg_days_to_pay,
    ROUND(AVG(payment_terms_days), 0) AS avg_terms_days,
    -- Early payment rate: what % of invoices were paid before due date
    ROUND(100.0 * SUM(CASE WHEN paid_early THEN 1 ELSE 0 END)
          / COUNT(*), 1) AS early_payment_rate_pct
FROM payment_timing
GROUP BY category, region, is_epd_eligible
ORDER BY avg_days_to_pay;
