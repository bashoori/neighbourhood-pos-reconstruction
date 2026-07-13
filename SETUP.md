# Setup & Workflow Log — neighbourhood-pos-reconstruction

A clean record of the commands used to stand up this project in a GitHub Codespace, from repo
creation through the first completed task. Reuse this as a template for the next practice
project.

## 1. Create the repo

On GitHub: **New repository** → name it (e.g. `neighbourhood-pos-reconstruction`) → create.

## 2. Add the project files

Upload `raw_pos_export.csv`, `store_lookup.csv`, the project brief document,
`solution_hints.md`, `README.md`, and `scenario_and_tasks.txt` to the repo (drag-and-drop via
the GitHub web UI, or push from a local clone).

## 3. Launch the Codespace

Repo page → **Code** (green button) → **Codespaces** tab → **Create codespace on main**.

## 4. Set up the folder structure

In the Codespace terminal, at the repo root:

```bash
mkdir -p data notebooks sql output
mv raw_pos_export.csv store_lookup.csv data/
```

## 5. Sanity-check the Python environment

Quick REPL check (optional — confirms the interpreter and sqlite3 both work before doing real
work):

```bash
python3
```

Then at the `>>>` prompt:

```python
import sqlite3
conn = sqlite3.connect("output/practice.db")
exit()
```

`output/practice.db` should now exist.

**Or do this directly in the notebook instead** (cleaner — keeps everything in one place). In
`notebooks/01_profile.ipynb`, add a cell:

```python
import sqlite3

conn = sqlite3.connect("../output/practice.db")
```

Two differences from the REPL version: no `exit()` needed (the kernel just keeps running
between cells), and the path is `../output/practice.db` instead of `output/practice.db`,
since the notebook's working directory is `notebooks/`, not the repo root. Reuse this same
`conn` in later cells when writing the reconstructed transactions in Task 4 — or start a
separate notebook (e.g. `notebooks/04_model.ipynb`) for that step if you'd rather keep
profiling and modeling apart.

## 6. Install packages

```bash
pip install pandas jupyter matplotlib openpyxl
```

## 7. Create the first notebook

In the Explorer: right-click `notebooks/` → **New File** → name it `01_profile.ipynb`.

When prompted for a kernel: **Select Another Kernel** → **Python Environments...** → choose
the `Python 3.12.1 (~/.python/current/bin/python3, Global Env)` entry — the same interpreter
the pip installs above went into.

## 8. Task 1 — Profile the data

Run each of these in its own cell (Shift+Enter), building on the previous cell's imports:

```python
import pandas as pd

df = pd.read_csv("../data/raw_pos_export.csv")
df.info()
```

```python
df.isnull().sum()
```

```python
# null rates as percentages — easier to read than raw counts
(df.isnull().mean() * 100).round(1)
```

```python
# duplicates ignoring row_id, since row_id alone makes every row look unique
df.drop(columns="row_id").duplicated().sum()
```

```python
# distinct value counts for the columns called out in Task 1
df[["store_id", "category_raw", "payment_method"]].nunique()
```

```python
# does case-folding collapse categories down?
df["category_raw"].str.lower().nunique()
```

```python
# compare store_id sets between the two files
stores = pd.read_csv("../data/store_lookup.csv")
print("in export but not lookup:", set(df["store_id"]) - set(stores["store_id"]))
print("in lookup but not export:", set(stores["store_id"]) - set(df["store_id"]))
```

**Findings confirmed from this Codespace run:**

- 131 rows, 17 columns
- `invoice_number` non-null on only ~29% of rows
- `line_note` non-null on only ~5% of rows
- 2 exact duplicate rows once `row_id` is excluded
- `category_raw`: 8 distinct values, collapses to 4 once case-folded
- Store mismatch: `ST99` in export but not lookup; `ST04` in lookup but not export

Add a markdown cell in the notebook (`+ Markdown`) with these findings written out in plain
language — that's the actual Task 1 deliverable.

## 9. Commit and push

From the terminal (not inside the notebook):

```bash
git add .
git commit -m "Task 1: profile raw POS export, confirm data quality issues"
git push
```

First push from a new Codespace, if it asks about upstream:

```bash
git push -u origin main
```

Or via the UI: **Source Control** icon (sidebar) → type commit message → checkmark to commit
→ **Sync Changes** to push.

**Habit going forward:** commit after each task, not one giant commit at the end — gives you
a clean, presentable history.

## Reminders

- Jupyter kernels default to the notebook's own folder as the working directory, not the repo
  root — hence `../data/...` instead of `data/...` inside `notebooks/01_profile.ipynb`.
- Don't paste Python into the bash terminal — it only understands shell commands. Python code
  goes in a notebook cell or a `python3` REPL session.
- Save the notebook (Cmd/Ctrl+S) before committing, so the `.ipynb` file on disk includes the
  outputs you just generated.
