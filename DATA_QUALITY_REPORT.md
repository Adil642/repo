# Data Quality Report

Raw records → rejected/corrected → golden dataset, with detection method, treatment, and quantified business impact for every issue found.

## Summary table

| # | Issue | Table(s) | Detection | Rows affected | Business impact |
|---|---|---|---|---|---|
| 1 | Duplicate SUCCESS payment events | `payments` | Group by `COALESCE(payment_reference, payment_id)`, count status='SUCCESS' rows per group | 2,033 reference groups / 4,299 rows | **Inflates reported recovery by 14.7% overall, growing from 3.8% (Jan) to 28.6% (Aug)** — see Finding A below |
| 2 | Exact duplicate `payment_id` rows | `payments` | `COUNT(*) - COUNT(DISTINCT payment_id)` | 500 rows | Subset of #1; ingestion-replay duplicates |
| 3 | Exact duplicate `call_id` rows | `calls` | `COUNT(*) - COUNT(DISTINCT call_id)` | 1,350 rows (1.5%) | Inflates call-volume metrics if not deduped |
| 4 | Agent identity unresolvable | `agents` | 30,000 rows / 1,000 distinct `agent_id`; only 10 distinct `agent_name` values in the whole table; one `agent_id` shows up to 48 different `employee_code`s | 29,000 rows (96.7%) | Cannot build a trustworthy agent dimension (tenure, team, vendor) — see Finding B |
| 5 | Borrower row duplication (SCD-style) | `borrowers` | 30,600 rows / 11,015 distinct `borrower_id` | 19,585 rows (64.0%) | Stale attribute rows; resolved by latest-complete-row rule |
| 6 | Mixed timezones in event timestamps | `calls`, `accounts`, `agent_sessions`, `vendor_telephony` | Distinct `timezone` values per table | ~30% of rows in each affected table, roughly evenly split UTC / Asia/Kolkata / Asia/Dubai | Any hour-of-day or day-of-week cut on raw `event_at` misclassifies events, and near midnight can shift events across a month boundary |
| 7 | Non-chronological disposition code versions | `call_dispositions` | `legacy`/`v2` versions co-occur in the same date ranges | ~35,000 rows | Disposition-code-based funnel metrics need a taxonomy crosswalk, not a simple time cutover |
| 8 | Non-chronological campaign `strategy_version` | `campaigns` | All 4 versions (`legacy`,`v1`,`v2`,`v3`) present in every campaign-start month Jan–May 2026 | 120 rows | Cannot be used to date the "targeting strategy change" referenced in the assignment brief — see counterfactual notes |
| 9 | Targeting funnel narrower than the open book | `daily_targeting` vs `accounts` | ~5–6k unique accounts targeted/month vs ~15,018 open accounts | N/A | If "conversion rate" denominator is the targeting funnel rather than the open book, a narrowing funnel mechanically inflates the rate |
| 10 | No cost data provided | *(no table)* | N/A | N/A | "Cost per ₹ recovered" from any prior report cannot be verified — no salary, vendor billing, or per-minute rate table exists in this package |

## Finding A — Duplicate payments (the core driver of the false "improvement")

Naive `SUM(amount)` over `payments.csv` where `payment_status='SUCCESS'` = **₹1,341,485,926**.
Deduplicated (one row per `COALESCE(payment_reference, payment_id)`, preferring the earliest SUCCESS row) = **₹1,169,564,836**.
**Naive figure is inflated 14.7% overall** — but the inflation rate is not constant:

| Month | Naive amount | Golden amount | Inflation |
|---|---:|---:|---:|
| 2026-01 | 191.1M | 184.1M | 3.8% |
| 2026-02 | 174.1M | 161.7M | 7.7% |
| 2026-03 | 193.2M | 174.8M | 10.6% |
| 2026-04 | 178.4M | 156.6M | 13.9% |
| 2026-05 | 187.0M | 157.6M | 18.7% |
| 2026-06 | 178.7M | 148.4M | 20.4% |
| 2026-07 | 190.3M | 148.7M | 28.0% |
| 2026-08* | 48.5M | 37.7M | 28.6% |

*August is a partial month (data cuts off Aug 8).

This is the headline finding of the entire assignment: **a growing rate of duplicate-payment ingestion, not any real operational change, is what makes the naive monthly totals look flat-to-improving while the deduplicated (real) totals actually decline ~19% from January to July.** Note that March 2026's naive month-over-month growth is **+11.0%** — matching the reported "11% MoM improvement" almost exactly. That figure is best explained as a naive, non-deduplicated read of one month's payment sum, not a genuine trend.

**Treatment:** golden_payments deduplicates by `COALESCE(payment_reference, payment_id)`, keeping the earliest SUCCESS-status row per group. This is the single most consequential cleaning decision in this pipeline.

## Finding B — Agent identity cannot be reconstructed from `agents.csv`

`agents.csv` has 30,000 rows but only 1,000 distinct `agent_id` values — roughly 30 rows per agent. Within one `agent_id`'s 30–48 rows, `employee_code` takes up to 48 different values, `team`/`vendor_id`/`status` are scattered across most of their possible values, and `agent_name` is drawn from a pool of just **10** names shared across the entire table (so ~1,000 agent_id values collapse onto 10 names, ~100 agents per name). This is not a "multiple identifiers for one agent" problem in the ordinary sense (assignment forensics item E) — it's the opposite and more severe: **the dimension table itself carries no resolvable identity**, so it is unsafe to draw any "agent tenure" or "team performance" conclusion from `agents.csv` directly.

**Treatment:** `agent_id`, as it appears in `calls`, `call_attempts`, `promises_to_pay`, and `field_visits` (the transactional tables), is treated as the only reliable key for agent-level performance cuts. `golden_agents` retains a best-effort descriptive layer (mode of the noisy attributes) but is explicitly flagged low-confidence and should not be the basis of a tenure or vendor-attribution claim without independent confirmation.

## What was NOT changed

- `accounts.csv`: `account_id` is a clean unique key (30,000/30,000); no rows dropped.
- `call_attempts.csv`, `promises_to_pay.csv`: unique IDs already; no rows dropped.
- Portfolio mix (origination volume and risk_segment split by vintage month) is stable — ruled out as a driver (see forensics item F).
- Contact rate (~20%), PTP kept-rate (~25%), field-visit paid-rate (~16%), and attempts-per-account (~1.3) are all **flat** month over month on the golden data. This matters: it rules out both a genuine operational improvement and a portfolio-mix (Simpson's paradox) explanation for the reported "11%" — the only thing that moved is the duplicate-payment inflation rate.

## Exclusion rules applied throughout

- All recovery/PTP/contact-rate metrics are computed from **golden** tables, never raw.
- August 2026 is excluded from month-over-month trend claims (partial month, ~8 of 31 days of data).
- `payment_status` other than `SUCCESS` is never counted as recovery.
- Timestamps are treated as being in the row's own declared `timezone` field (not implicitly UTC) before any hour/day rollup.
