# DataExtractor.jl

**Module 2 (Extraction) of the SteelData Initiative pipeline.**

Module 1 (PDFTopicSorter.jl) sorts a pile of research PDFs into themes and topics.
This module reads each PDF and, using the Anthropic API, produces two kinds of file per
paper:

| Artifact | File name | What it is |
|---|---|---|
| **Schema** | `MBMA_9408_schema.svg` | A one-page flowchart of the paper's own structure: background → research program (parallel studies) → key output → synopsis → recommendations → outcome. Open it in any web browser. |
| **Data tables** | `MBMA_9408_Cain1995_Table5_ZSectionDimensions.csv` | One CSV per table of the paper's own numerical data: test specimens and dimensions, measured properties, test results, field measurements, and the paper's own analysis results (finite-element output, design factors, regression fits). Zero, one or many per paper. Values are copied exactly as printed; oddities are flagged in the header, never corrected. |

**What is included.** Every table of numbers the paper itself produced, whether measured
in a test or computed in an analysis. Left out: literature-review tables, other papers'
results, code/specification coefficient tables, symbol lists, and descriptive tables
without numbers. Each CSV says how its numbers were obtained on a `# Data basis:` line
(`measured: ...`, `computed: ...`, `input: ...` or `mixed: ...`), so you can filter
measured from computed tables afterwards with a text search.

The code tag (`MBMA_9408`) comes from the PDF filename prefix, e.g.
`254__MBMA_9408 - Title.pdf`.

---

## 1. One-time setup (Windows PowerShell)

You need Julia (already installed) and an Anthropic API key.

**a) Install the package.** Open PowerShell and run:

```powershell
cd "C:\Users\ELIKEM.ANYOMI\OneDrive\Desktop\RunToSolve\SteelDataInitiative\DataExtractor.jl"
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

This downloads the three libraries the package needs (HTTP, JSON and a bundled copy of
Poppler for reading PDFs). No separate Poppler install is required.

**b) Give it your API key.** Either of these works:

- Put a line `ANTHROPIC_API_KEY=sk-ant-...` in the `.env` file in the
  `SteelDataInitiative` folder (there is one there already). The package finds it
  automatically when you run from inside that folder or any of its sub-folders.
- Or set it for the current PowerShell window:

  ```powershell
  $env:ANTHROPIC_API_KEY = "sk-ant-..."
  ```

---

## 2. Running it

Always start Julia from the package folder with `--project=.` so it finds its libraries:

```powershell
cd "C:\Users\ELIKEM.ANYOMI\OneDrive\Desktop\RunToSolve\SteelDataInitiative\DataExtractor.jl"
julia --project=.
```

You are now at the Julia prompt (`julia>`). Type:

```julia
using DataExtractor
```

### A whole folder (the normal case)

```julia
extract_papers("C:/Users/ELIKEM.ANYOMI/OneDrive/Desktop/RunToSolve/SteelDataInitiative/test_pdfs_sorted")
```

- Give it **PDFTopicSorter's output folder** (the one with `index.csv`) and it reuses the
  P-codes, titles, themes and topics from Module 1.
- Or give it **any folder of PDFs**; sub-folders are searched too.
- Results go to a folder next to the input named `<input>_extracted`, e.g.
  `test_pdfs_sorted_extracted`. Choose your own with `out=`:

```julia
extract_papers("C:/path/to/pdfs"; out="C:/path/to/results")
```

Use forward slashes `/` in paths inside Julia, or double the backslashes (`C:\\path`).

### A single PDF

```julia
extract_paper("C:/path/to/254__MBMA_9408 - Some Report.pdf")
```

Its files go to a folder named `extracted` next to the PDF (or wherever `out=` says).

### Leaving Julia

Type `exit()` or press `Ctrl+D`.

### Running everything in one line from PowerShell

```powershell
julia --project=. -e "using DataExtractor; extract_papers(\"C:/path/to/pdfs\")"
```

---

## 3. What you get

```
test_pdfs_sorted_extracted/
├── MBMA_7505_schema.svg
├── MBMA_7505_Douty1975_Table3_BoltTensionResults.csv
├── MBMA_7505_Douty1975_Table4_PlateDeflections.csv
├── MBMA_9808_schema.svg                      ← a paper with no data tables gets only its schema
├── extraction_index.csv                      ← one row per paper: status, files written
└── _logs/
    ├── MBMA_7505_structure.json              ← the model's answer behind the SVG
    ├── MBMA_7505_tables.json                 ← the model's answer behind the CSVs (+ which files were written)
    ├── usage.jsonl                           ← one line per API call: tokens and estimated cost
    ├── usage_total.json                      ← running total over all runs into this folder
    └── run_2026-09-21.log                    ← everything that happened, including skipped files and why
