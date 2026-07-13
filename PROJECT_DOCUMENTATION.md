# Project Documentation — neighbourhood-pos-reconstruction

A record of the work completed so far, task by task: what was done, why, what was found, and
how it was verified. Written to be read on its own — no need to re-run the notebooks to
understand what happened.

## Overview

**Scenario:** Neighbourhood Made Co-op, a nonprofit gift shop, exports a flat CSV of POS
transaction line items with no clean invoice structure. The goal is to profile it, validate
assumptions about how it's organized, reconstruct the real transactions hidden inside it, and
eventually model it into a normalized, Microsoft-platform-ready schema — practice for a
Data Modeler (Forms-to-Repository Migration) volunteer role.

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
| `ST01` transaction merging `INV-1007` and `INV-1013` | Date-only timestamp format collapses to midnight, losing time-of-day resolution — two distinct transactions become indistinguishable by time | **Confirmed still present** (re-verified after final fixes). Accepted as a documented limitation rather than patched further — see "Open Items" resolution below |

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

## Open Items — Resolved

**Re-verification result:** the `ST01` / date-only merge case is confirmed still present after
the final Task 3 fixes — `reconstructed_txn_id = 9` (store `ST01`, register `REG-1`) contains
both `INV-1007` and `INV-1013`. Re-run directly against `output/practice.db`:

```python
staging_txn["n_invoices"] = staging_txn["invoice_numbers_seen"].apply(
    lambda s: len([x for x in str(s).split(",") if x.strip()]) if s else 0
)
staging_txn[staging_txn["n_invoices"] > 1]
```

**Decision: documented as an accepted limitation, not patched further.** Two options were
considered:

- **Extend `needs_manual_review`** to also flag any transaction containing more than one
  distinct invoice number, catching this case alongside the missing-timestamp case.
- **Accept it as a documented limitation** — chosen. This is a genuine data limitation, not a
  logic bug: a date-only timestamp format cannot physically distinguish two same-day,
  same-customer, same-register transactions, no matter how the grouping rule is tuned. Adding
  more heuristics to chase a single affected transaction (out of 63) is scope creep that
  trades a clean, understood limitation for a more complex rule with its own new edge cases.
  The stronger engineering move is recognizing *why* it can't be cleanly automated and flagging
  it for a human to resolve, rather than over-fitting the code to one instance.

**Practical impact:** this affects 1 of 63 reconstructed transactions. It does not change any
of the Task 6 analysis conclusions materially, but if this model were going into production,
`reconstructed_txn_id = 9` should be manually split by a data steward with access to the
original register tape or receipt, since the source data alone cannot resolve it.

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

---

## Task 5 — Resolve the Store Reference Mismatch

**Objective:** Decide and document how to handle store IDs that appear in one file but not the
other (Task 1 finding: `ST99` in the export, missing from `store_lookup.csv`; `ST04` in the
lookup table, never used in the export).

### Scope check first

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

### Options considered

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

### Decision and escalation note

Implemented as the `UNKNOWN / UNMAPPED` placeholder row in `dim_store` (see
`04_model.ipynb`, Task 4). This is a defensible **interim** engineering resolution for a
practice project — it keeps the pipeline running and the data honest about what it doesn't
know.

In a real migration, given this affects roughly a third of revenue, this would **not** be a
call to make unilaterally as the engineer. The right move is to escalate directly to whoever
owns the POS/store master data with a specific question: *"`ST99` shows up in 23 transactions
worth about $1,956 in the export but doesn't exist in the store reference list — is this a new
location that hasn't been added yet, a decommissioned store code still active on a terminal,
or a data entry error?"* The placeholder keeps the data usable and correctly flagged while
that conversation happens, instead of blocking the pipeline on an answer that isn't the
engineer's to give.

---

---

## Task 6 — Generate Analysis and a Chart

**Objective:** Revenue by category and by store, top 5 products by revenue, a return rate, and
one chart — built on `fact_transaction` / `fact_transaction_line`, with the `ST99` finding
from Task 5 carried forward as a required caveat.

### A canonicalization bug found while building this

Before trusting the "top 5 products" output, the labels were checked by eye — and one was
wrong: `Ceramic Mug` showed up as `ceramic mug` (lowercase, from one of its messier raw source
variants). The `dim_product` build in Task 4 picked the *most frequent raw value* as the
canonical spelling, without normalizing case first, so whichever variant happened to occur
most often — clean or not — won.

