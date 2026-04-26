-- ============================================================
-- Financial Analytics — Star Schema DDL
-- Author: Shivani Mishal
-- Dialect: SQL Server
-- Design rationale: Star schema chosen over snowflake because:
--   (1) self-service analytics users need simple joins
--   (2) Power BI and Tableau both perform better against stars
--   (3) 100+ stakeholders with mixed SQL ability
-- ============================================================

-- ── DIMENSION: VENDOR ───────────────────────────────────────
CREATE TABLE dim_vendor (
    vendor_id                VARCHAR(10)   PRIMARY KEY,
    vendor_name              VARCHAR(200)  NOT NULL,
    category                 VARCHAR(100),
    -- CHECK constraint enforces only valid region codes enter the table
    -- This is a data governance control — prevents 'ASIA' vs 'APAC' inconsistency
    region                   VARCHAR(10)   CHECK (region IN ('APAC','EMEA','AMER')),
    payment_terms_days       INT,
    -- Discounting eligibility flags which vendors are enrolled in the discounting programme
    is_discounting_eligible  BIT           DEFAULT 0,
    platform                 VARCHAR(100)  CHECK (platform IN
                             ('SAP Ariba','Coupa','Tungsten Network','Legacy ERP','Other'))
);

-- ── DIMENSION: DATE ─────────────────────────────────────────
CREATE TABLE dim_date (
    date_key            DATE          PRIMARY KEY,
    year                INT,
    quarter             INT,
    month               INT,
    month_name          VARCHAR(20),
    week_of_year        INT,
    -- is_month_end useful for month-end close reporting cycles
    is_month_end        BIT
);

-- ── FACT: INVOICE ────────────────────────────────────────────
-- Each invoice is one event (one row)
-- Foreign keys link back to dimension tables for joins
CREATE TABLE fact_invoice (
    invoice_id          VARCHAR(15)   PRIMARY KEY,
    -- REFERENCES enforces referential integrity — no orphan invoices without a vendor
    vendor_id           VARCHAR(10)   REFERENCES dim_vendor(vendor_id),
    -- CHECK constraint added to platform
    platform            VARCHAR(100)  CHECK (platform IN
                        ('SAP Ariba','Coupa','Tungsten Network','Legacy ERP','Other')),
    invoice_date        DATE,
    due_date            DATE,
    -- paid_date is nullable — unpaid invoices have no paid date
    paid_date           DATE,
    -- DECIMAL(15,2): up to 15 digits with 2 decimal places — handles multi-million amounts
    amount_usd          DECIMAL(15,2),
    -- CHECK constraint restricts status to valid values only
    -- Prevents dirty data like 'PAID' (uppercase) vs 'Paid' co-existing
    status              VARCHAR(20)   CHECK (status IN
                        ('Paid','Approved','Pending','Disputed','Rejected')),
    -- CHECK constraint added to region 
    region              VARCHAR(10)   CHECK (region IN ('APAC','EMEA','AMER')),
    invoice_type        VARCHAR(30)
);

-- ── FACT: SLO COMPLIANCE LOG ─────────────────────────────────
-- Tracks every approval process — one row per process event
CREATE TABLE fact_slo_log (
    process_id          VARCHAR(15)   PRIMARY KEY,
    -- CHECK constraint added to region 
    region              VARCHAR(10)   CHECK (region IN ('APAC','EMEA','AMER')),
    -- CHECK constraint added to platform 
    platform            VARCHAR(100)  CHECK (platform IN
                        ('SAP Ariba','Coupa','Tungsten Network','Legacy ERP','Other')),
    submitted_date      DATE,
    approved_date       DATE,
    days_to_approve     INT,
    -- DEFAULT 7: the SLO target — stored per row in case targets change by region
    slo_target_days     INT           DEFAULT 7,
    slo_met             AS (CAST(CASE WHEN days_to_approve <= slo_target_days
                            THEN 1 ELSE 0 END AS BIT)) PERSISTED,
    -- CHECK constraint added to approver_type
    approver_type       VARCHAR(50)   CHECK (approver_type IN
                        ('Manager','Director','VP','MD'))
);