```

### CSV header format

Every CSV starts with comment lines (beginning with `#`) that describe the table, then
the column header, then the data rows:

```
# Source: MBMA_9408 | Cain, D.E. (1995), Table V, cont'd, pp.34-37
# Tag: MBMA_9408_TABLE5_ZSECTIONDIMENSIONS
# Content: Measured cross-sectional dimensions of Z-section web crippling test specimens (EOF loading condition).
# Units: all columns in inches
# ANOMALY FLAG: source table lists the fourth Z2 specimen with duplicate label "Z2.3-F"; preserved verbatim, not corrected
# "-F" suffix in specimen_id denotes flanges fastened to support
specimen_id,t_in,b1_in,b2_in,d1_in,d2_in,d3_in,r_in,n_in,l_in
Z1.1,0.061,1.656,1.750,6.469,0.406,0.406,0.250,2.625,30.000
```

Column names are short lowercase `snake_case` with the unit as a suffix
(`t_in`, `h_in`, `fy_ksi`, `p_test_kip`; dimensionless columns have no suffix).
Every column is then defined in plain words in a `# Column definitions:` block, one line
per column, taken from the paper's text, figures and nomenclature:

```
# Column definitions:
#   specimen_id = test specimen label; -F suffix means flanges fastened to the support
#   t_in = base metal thickness of the Z-section, inches
#   l_in = span length between supports, inches
```

If the paper never defines a symbol, the line says so instead of guessing.
The `ANOMALY FLAG` line appears only when the printed table has something odd.

Every CSV also carries an `# EXTRACTION QUALITY:` line. Read it before trusting the numbers:

| grade | meaning |
|---|---|
| `clean` | values copied exactly as they came out of the PDF text |
| `ocr_repaired` | the PDF's text layer had obvious OCR slips (a letter `l` where a `1` was printed, etc.); each repaired cell is listed under `ANOMALY FLAG` |
| `reconstructed` | the text layer was badly damaged (old typewritten scans often lose every decimal point or the column headings); the model inferred what it could and says exactly what it inferred. **Check these against the PDF before using them.** The run log lists them with a warning. |

Errors that are *in the printed source* (a duplicated specimen label, a mis-numbered
row) are never corrected; they are kept verbatim and described under `ANOMALY FLAG`.
Most spreadsheet programs and data tools skip `#` lines; if yours does not, delete them
or tell it the comment character is `#`.

### The SVG schema

Open it by double-clicking (it opens in your browser). Colours are defined once at the
top of the file as CSS variables:

```css
--navy:   #1b2a44;   /* background / outcome boxes */
--slate:  #5a6b7d;   /* research-program branches */
--orange: #e8722a;   /* key output, recommendations */
--paper:  #ecebe6;   /* page background */
```

Change those values with any text editor to reskin every schema. (Browsers honour CSS
variables; some older image viewers do not, so a fixed fallback colour is written next to
each variable.)

---

## 4. Good to know

