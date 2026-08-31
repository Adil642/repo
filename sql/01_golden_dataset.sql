-- ============================================================================
-- 01_golden_dataset.sql
-- Builds the trustworthy analytical layer from raw source tables.
-- Engine: DuckDB (portable to Snowflake/BigQuery/Postgres with minor syntax edits)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- GOLDEN_PAYMENTS
-- Problem found: 25,500 raw rows but only 25,000 distinct payment_id (500 exact
-- duplicate rows) and only 20,821 distinct payment_reference (4,679 rows share
-- a reference with >=1 other row). Critically, 2,033 payment_references have
-- MORE THAN ONE row with payment_status = 'SUCCESS' -- these are not
-- retries-that-eventually-succeeded, they are the SAME successful payment
-- landing multiple times (gateway callback replay / ingestion duplication).
-- Naive SUM(amount WHERE status='SUCCESS') = 1,341,485,926
-- Deduplicated SUM                          = 1,169,564,836
-- --> 14.7% of "reported" recovery is duplicate-count inflation, and the
--     inflation rate is NOT constant -- it grows from 3.8% (Jan) to 28.6%
--     (Aug), which is what manufactures the illusion of improvement in any
--     naive month-over-month comparison. See 03_metrics.sql / data quality report.
--
-- Rule: partition by COALESCE(payment_reference, payment_id) [payment_id alone
-- covers the 265 legitimate rows with a NULL reference], keep one row per
-- partition, preferring SUCCESS status and earliest event_at (first true
-- settlement, not last retry echo).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_payments AS
WITH ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY COALESCE(payment_reference, payment_id)
      ORDER BY CASE payment_status WHEN 'SUCCESS' THEN 0 ELSE 1 END,
               event_at, payment_id
    ) AS rn
  FROM payments
)
SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1;
-- Impact: 25,500 raw -> 21,203 golden (-16.9% rows, -12.8% SUCCESS amount)

-- ----------------------------------------------------------------------------
-- GOLDEN_CALLS
-- 91,350 raw rows, 90,000 distinct call_id (1,350 exact duplicate rows,
-- almost certainly re-ingestion from the telephony vendor feed). Keep the
-- earliest occurrence.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_calls AS
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY event_at) AS rn
  FROM calls
)
SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- GOLDEN_BORROWERS
-- 30,600 raw rows but only 11,015 distinct borrower_id: the same borrower_id
-- recurs with different (usually stale) phone/email/updated_at combinations --
-- classic slowly-changing-dimension rows persisted without a version flag,
-- not genuine duplicate customers. We keep one row per borrower_id: prefer
-- the row with both phone and email populated, tie-break on latest updated_at.
-- Caveat: 1,205 phone numbers and 15,223 email rows are still shared across
-- >1 borrower_id even after this -- true multi-account-per-person cases exist
-- in this book (a borrower can legitimately hold multiple loans/accounts) and
-- were NOT merged, since accounts.borrower_id is the operative FK grain used
-- everywhere else in this pipeline.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_borrowers AS
WITH ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY borrower_id
      ORDER BY (phone IS NULL)::INT + (email IS NULL)::INT ASC, updated_at DESC
    ) AS rn
  FROM borrowers
)
SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1;

-- ----------------------------------------------------------------------------
-- GOLDEN_AGENTS  **DO NOT TRUST agents.csv AS AN IDENTITY DIMENSION**
-- 30,000 raw rows but only 1,000 distinct agent_id, and only 10 distinct
-- agent_name values in the ENTIRE table. Every agent_id has ~30 rows, each
-- with a *different, effectively random* employee_code (up to 48 distinct
-- codes for one agent_id) and a name drawn from just 10 possibilities.
-- employee_code fares no better: one employee_code maps to up to 46 distinct
-- agent_id values. There is no way to reconstruct a stable agent<->person
-- mapping from this table -- team, vendor_id, and status are effectively
-- randomized per row too (up to 15 vendors and 5 teams seen against one
-- agent_id). Conclusion: agents.csv is a corrupted/unresolvable dimension.
--
-- Treatment: agent_id, as it appears in calls / call_attempts / promises_to_pay
-- / field_visits, is the only reliable operational key and is used as-is for
-- all agent-level performance cuts. golden_agents below is a best-effort,
-- LOW-CONFIDENCE descriptive layer only (mode of noisy attributes) -- it must
-- never be joined for anything that claims per-agent tenure, vendor, or team
-- attribution without flagging the result as unreliable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_agents AS
SELECT
  agent_id,
  MIN(joined_at)               AS first_seen_joined_at,   -- earliest claimed join date, directional only
  MODE(team)                   AS team_mode_low_confidence,
  MODE(vendor_id)               AS vendor_mode_low_confidence,
  MODE(status)                  AS status_mode_low_confidence,
  COUNT(*)                       AS raw_row_count,
  COUNT(DISTINCT employee_code)  AS distinct_employee_codes,  -- data-quality signal, keep visible
  COUNT(DISTINCT agent_name)     AS distinct_names
FROM agents
GROUP BY agent_id;

-- ----------------------------------------------------------------------------
-- GOLDEN_ACCOUNTS -- account_id is a clean unique key (30,000/30,000). No
-- dedup needed. Passed through unchanged; dpd/risk_segment/status used as-is.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_accounts AS SELECT * FROM accounts;

-- ----------------------------------------------------------------------------
-- GOLDEN_CALL_ATTEMPTS / GOLDEN_PTP -- attempt_id and ptp_id are already
-- clean unique keys (120,000/120,000 and 18,000/18,000). Passed through as-is.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_call_attempts AS SELECT * FROM call_attempts;
CREATE OR REPLACE TABLE golden_ptp           AS SELECT * FROM promises_to_pay;

-- ----------------------------------------------------------------------------
-- GOLDEN_ACCOUNT_STATUS_HISTORY -- no exact (account_id, event_at, status)
-- collisions were found, so no rows dropped here; recorded_at vs event_at gap
-- is retained as a lateness signal rather than collapsed, per the
-- late-arriving-data handling in the production design (05_production_design.md).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE golden_account_status_history AS
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY account_id, event_at, status ORDER BY recorded_at DESC
  ) AS rn
  FROM account_status_history
)
SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1;
