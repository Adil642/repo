# Collections Analytics — Submission Index

**Question:** Is the reported "recovery has improved 11% month-on-month" true?
**Answer: No.** It's a duplicate-payment reporting artifact. Deduplicated recovery actually declined ~19% Jan→Jul 2026, while every genuine operational metric (contact rate, PTP kept-rate, field-visit paid-rate, attempt frequency) stayed flat. Full reasoning in the notebook and memo below.

## Contents

| File | What it is |
|---|---|
| `EXECUTIVE_MEMO.docx` | 2-page memo for leadership: what happened, why, confidence, ₹10 Cr recommendation |
| `EXECUTIVE_DASHBOARD.html` | One-screen dashboard — open in any browser, no server needed |
| `ANALYSIS_NOTEBOOK.ipynb` | Full reasoning walkthrough: forensics → golden dataset → metric audit → driver analysis |
| `DATA_QUALITY_REPORT.md` | Every data issue found: detection method, rows affected, quantified business impact |
| `ARCHITECTURE_AND_PRODUCTION_DESIGN.md` | Production pipeline design (raw→staging→clean→golden→feature→metrics→dashboard), with Mermaid diagram, data contracts, DQ checks, anomaly detection |
| `sql/01_golden_dataset.sql` | Cleaning & dedup logic for every table |
| `sql/02_forensics.sql` | The 7 forensic checks (A–G) from the assignment brief, with findings inline as comments |
| `sql/03_metrics.sql` | Golden metric definitions (recovery rate, contact rate, PTP rate/kept-rate, recovery/agent-hour) and why each differs from the naive version |
| `sql/04_counterfactual.sql` | Why a formal targeting-strategy counterfactual could not be built from this data, and exactly what's missing |
| `golden_dataset/*.csv` | The cleaned, deduplicated analytical tables themselves |

## The four questions, in one paragraph each

**1. What happened?** Reported recovery numbers looked flat-to-improving because duplicate SUCCESS payment records grew from 3.8% of the reported total (Jan) to 28.6% (Aug). On deduplicated data, recovery fell from ₹184.1M to ₹148.7M (Jan→Jul, -19.2%) and accounts recovered fell from 2,338 to 1,868 (-20.1%). Nothing else in the funnel moved — the change is entirely in reporting, not operations.

**2. Why did it happen?** Portfolio mix (origination and among recovered accounts) is stable — ruled out. Operational quality (contact rate ~20%, PTP kept-rate ~25%, field-visit paid-rate ~16%, attempts/account ~1.3) is flat — ruled out. Targeting-funnel narrowing doesn't explain the naive-vs-golden gap either. The residual real decline (Fact) is not explained by anything in this dataset (Hypothesis: seasonality, portfolio aging, or a cost change not captured here).

**3. Is the 11% improvement real?** No. March 2026's *naive* MoM growth was +11.0%, which lines up with the reported figure — most likely source of the claim. Golden (deduplicated) definitions of every core metric are in `sql/03_metrics.sql`, each with a stated rationale for why it differs from what was likely reported.

**4. Where should the ₹10 Cr go?** Better borrower targeting — re-prioritize existing, already-flat contact volume toward higher-probability-of-payment accounts, rather than add capacity, automation, or infrastructure the data shows no bottleneck for. ROI cannot be point-estimated (no cost table exists in this package) — recommendation is a funded 60–90 day pilot, not a full upfront commitment. Full assumptions, downside scenario, and confidence range in `EXECUTIVE_MEMO.docx`.

## Key methodology notes

- All analysis on **golden** (deduplicated) tables only; August 2026 excluded from trend comparisons as a partial month (data ends Aug 8).
- `agents.csv` could not be used as an identity dimension — see Data Quality Report, Finding B — so no agent-tenure or vendor-attribution claims are made from it.
- Every conclusion in the notebook is explicitly labeled Fact / Strong Evidence / Correlation / Hypothesis.