- **Resumable.** Papers that already have both their schema SVG and their tables record
  are skipped. If a batch is interrupted, just run the same command again. To redo a
  paper, delete its `_schema.svg` and `_logs/<tag>_tables.json` (and its CSVs).
  Use `resume=false` to redo everything.
- **Scanned PDFs (no text layer)** are logged and skipped. Nothing else stops; one bad
  paper never fails the batch.
- **Cost.** Two API calls per paper (structure, then tables); each sends the full paper
  text. The bill is dominated by the tables the model has to type out, not by the paper
  length. Measured on the samples with `claude-opus-5`: a 9-page journal paper with 11
  data tables ≈ $1.00; a 159-page 1975 report with 5 large tables ≈ $2.70; a paper with
  no data tables ≈ $0.20–0.60. Look at `_logs/usage_total.json` any time.
  `effort="medium"` trims the cost somewhat.
- **Validation.** Each CSV is parsed back before it is written (consistent column counts,
  non-empty header). If a table fails, the model is asked once to correct it; tables that
  still fail are left out and listed in the log and in `_logs/<tag>_tables.json`.
- **Refusal fallback.** If Anthropic's safety classifier declines a request, the API
  automatically re-runs it on Claude Opus 4.8 inside the same call. Turn off with
  `fallbacks=false`.

### Options

| keyword | default | meaning |
|---|---|---|
| `out` | `<input>_extracted` | where to write results |
| `resume` | `true` | skip papers that are already done |
| `model` | `"claude-opus-5"` | any Messages API model id |
| `effort` | `"high"` | `"medium"` / `"low"` are cheaper, `"xhigh"`/`"max"` more thorough |
| `fallbacks` | `true` | server-side refusal fallback |
| `max_tokens_structure` | `16000` | output budget for the schema pass |
| `max_tokens_tables` | `64000` | output budget for the tables pass; raise for papers with huge tables |
| `max_input_tokens` | `900000` | papers longer than this are skipped |
| `retry_tables` | `true` | ask once for a correction when a table fails validation |
| `api_timeout` | `1800` | seconds to wait for one API answer |
| `api_key` | from env / `.env` | override the key |

Example, cheaper run:

```julia
extract_papers("C:/path/to/pdfs"; effort="medium")
```

---

## 5. Tests

Offline tests (no API key, no cost) run with:

```powershell
cd "C:\Users\ELIKEM.ANYOMI\OneDrive\Desktop\RunToSolve\SteelDataInitiative\DataExtractor.jl"
julia --project=. -e "using Pkg; Pkg.test()"
```

Live tests process three sample PDFs from `..\test_pdfs` through the API (this costs a
few dollars) and write to `..\test_pdfs_live_test_output`:

```powershell
$env:DATAEXTRACTOR_LIVE = "1"
julia --project=. -e "using Pkg; Pkg.test()"
```

---

## 6. How it works (for the curious)

1. **Text** – Poppler's `pdftotext -layout` extracts the whole PDF with `=== PAGE n ===`
   markers so the model can quote page numbers. Column layout is preserved, which
   matters for tables.
2. **Pass 1 – structure** – the full text goes to Claude with a fixed JSON schema
   (background, research-program branches, key output, synopsis, recommendations,
   outcome). Julia draws that JSON as the SVG, so the style is always consistent.
3. **Pass 2 – tables** – the same text (read from cache) goes to Claude with a second
   schema asking for every measured-data table as verbatim rows. Julia writes and
   validates each CSV.
4. **Bookkeeping** – tokens and estimated cost are logged per call and totalled; the raw
   model answers are kept in `_logs/` so you can re-render or audit without paying again.

Source files: `src/pdftext.jl` (Poppler), `src/sources.jl` (which PDFs, code tags,
PDFTopicSorter index), `src/anthropic.jl` (API client), `src/structure.jl` + `src/svg.jl`
(schema), `src/tables.jl` (CSVs), `src/run.jl` (batch, resume, logs).
