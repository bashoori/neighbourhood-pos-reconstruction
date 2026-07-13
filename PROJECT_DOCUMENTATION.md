# Project Documentation — neighbourhood-pos-reconstruction

A record of the work completed so far, task by task: what was done, why, what was found, and
how it was verified. Written to be read on its own — no need to re-run the notebooks to
understand what happened.

## Overview

**Scenario:** Neighbourhood Made Co-op, a nonprofit gift shop, exports a flat CSV of POS
transaction line items with no clean invoice structure. The goal is to profile it, validate
assumptions about how it's organized, reconstruct the real transactions hidden inside it, and
eventually model it into a normalized, Microsoft-platform-ready schema — practice for the
Atira Data Modeler (Forms-to-Repository Migration) role.

**Environment:** GitHub Codespace, Python 3.12.1, pandas + Jupyter notebooks. See `SETUP.md`
for the full environment setup log.

**Data:** `data/raw_pos_export.csv` (131 rows, one row per line item, 17 columns) and
`data/store_lookup.csv` (store reference table).

---

## Task 1 — Profiling

**Objective:** Establish exactly how messy the data is, with real counts, before assuming
anything about its structure.

**Method:** Loaded `raw_pos_export.csv` in `01_profile.ipynb` and checked null rates, exact
duplicates, and distinct value counts on the columns most likely to carry data quality issues.

**Findings:**

- 131 rows, 17 columns, no fully-null columns.
- `invoice_number` populated on only 38/131 rows (~29%) — not reliable as a grouping key on
  its own.
- `line_note` populated on only 7/131 rows (~5%) — mostly blank by design.
- `unit_price_raw`, `transaction_ts`, and `product_sku` each have a small number of missing
  values.
- **2 exact duplicate rows** once `row_id` is excluded from the comparison. (`row_id` alone
  made every row look "unique," since it's a sequential export number, not a business key —
  `df.duplicated()` on the full row returns 0 for this reason; dropping `row_id` first is
  what surfaces the real duplicates.)
- `category_raw` shows 8 distinct values but collapses to 4 once case-folded
  (`.str.lower()`) — inconsistent casing, not real categories (e.g. `Home` vs `HOME`).
- **Store ID mismatch:** `ST99` appears in the export but does not exist in
  `store_lookup.csv`; `ST04` exists in the lookup table but is never used in the export.

---

## Task 2 — Validating Assumptions About Structure and Sorting

**Objective:** Test — rather than assume — whether the data's structural signals (timestamp,
row order, invoice numbers) can be trusted before building any grouping logic on top of them.

**Method:** Parsed `transaction_ts` and checked how many rows failed; compared `row_id` order
against true timestamp order.

**Key finding:** A naive `pd.to_datetime(df["transaction_ts"])` failed to parse **108 of 131
rows**, even though only one value in the column is actually blank. The cause: the column
mixes more than one timestamp format (ISO, `MM/DD/YYYY hh:mm AM/PM`, date-only, and
`DD-Mon-YYYY hh:mm`), and pandas' default behavior infers a single format from the first few
rows, then coerces every row that doesn't match that inferred format to `NaT` — instead of
trying each row's format individually.

**Fix:** `pd.to_datetime(df["transaction_ts"], format="mixed", errors="coerce")` — parses each
row on its own terms. This brought the failure count down to the single row with a genuinely
blank timestamp.

**Why this matters:** Every downstream step (sorting, gap-based grouping, invoice
reconstruction) depends on trustworthy time ordering. Building on the naive parse would have
silently corrupted almost the entire dataset's effective time order without raising an error.

---

## Task 3 — Reconstructing Invoices from Line Items

**Objective:** Since `invoice_number` can't be trusted as a grouping key (Task 1), define and
apply a rule to group line items into real transactions, then verify it against actual data
rather than trusting it by construction.

**Rule:** A new transaction starts whenever the store, register, or customer changes, or more
than `GAP_MINUTES = 2` has passed since the previous line item at that same store + register +
customer. Each transaction gets a surrogate `reconstructed_txn_id` — `invoice_number` is kept
as a reference attribute, not used as the key.

### Bugs found and fixed

**Bug 1 — walk-in customers over-split.** `pandas.groupby()` silently drops rows whose
grouping key is `NaN` by default. Walk-in customers have a blank `customer_ref`, which
`pd.read_csv` reads in as `NaN` — so every walk-in line item was being excluded from its own
group's `shift()` calculation, making every single walk-in line look like the start of a new
transaction, even when several were seconds apart.
**Fix:** `df.groupby([...], dropna=False)` — keeps `NaN` as a valid group instead of dropping
it.

**Bug 2 — a missing timestamp caused a transaction to be mislabeled.** Row 63 (a Canvas Tote
Bag line, invoice `INV-1009`) has a blank `transaction_ts`. `NaT` values sort to the *end* of
their entire `(store_id, register_id)` partition — not just later than their true neighbors,
but past every other customer's rows too. This placed row 63 immediately after an unrelated
customer's transaction in the sorted data. The transaction ID assignment (`cumsum()` over the
full sorted order) is positional, so row 63 inherited that unrelated transaction's ID instead
of its own.
**Detected by:** a `needs_manual_review` flag (`True` when a transaction contains any line
with an unparseable timestamp) — built deliberately for this situation.
**Fixed by:** using `invoice_number` as corroborating evidence — row 63 shares `INV-1009` with
rows 62 and 64, confirming where it actually belongs. Manually reassigned
`reconstructed_txn_id` accordingly.

### Known edge cases (documented, not silently hidden)

