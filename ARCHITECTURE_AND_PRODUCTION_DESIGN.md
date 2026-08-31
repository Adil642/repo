# Production Analytics Architecture

## Pipeline diagram

```mermaid
flowchart LR
  subgraph SRC["Source Systems"]
    S1[(Telephony vendors)]
    S2[(WhatsApp/SMS providers)]
    S3[(Field ops app)]
    S4[(Payments gateway)]
    S5[(Loan mgmt system)]
  end

  subgraph RAW["Raw Layer"]
    R1[(raw.* tables\nappend-only, as-landed)]
  end

  subgraph STG["Staging"]
    T1[Type cast + timezone tag]
    T2[Schema-version normalize\n(v1/v2/v3/legacy -> canonical)]
  end

  subgraph CLN["Clean"]
    C1[Dedup: payments by\nCOALESCE(ref,id)]
    C2[Dedup: calls by call_id]
    C3[Borrower SCD collapse]
    C4[Agent identity: use\ntxn agent_id only]
  end

  subgraph GLD["Golden"]
    G1[(golden_accounts)]
    G2[(golden_payments)]
    G3[(golden_calls / attempts)]
    G4[(golden_ptp)]
    G5[(golden_borrowers)]
  end

  subgraph FEAT["Feature Layer"]
    F1[Account-month features:\nDPD, risk, contact history]
    F2[Agent-month performance]
    F3[Campaign-month performance]
  end

  subgraph MET["Metrics Layer"]
    M1[Recovery rate, RPC,\nPTP rate/kept-rate]
    M2[Contact rate, cost/recovered*]
    M3[Channel conversion]
  end

  subgraph OUT["Consumption"]
    D1[Executive Dashboard]
    D2[Ops/Agent Dashboards]
    D3[Alerting / Anomaly detection]
  end

  SRC --> RAW --> STG --> CLN --> GLD --> FEAT --> MET --> OUT
```

*Cost/rupee-recovered requires a cost table not present in the source system today — see Data Quality Report item 10.

## Data contracts

Each source feed publishes to `raw.<table>` under a contract that specifies:
- **Primary key** and whether it is guaranteed unique at source (most are NOT, per this audit — `payments.payment_id` and `calls.call_id` both had exact duplicates; `agents.agent_id` has no reliable 1:1 identity at all).
- **Idempotency key** for replay-safe ingestion: `COALESCE(payment_reference, payment_id)` for payments; `call_id` for calls; `(account_id, event_at, status)` for status history.
- **Timezone contract**: every event-level table must carry its own `timezone` field (already true for `calls`, `accounts`, `agent_sessions`, `vendor_telephony`) — staging normalizes all timestamps to UTC before any calendar rollup.
- **Late-arrival SLA**: `recorded_at` vs `event_at` gap is tracked per source; a table breaching its SLA (e.g. events landing >72h late) triggers a backfill job rather than being silently included in the current day's roll-up.

## Primary keys & lineage

| Layer | Table | Primary key | Lineage tag |
|---|---|---|---|
| Golden | `golden_payments` | `COALESCE(payment_reference,payment_id)` | `_source_row_ids[]` (array of all raw rows collapsed into this record) |
| Golden | `golden_accounts` | `account_id` | 1:1 passthrough |
| Golden | `golden_calls` | `call_id` | first-seen row |
| Golden | `golden_borrowers` | `borrower_id` | latest-complete row + `_dropped_row_count` |
| Golden | `golden_agents` | `agent_id` (txn tables only) | `agents.csv` dimension flagged `low_confidence=true`, never used as an authoritative join key for tenure/vendor claims |

Every golden table carries `_source_row_ids`, `_dedup_rule_version`, and `_loaded_at` so any metric can be traced back to the exact raw rows that produced it — this is what would have caught the payment-duplication issue in real time rather than 8 months later.

## Incremental processing & backfills

- **Incremental**: staging→clean→golden runs on a daily micro-batch keyed by `_loaded_at` watermark per source table, not by `event_at` (event_at is late-arriving and vendor-timezone-dependent, so it's a poor incremental cursor).
- **Backfill**: any change to a dedup or attribution rule (e.g. this audit's payment dedup logic) is versioned (`_dedup_rule_version`) and re-run against the full raw history, never patched in place — golden tables are always fully reproducible from raw + rule version.
- **Late-arriving data**: events landing after their day's golden partition has closed are appended to the next partition with a `_late_arrival=true` flag and trigger a re-aggregation of the affected month's metrics rather than a silent drop.

## Data-quality checks & monitoring

Run on every load, blocking promotion to golden on failure:
1. **Uniqueness**: primary key uniqueness per the contract table above (would have caught the `payment_id`/`call_id` duplicates on day one).
2. **Referential integrity**: every `account_id`/`borrower_id`/`agent_id` in a fact table resolves in the corresponding dimension.
3. **Distribution drift**: month-over-month row count and `SUM(amount)` z-score vs trailing 6-month mean — flags exactly the kind of creeping duplication found in this audit (a steadily rising volume/amount ratio per unique reference is itself an anomaly signal).
4. **Duplication rate**: `1 - COUNT(DISTINCT COALESCE(payment_reference,payment_id)) / COUNT(*)` computed daily and alerted if it exceeds a rolling baseline by >2x — this single check would have surfaced the issue this audit found in January, not August.
5. **Denominator stability**: targeting-funnel size (`daily_targeting` unique accounts) vs open-book size, alerted if the ratio moves >X% week over week (guards against denominator manipulation, forensics item G).

## Anomaly detection

Simple, explainable methods preferred over black-box models, per the assignment's own guidance:
- Rolling z-score (6-month trailing mean/stdev) on: recovery amount, duplication rate, contact rate, PTP kept-rate, per-channel volume.
- A metric that changes by >2 standard deviations without a corresponding, logged operational change (new campaign, new vendor, policy change) is auto-flagged for analyst review before it reaches the executive dashboard — this is the control that was missing and let a reporting artifact become a leadership-level claim.
