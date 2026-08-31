-- ============================================================================
-- 03_metrics.sql -- Golden metric definitions (Part 3 / Question 3)
-- Run after 01_golden_dataset.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- METRIC: Monthly Recovery Amount & Recovered-Account Count (THE HEADLINE METRIC)
-- Definition: SUM(amount) / COUNT(DISTINCT account_id) from golden_payments
-- where payment_status = 'SUCCESS', grouped by calendar month of event_at
-- (UTC-normalized). This replaces the reported metric, which appears to be a
-- naive SUM(amount WHERE status='SUCCESS') over payments.csv with no dedup.
-- ----------------------------------------------------------------------------
SELECT strftime(event_at, '%Y-%m') AS ym,
       COUNT(DISTINCT account_id)  AS accounts_recovered,
       SUM(amount)                 AS recovery_amount,
       ROUND(100.0 * SUM(amount) / LAG(SUM(amount)) OVER (ORDER BY strftime(event_at,'%Y-%m')) - 100, 1) AS mom_pct
FROM golden_payments
WHERE payment_status = 'SUCCESS'
GROUP BY 1 ORDER BY 1;
-- Result: recovery_amount declines from ~184.1M (Jan) to ~148.7M (Jul, last
-- full month); accounts_recovered declines from 2,338 to 1,868.
-- Real Jan->Jul change: -19.2% amount, -20.1% accounts. NOT +11%.

-- ----------------------------------------------------------------------------
-- METRIC: Contact Rate = CONNECTED attempts / total attempts (golden_call_attempts)
-- Why this definition: attempt-level, not call-level, because call_attempts
-- carries an explicit attempt_status and attempt_no (so retries are already
-- distinguishable) -- calls.csv's call_status is a coarser, overlapping signal.
-- ----------------------------------------------------------------------------
SELECT strftime(event_at,'%Y-%m') ym, COUNT(*) attempts,
       SUM((attempt_status='CONNECTED')::INT) connected,
       ROUND(100.0*SUM((attempt_status='CONNECTED')::INT)/COUNT(*),1) contact_rate_pct
FROM golden_call_attempts GROUP BY 1 ORDER BY 1;
-- Result: flat at 19.7%-20.6% every month. No operational improvement here.

-- ----------------------------------------------------------------------------
-- METRIC: RPC (Right-Party Contact) proxy = CONNECTED attempts that produced a
-- disposition within the same day for the same account (call_dispositions
-- doesn't flag right-party explicitly, so this is the best available proxy;
-- documented as an ASSUMPTION, not a fact).
-- ----------------------------------------------------------------------------
-- (left as a documented gap -- raw data has no explicit RPC flag; do not
--  silently invent one and report it as ground truth)

-- ----------------------------------------------------------------------------
-- METRIC: PTP Rate = PTPs created / CONNECTED attempts (same month)
-- PTP Kept Rate = KEPT / (KEPT + BROKEN + CANCELLED), i.e. of PTPs that
-- reached a resolved terminal state, excludes still-OPEN promises whose
-- promised_date hasn't arrived yet (avoids penalizing recent months for
-- promises that haven't had a chance to be kept or broken).
-- ----------------------------------------------------------------------------
SELECT strftime(event_at,'%Y-%m') ym, COUNT(*) ptps,
       SUM((status='KEPT')::INT) kept,
       ROUND(100.0*SUM((status='KEPT')::INT) /
             NULLIF(SUM((status IN ('KEPT','BROKEN','CANCELLED'))::INT),0), 1) AS kept_rate_pct_resolved
FROM golden_ptp GROUP BY 1 ORDER BY 1;
-- Result: flat at 24.1%-25.5%. No operational improvement here either.

-- ----------------------------------------------------------------------------
-- METRIC: Recovery Rate = accounts_recovered / OPEN BOOK (ACTIVE+WRITEOFF
-- accounts.status), NOT accounts_recovered / accounts_targeted_that_month.
-- Rationale: daily_targeting only covers ~5-6k of ~15k open accounts per
-- month and the targeting funnel width itself varies month to month, so using
-- it as the denominator lets a narrowing/widening funnel move the "rate"
-- independent of real collections performance (see forensics item G).
-- ----------------------------------------------------------------------------
WITH open_book AS (SELECT COUNT(*) n FROM golden_accounts WHERE status IN ('ACTIVE','WRITEOFF'))
SELECT strftime(gp.event_at,'%Y-%m') ym,
       COUNT(DISTINCT gp.account_id)                                  AS accounts_recovered,
       (SELECT n FROM open_book)                                      AS open_book_size,
       ROUND(100.0*COUNT(DISTINCT gp.account_id)/(SELECT n FROM open_book),2) AS recovery_rate_pct
FROM golden_payments gp WHERE payment_status='SUCCESS'
GROUP BY 1 ORDER BY 1;

-- ----------------------------------------------------------------------------
-- METRIC: Recovery per Agent-Hour
-- Numerator: golden recovery amount attributed to an agent-month via the
-- disposition/attempt agent_id on that account in that month (many-to-one
-- simplification -- true multi-touch credit-splitting is out of scope here
-- and flagged as a limitation).
-- Denominator: agent_sessions login_at->logout_at duration, summed per
-- agent_id per month (session table, NOT the corrupted agents.csv dimension).
-- ----------------------------------------------------------------------------
WITH hours AS (
  SELECT agent_id, strftime(login_at,'%Y-%m') ym,
         SUM(EXTRACT(EPOCH FROM (logout_at-login_at))/3600.0) agent_hours
  FROM agent_sessions WHERE logout_at IS NOT NULL GROUP BY 1,2
),
attributed AS (
  SELECT ca.agent_id, strftime(gp.event_at,'%Y-%m') ym, SUM(gp.amount) amt
  FROM golden_payments gp
  JOIN golden_call_attempts ca
    ON ca.account_id = gp.account_id
   AND ca.event_at <= gp.event_at
   AND ca.event_at >= gp.event_at - INTERVAL 14 DAY   -- 14-day attribution window, see notebook
  WHERE gp.payment_status='SUCCESS'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY gp.payment_id ORDER BY ca.event_at DESC) = 1  -- last-touch
  GROUP BY 1,2
)
SELECT h.ym, SUM(a.amt) recovery_amt, SUM(h.agent_hours) agent_hours,
       ROUND(SUM(a.amt)/NULLIF(SUM(h.agent_hours),0),0) recovery_per_agent_hour
FROM hours h JOIN attributed a ON a.agent_id=h.agent_id AND a.ym=h.ym
GROUP BY 1 ORDER BY 1;

-- ----------------------------------------------------------------------------
-- METRIC: Cost per Rupee Recovered -- NOT COMPUTABLE from this dataset.
-- No cost/salary/vendor-billing table was provided (agents.csv has no comp
-- field, vendor_telephony.csv has no per-minute/per-seat rate). Any figure
-- for this metric in a prior report was necessarily assumption-driven and
-- should be treated as Hypothesis, not Fact, until a cost table is sourced.
-- ----------------------------------------------------------------------------
