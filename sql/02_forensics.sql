-- ============================================================================
-- 02_forensics.sql -- Part 2 data forensics checks (A-G from the assignment)
-- ============================================================================

-- A. DUPLICATE PAYMENTS -- are retries/ingestion inflating recovery?
-- Finding: YES. See 01_golden_dataset.sql header. Quantified below.
SELECT
  SUM(amount) FILTER (WHERE payment_status='SUCCESS')                         AS naive_success_amt,
  (SELECT SUM(amount) FROM golden_payments WHERE payment_status='SUCCESS')    AS golden_success_amt,
  1 - (SELECT SUM(amount) FROM golden_payments WHERE payment_status='SUCCESS')
      / SUM(amount) FILTER (WHERE payment_status='SUCCESS')                  AS inflation_pct
FROM payments;

-- Inflation rate by month -- proves the inflation is TIME-VARYING (grows over
-- the period), which is what manufactures the appearance of an upward trend.
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY COALESCE(payment_reference, payment_id)
    ORDER BY CASE payment_status WHEN 'SUCCESS' THEN 0 ELSE 1 END, event_at, payment_id
  ) rn
  FROM payments WHERE payment_status = 'SUCCESS'
)
SELECT strftime(event_at, '%Y-%m') AS ym,
       SUM(amount)                                    AS naive_amt,
       SUM(amount) FILTER (WHERE rn = 1)               AS golden_amt,
       ROUND(100.0 * (SUM(amount) - SUM(amount) FILTER (WHERE rn=1))
             / SUM(amount) FILTER (WHERE rn=1), 1)     AS inflation_pct
FROM ranked GROUP BY 1 ORDER BY 1;

-- B. ATTRIBUTION ERRORS -- payments carry no campaign_id/call_id FK at all;
-- calls.csv is the only table with campaign_id. Any "payment attributed to
-- latest campaign" logic must therefore be inferred via a time-window join
-- (nearest preceding call/campaign touch to an account before a payment).
-- This is inherently fragile with a naive "last touch wins" rule, since ~5
-- channels can touch the same account within days of each other. See metric
-- notes in 03_metrics.sql for the windowed-attribution approach used.

-- C. TIMEZONE PROBLEMS -- calls/accounts/agent_sessions/vendor_telephony each
-- carry their own timezone field (UTC / Asia/Kolkata / Asia/Dubai). event_at
-- timestamps are NOT normalized to a common zone in the raw files.
SELECT timezone, COUNT(*) FROM calls GROUP BY 1;
SELECT timezone, COUNT(*) FROM accounts GROUP BY 1;
SELECT timezone, COUNT(*) FROM vendor_telephony GROUP BY 1;
-- Finding: a call logged at "23:40" in Asia/Dubai (UTC+4) is 19:40 UTC and
-- 01:10 the next day in Asia/Kolkata (UTC+5:30). Any hour-of-day / day-of-week
-- cut (e.g. "best calling time") computed directly off raw event_at without
-- normalizing by the row's own timezone field will misclassify a material
-- share of events into the wrong hour and, near midnight, the wrong DAY --
-- which also risks shifting events across a month boundary and distorting
-- month-over-month totals. Golden layer normalizes to UTC before any
-- time-of-day or calendar-month aggregation (see 03_metrics.sql).

-- D. VENDOR MAPPING / DISPOSITION CODE CHANGES DURING THE PERIOD
SELECT disposition_version, COUNT(*), MIN(event_at), MAX(event_at)
FROM call_dispositions GROUP BY 1 ORDER BY 2 DESC;
-- Finding: 'legacy' and 'v2' disposition_version codes co-exist across the
-- SAME time period (not a clean before/after cutover), meaning a disposition
-- code taxonomy mapping table is required before any disposition-code-based
-- funnel metric (e.g. "PTP rate by disposition") can be trusted across months.

-- E. AGENT IDENTITY PROBLEMS -- does the same agent appear under multiple IDs?
SELECT agent_id, COUNT(*) n_rows, COUNT(DISTINCT employee_code) n_emp_codes,
       COUNT(DISTINCT agent_name) n_names
FROM agents GROUP BY agent_id ORDER BY n_rows DESC LIMIT 10;
-- Finding: the INVERSE and worse problem than expected -- agents.csv cannot
-- resolve identity at all (see 01_golden_dataset.sql). Only the transactional
-- agent_id (in calls/attempts/ptp/field_visits) is trustworthy.

-- F. PORTFOLIO MIX CHANGES -- did the book change composition?
SELECT strftime(opened_at, '%Y-%m') AS vintage_month, risk_segment, COUNT(*)
FROM accounts GROUP BY 1,2 ORDER BY 1,2;
-- Finding: origination volume and risk_segment split are stable (~300-380
-- accounts/segment/month) across the full origination history -- no material
-- portfolio mix shift at acquisition. See 03_metrics.sql for the mix-of-
-- RECOVERED-accounts check (also flat), which rules out Simpson's paradox.

-- G. DENOMINATOR MANIPULATION -- are unsuccessful accounts vanishing from the
-- population used for conversion rates?
SELECT strftime(target_date,'%Y-%m') ym, COUNT(DISTINCT account_id) targeted_accounts
FROM daily_targeting GROUP BY 1 ORDER BY 1;
-- Cross-check against the full active book:
SELECT COUNT(*) FROM accounts WHERE status IN ('ACTIVE','WRITEOFF');
-- Finding: daily_targeting selects ~5-6k unique accounts/month out of ~15k
-- open accounts. If "conversion rate" is reported as
-- (recovered / targeted-that-month) instead of (recovered / open book), any
-- narrowing of the targeting funnel toward easier-to-collect accounts will
-- mechanically inflate the reported rate even with flat real performance.
-- Golden metric definitions in 03_metrics.sql use the STABLE full open-book
-- denominator, not the targeting funnel, for headline recovery-rate.
