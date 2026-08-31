-- ============================================================================
-- 04_counterfactual.sql -- Part 4: "What if targeting strategy hadn't changed?"
-- ============================================================================

-- STEP 1: locate the actual change. campaigns.strategy_version (legacy/v1/v2/v3)
-- CANNOT be used as the split -- all four versions appear in every campaign
-- start month Jan-May 2026 with no chronological ordering (verified below),
-- so it is metadata noise, not a policy timeline.
SELECT strftime(start_at,'%Y-%m') ym, strategy_version, COUNT(*)
FROM campaigns GROUP BY 1,2 ORDER BY 1,2;
-- All 4 versions present every month => strategy_version is not usable as a
-- pre/post split. Falls back to the one observable behavioral signal: the mix
-- of recommended_channel in daily_targeting over time.

SELECT strftime(target_date,'%Y-%m') ym, recommended_channel, COUNT(*) n
FROM daily_targeting GROUP BY 1,2 ORDER BY 1,2;
-- Even this is close to flat (channel shares move by only a few points month
-- to month) -- there is no sharp, identifiable "before vs after" cutover
-- month visible anywhere in the provided tables.

-- CONCLUSION (stated plainly rather than forced into a method):
-- This dataset does not contain a clean, dateable targeting-strategy change
-- event. campaigns.strategy_version is randomized/non-chronological and
-- daily_targeting.recommended_channel mix does not show a step-change. A
-- difference-in-differences or matching design REQUIRES an identifiable
-- treatment date and a comparable untreated group; neither is available here
-- with acceptable confidence. Forcing a DiD onto a guessed cutover date would
-- produce a number that looks precise but is not defensible.
--
-- What we would need to actually answer this (stated per the assignment's
-- explicit allowance to say "the data is insufficient"):
--   1. A campaign/targeting change-log table with an explicit effective_date
--      and a machine-readable description of what changed (which segments
--      gained/lost priority, which channel mix rules changed).
--   2. A holdout/control group that continued under the old policy after the
--      change date (even a small 5-10% randomized holdout is enough for a
--      credible DiD or synthetic control).
--   3. If no holdout exists, a REGRESSION DISCONTINUITY around the true
--      change date could substitute, but only once step 1 supplies that date.
--
-- Methodology we WOULD run once the above is available:
--   Treatment group : accounts targeted under the new policy after the cutover
--   Control group    : accounts/segments still following the old policy
--                       (holdout) or, absent a holdout, a synthetic control
--                       built from pre-period segment x month recovery-rate
--                       trends (matching on risk_segment, dpd bucket, city tier)
--   Identification   : parallel-trends assumption for DiD -- checked by
--                       plotting pre-period trends for treated vs candidate
--                       control segments; if they do not move together
--                       pre-change, DiD is invalid and synthetic control /
--                       matching should be used instead.
--   Confounders to rule out : seasonality, portfolio vintage mix (checked
--                       flat in 02_forensics.sql item F), agent attrition,
--                       macro/collections-industry seasonality (e.g. salary
--                       cycles), and the payment-duplication artifact itself
--                       (must run this on golden_payments, never raw).
--   Limitation        : even with a clean cutover date, this book has only
--                       ~8 months of transactional history (Jan-Aug 2026),
--                       which limits pre-period length for parallel-trends
--                       validation to at most a few months on either side.
