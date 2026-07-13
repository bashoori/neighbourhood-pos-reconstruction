-- ============================================================================
-- neighbourhood-pos-reconstruction -- Task 4 physical schema (T-SQL)
--
-- Source: output/practice.db, tables staging_transactions and
-- staging_line_items, built in 03_reconstruct_invoices.ipynb.
--
-- Design decisions (see PROJECT_DOCUMENTATION.md, Task 4, for full reasoning):
--   - Natural keys used where the source data has one that survives Task 1/2's
--     data quality checks: customer_id, product_sku, store_id. invoice_number
--     is NOT a key anywhere -- it's kept as a traceability attribute only,
--     since Task 2 proved it isn't unique.
--   - transaction_id / line_id reuse the surrogate ids already produced during
--     reconstruction (reconstructed_txn_id, row_id) rather than new IDENTITY
--     values, so every row stays traceable back to the notebook that built it.
--   - Walk-in customers (blank customer_ref) get no dim_customer row --
--     fact_transaction.customer_id is NULLable, not forced to a placeholder.
--   - ST99 (seen in the export, absent from store_lookup.csv -- see Task 1)
--     gets an explicit dim_store row with a placeholder name, instead of
--     silently dropping those transactions or leaving an orphaned FK.
--   - product_sku / qty / unit_price on fact_transaction_line are NULLable,
--     because a handful of source rows (Task 1 findings) have no resolvable
--     value for them -- forcing a placeholder would misrepresent the data.
-- ============================================================================

CREATE TABLE dim_customer (
    customer_id     NVARCHAR(10)    NOT NULL PRIMARY KEY,
    customer_name   NVARCHAR(100)   NOT NULL,   -- canonical spelling: most frequent raw variant for this id
    customer_email  NVARCHAR(150)   NULL        -- canonical email: most frequent non-blank raw variant
);

CREATE TABLE dim_product (
    product_sku     NVARCHAR(20)    NOT NULL PRIMARY KEY,
    product_name    NVARCHAR(100)   NOT NULL,   -- canonical name: most frequent raw variant for this SKU
    category        NVARCHAR(50)    NOT NULL    -- case-normalized (Task 1: 8 raw values collapse to 4)
);

CREATE TABLE dim_store (
    store_id        NVARCHAR(10)    NOT NULL PRIMARY KEY,
    store_name      NVARCHAR(100)   NOT NULL    -- 'UNKNOWN / UNMAPPED' for store ids with no lookup match
);

CREATE TABLE fact_transaction (
    transaction_id       INT             NOT NULL PRIMARY KEY,  -- = reconstructed_txn_id from Task 3
    store_id              NVARCHAR(10)    NOT NULL,
    register_id            NVARCHAR(10)    NOT NULL,
    customer_id            NVARCHAR(10)    NULL,                 -- NULL = walk-in, no reliable customer key
    start_ts                DATETIME2       NULL,                 -- NULL possible if underlying rows were unparseable
    end_ts                  DATETIME2       NULL,
    invoice_number          NVARCHAR(60)    NULL,                 -- traceability only -- NOT unique, do not use as a key
    needs_manual_review     BIT             NOT NULL DEFAULT 0,   -- carried from Task 3's flag
    CONSTRAINT FK_transaction_store    FOREIGN KEY (store_id)    REFERENCES dim_store(store_id),
    CONSTRAINT FK_transaction_customer FOREIGN KEY (customer_id) REFERENCES dim_customer(customer_id)
);

CREATE TABLE fact_transaction_line (
    line_id         INT             NOT NULL PRIMARY KEY,  -- = row_id from the raw export
    transaction_id  INT             NOT NULL,
    product_sku     NVARCHAR(20)    NULL,                   -- NULL = source row had no resolvable SKU
    qty             INT             NULL,                   -- NULL = source row had no resolvable quantity
    unit_price      DECIMAL(10,2)   NULL,                   -- NULL = source row's price string didn't parse
    discount_code   NVARCHAR(20)    NULL,
    payment_method  NVARCHAR(20)    NULL,
    line_note       NVARCHAR(100)   NULL,
    CONSTRAINT FK_line_transaction FOREIGN KEY (transaction_id) REFERENCES fact_transaction(transaction_id),
    CONSTRAINT FK_line_product     FOREIGN KEY (product_sku)    REFERENCES dim_product(product_sku)
);