| Case | Cause | Resolution |
|---|---|---|
| `INV-1000` maps to 2 transactions | Deliberately planted register-counter-reset scenario — two real transactions share a reused invoice number | Correct behavior: the rule kept them separate rather than trusting the colliding number |
| Row 63 / `INV-1009` mislabeled | Missing timestamp sorts to end of partition, corrupting positional ID assignment | Caught by `needs_manual_review` flag, corrected using `invoice_number` |
| `ST01` transaction merging `INV-1007` and `INV-1013` | Date-only timestamp format collapses to midnight, losing time-of-day resolution — two distinct transactions become indistinguishable by time | **Not yet re-verified after the latest fixes** — flagged as an open item below, since `needs_manual_review` only catches *missing* timestamps, not *coarse* ones |

### Verification

- Invoice numbers still mapping to more than one transaction after fixes: only `INV-1000`
  (expected, by design).
- Transactions still flagged for manual review: 1 (`reconstructed_txn_id = 44`, the corrected
  row-63 case — flag correctly stays `True` since the underlying timestamp is still genuinely
  missing, even though the ID is now correct).
- Row-count reconciliation: 131 total line items, 131 summed across all reconstructed
  transactions — nothing lost or double-counted.
- Result: **63 real transactions** reconstructed from 131 line items.

### Output

Persisted to `output/practice.db`:

- `staging_line_items` — line-item level, includes `reconstructed_txn_id`
- `staging_transactions` — one row per reconstructed transaction

---

## Open Items Before Task 4

- Re-run the "does one transaction contain more than one invoice number" check
  (`transactions[transactions["invoice_numbers_seen"].apply(len) > 1]`) after the final fixes
  to confirm whether the `ST01` / date-only merge case (`INV-1007` + `INV-1013`) is still
  present. It wasn't caught by `needs_manual_review` since those timestamps parsed
  successfully — they're just too coarse to distinguish separate transactions.
- Decide how to handle it if still present: flag for manual review (extend the review-flag
  logic to also catch same-day, same-customer, same-register transactions with no time-based
  way to separate them), or document it as an accepted limitation of the source data's
  granularity.

## Task 4 — Build the Logical and Physical Data Model

**Objective:** Design a normalized structure from `staging_transactions` and
`staging_line_items` — reference entities for customer, product, and store, plus a
transaction/invoice entity and a line-item entity — and produce both an ERD and the physical
T-SQL schema.

### Design decisions

- **Natural keys used where the data supports one:** `customer_id`, `product_sku`, `store_id`.
  `invoice_number` is never a key anywhere in the schema — Task 2 proved it isn't unique
  (`INV-1000` reuse), so it's kept only as a traceability attribute on `fact_transaction`.
- **Surrogate keys reused, not regenerated:** `transaction_id` and `line_id` reuse the ids
  already produced during Task 3 reconstruction (`reconstructed_txn_id`, `row_id`) rather than
  new `IDENTITY` values — every row in the model stays traceable back to the exact notebook
  step that produced it.
- **Walk-ins get no `dim_customer` row.** Blank `customer_ref` means no reliable customer key
  exists — `fact_transaction.customer_id` is nullable rather than forced to a placeholder
  value that would misrepresent an unknown customer as a known one.
- **`ST99` gets an explicit `dim_store` row** (`store_name = 'UNKNOWN / UNMAPPED'`), rather
  than leaving an orphaned foreign key or silently dropping those transactions. This resolves
  Task 1's store mismatch finding directly in the schema instead of deferring it.
- **`product_sku`, `qty`, and `unit_price` on `fact_transaction_line` are nullable.** A
  handful of source rows (Task 1 findings) have no resolvable value for these — forcing a
  placeholder (e.g. `qty = 0` or a fake SKU) would misrepresent genuinely missing data as a
  real observation.
- **Canonical attribute values picked by frequency, not fuzzy matching.** Where a natural key
  is reliable but its descriptive attributes vary in spelling (customer names/emails, product
  names, category casing), the most frequently occurring non-blank raw value is used as the
  canonical value, rather than attempting identity resolution — the key already solves
  identity; the attribute just needs cleanup.

### Entities

| Table | Grain | Key |
|---|---|---|
| `dim_customer` | one row per known customer | `customer_id` (natural, from `customer_ref`) |
| `dim_product` | one row per SKU | `product_sku` (natural) |
| `dim_store` | one row per store, including unmapped ones | `store_id` (natural) |
| `fact_transaction` | one row per reconstructed transaction | `transaction_id` (surrogate, reused from Task 3) |
| `fact_transaction_line` | one row per original line item | `line_id` (surrogate, reused `row_id`) |

Physical schema: `sql/schema.sql` (T-SQL). ETL and verification: `notebooks/04_model.ipynb`.

### Verification

Built and tested end to end before handing off:

- All 5 tables create cleanly from the T-SQL DDL (SQLite's type affinity accepts `NVARCHAR`,
  `DATETIME2`, `DECIMAL`, `BIT` as written, no rewrite needed to prove the schema out locally).
- Row counts: `dim_customer` 6, `dim_product` 10, `dim_store` 5 (4 from `store_lookup.csv` + 1
  placeholder for `ST99`), `fact_transaction` 63, `fact_transaction_line` 131.
- Four explicit referential integrity checks (store FK, customer FK, line→transaction FK,
  line→product FK), each via anti-join since SQLite doesn't enforce FKs by default — **all
  four passed with zero orphans.**

### Next Steps — Task 5

Resolve and formally document the store reference mismatch (already handled structurally via
the `ST99` placeholder row in `dim_store` — Task 5 is about writing up the reasoning behind
that decision explicitly, as the brief requires a documented judgment call, not just a working
schema).
