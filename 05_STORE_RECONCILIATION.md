# Task 5 — Resolve the Store Reference Mismatch

**Objective:** Decide and document how to handle store IDs that appear in one file but not the
other (Task 1 finding: `ST99` in the export, missing from `store_lookup.csv`; `ST04` in the
lookup table, never used in the export).

## Scope check first

Before deciding how to handle `ST99`, the honest first question is *how much of the data does
this actually touch* — "it's just one bad store code" and "a third of the dataset has no
verified store name" call for very different responses.

```python
# how much of the reconstructed data is tied to the unmapped store?
txn_count = pd.read_sql("SELECT COUNT(*) AS n FROM fact_transaction WHERE store_id = 'ST99'", conn)["n"].iloc[0]
total_txn = pd.read_sql("SELECT COUNT(*) AS n FROM fact_transaction", conn)["n"].iloc[0]
print(f"transactions at ST99: {txn_count} / {total_txn} ({txn_count/total_txn*100:.1f}%)")
```

**Result:**

| Metric | ST99 | Total | Share |
|---|---|---|---|
| Transactions | 23 | 63 | **36.5%** |
| Line items | 42 | 131 | **32.1%** |
| Revenue | $1,956.24 | $5,858.64 | **33.4%** |

This is not a rounding-error edge case — roughly a third of all reconstructed revenue is tied
to a store code with no confirmed name. That materially changes the right response.

## Options considered

1. **Drop transactions tied to `ST99`.** Rejected — destroys real transaction and revenue
   data because a reference table is incomplete, and at ~33% of revenue this would badly
   understate the business's actual activity.
2. **Leave an orphaned foreign key** (`fact_transaction.store_id` pointing to nothing in
   `dim_store`). Rejected — breaks referential integrity, causes silent join failures in any
   downstream report (a `JOIN` on `store_id` would just drop these rows without warning,
   which is worse than an error), and hides the problem instead of surfacing it.
3. **Add an explicit placeholder row in `dim_store`** (`store_name = 'UNKNOWN / UNMAPPED'`).
   **Chosen.** Preserves all transaction and revenue data, keeps referential integrity intact,
   and makes the gap impossible to miss — any report grouping by store immediately shows an
   `UNKNOWN / UNMAPPED` line with its real dollar figure attached, rather than the data
   quietly vanishing.
4. **Leave `ST04` in `dim_store` even though it's unused in the export.** No action needed —
   a store existing in the reference table with no recent transaction activity isn't a data
   quality problem, it's just an inactive or not-yet-opened location. Removing it would
   destroy valid reference data to solve a problem that doesn't exist.

## Decision and escalation note

Implemented as the `UNKNOWN / UNMAPPED` placeholder row in `dim_store` (see `04_model.ipynb`,
Task 4). This is a defensible **interim** engineering resolution for a practice project — it
keeps the pipeline running and the data honest about what it doesn't know.

In a real migration, given this affects roughly a third of revenue, this would **not** be a
call to make unilaterally as the engineer. The right move is to escalate directly to whoever
owns the POS/store master data with a specific question: *"`ST99` shows up in 23 transactions
worth about $1,956 in the export but doesn't exist in the store reference list — is this a new
location that hasn't been added yet, a decommissioned store code still active on a terminal,
or a data entry error?"* The placeholder keeps the data usable and correctly flagged while
that conversation happens, instead of blocking the pipeline on an answer that isn't the
engineer's to give.