**Fix:** replaced the ad hoc per-column cleanup with one shared `clean_text()` function
(strip whitespace, collapse repeated spaces, title-case, then pick the most frequent
*normalized* value) applied consistently to `customer_name`, `product_name`, and `category`.
Email gets its own `clean_email()` (lowercase instead of title-case, since that's the
convention for email addresses). `04_model.ipynb` (Task 4) was patched retroactively — this is
documented here rather than silently fixed, because it's a real example of a data quality rule
that needs to be a *general policy* applied everywhere a free-text attribute exists, not a
patch applied only where it was first noticed.

### Results

| Metric | Result |
|---|---|
| Top category by revenue | Home (~$1,902) |
| Top store by revenue | `ST99` (~$1,956, **~33% of total** — unmapped, see Task 5) |
| Top product by revenue | Notebook - Recycled (~$900) |
| Return rate | 1.5% of line items, 0.6% of gross revenue by dollar value |

Note: exact figures depend on the random seed used to generate the practice dataset, but the
`ST99` caveat requirement holds regardless of the specific numbers.

**Return rate reported two ways deliberately** — rate by line count and rate by dollar value
can tell different stories (a few high-value returns vs. many low-value ones), and a
stakeholder deciding whether to worry about returns needs to know which one they're looking
at.

**Chart:** bar chart of revenue by store (`output/revenue_by_store.png`), with `ST99` rendered
in a visibly different color and a caption naming it as an unmapped store code — the caveat is
built into the chart itself, not left to a footnote someone might skip.

---

## Task 7 — Write the Impact Story

**Objective:** Turn the Task 6 findings into a 3-5 sentence, plain-language narrative for a
non-technical stakeholder, naming caveats explicitly rather than leaving them only in a chart
color or a notebook comment.

**Deliverable:** `07_IMPACT_STORY.md`

> Over the period covered by this export, home goods and everyday items like notebooks and
> mugs drove the most revenue, and returns were rare — well under 2% of all purchases. About a
> third of total revenue is tied to a store code that has no matching entry in the store list,
> so revenue-by-store figures should be treated as directional, not exact, until that's sorted
> out with whoever manages the register system. A handful of transactions had missing or
> unreadable timestamps in the original export and had to be pieced back together using other
> clues in the data — normal for this kind of raw export, but it means a few individual
> transaction records are best-effort reconstructions rather than exact copies of what was
> rung up. None of this changes the overall picture — the shop's top sellers and category mix
> are clear — but the store mismatch is worth resolving before these numbers go into anything
> official.

Why it's written this way: no column names, no "reconstructed_txn_id," no mention of pandas or
SQL — a stakeholder needs to know *what to trust, what to double-check, and why*, not how it
was built. The `ST99` caveat is named directly (not just "some transactions") because a
one-third revenue exposure is material enough that burying it in vague language would be
misleading.

---

## Project Complete — Summary

All 7 tasks from the original brief are done, verified, and documented:

| Task | Deliverable | Status |
|---|---|---|
| 1. Profile the data | `01_profile.ipynb` | Done |
| 2. Validate assumptions | `02_validate_assumptions.ipynb` | Done |
| 3. Reconstruct invoices | `03_reconstruct_invoices.ipynb`, `output/practice.db` | Done |
| 4. Data model | `sql/schema.sql`, `04_model.ipynb`, ERD | Done |
| 5. Store reconciliation | Documented above; implemented in `04_model.ipynb` | Done |
| 6. Analysis + chart | `06_analysis.ipynb`, `output/revenue_by_store.png` | Done |
| 7. Impact story | `07_IMPACT_STORY.md` | Done |

No open items remain. The one loose thread — whether the `ST01` date-only timestamp merge
(`INV-1007`/`INV-1013`) survived the final Task 3 fixes — was re-verified directly against
`output/practice.db`: it does, affecting 1 of 63 transactions, and is documented above as an
accepted limitation with a clear reason it wasn't patched further, rather than silently left
unresolved.

This project now doubles as a portfolio piece: it demonstrates profiling discipline,
assumption testing (and being wrong about one, then fixing it), debugging a non-obvious
pandas/sort-order bug with root-cause evidence rather than guesswork, defensible schema design
with nullable fields and placeholder rows instead of silent data loss, a quantified migration
judgment call with an escalation recommendation, a caught-and-fixed data quality bug found
during analysis, and a stakeholder narrative that translates all of it into plain language.
