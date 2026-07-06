# Solution Hints — Open Only After You've Attempted the Tasks

This names the issues that were deliberately planted in `raw_pos_export.csv` and sketches one reasonable
approach. There's more than one defensible way to model this — the point is whether your reasoning holds up,
not whether it matches this exactly.

## Planted issues

1. **`invoice_number`** is populated on roughly a third of rows. One reused value (`INV-1000`) appears twice,
   simulating a register counter reset — a trap for anyone who assumes invoice numbers are globally unique.
2. **Timestamps** appear in four different formats, including a date-only format with no time component, and
   line items within the same transaction are NOT always in strict ascending time order (POS clock drift
   between line scans).
3. **Customer `C001` (Maria Gomez)** appears under multiple name spellings and email variants, including a
   blank email on some visits — an entity-resolution problem you have to decide how to handle (fuzzy match on
   name? treat as separate customers? flag for manual review?).
4. **`store_id` `ST99`** appears in the export but does not exist in `store_lookup.csv`. **`ST04`** exists in
   the lookup table but is never used in the export — both are realistic migration-reconciliation issues.
5. **Duplicate rows**: a small number of line items are exact duplicates of the row before them, simulating a
   POS double-submit glitch.
6. **Negative quantities** mark returns; some are same-visit exchanges, some are standalone.
7. **A handful of rows** have a blank `unit_price_raw`, `product_sku`, `qty`, or `transaction_ts` — decide
   whether to drop, impute, or flag these, and say why.

## One reasonable invoice-reconstruction rule

Group rows by `store_id` + `register_id` + `customer_ref` (or a resolved customer key) where consecutive
`transaction_ts` values are within roughly 2 minutes of each other. Walk-ins (`customer_ref` blank) should be
grouped by `store_id` + `register_id` + tight time window only, since there's no customer key to anchor on.
Flag any group where the gap between max and min timestamp exceeds a few minutes for manual review rather than
silently trusting it.

## One reasonable schema sketch (3NF-ish, star-adjacent)

- `dim_customer(customer_id PK, name, email)` — one row per resolved real person
- `dim_product(product_sku PK, product_name, category)`
- `dim_store(store_id PK, store_name)`
- `fact_transaction(transaction_id PK, store_id FK, register_id, customer_id FK NULLABLE, transaction_ts, payment_method, discount_code)`
- `fact_transaction_line(line_id PK, transaction_id FK, product_sku FK, qty, unit_price, line_note)`

`transaction_id` here is a surrogate key you generate during reconstruction — not the raw, unreliable
`invoice_number`. Keep `invoice_number` as an attribute on `fact_transaction` for traceability back to source,
even though you can't rely on it as the primary key.
