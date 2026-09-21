# Pass 2: measured-data tables → validated CSV files.

const TABLES_SYSTEM = """
You are a meticulous data curator building a database of steel-research data.
You will be given the complete extracted text of one paper (with `=== PAGE n ===`
markers; tables were extracted with column layout preserved, so columns are aligned by
spaces).

Find every table of the paper's OWN numerical data — test specimens and their
dimensions, measured material properties, test results, recorded loads, deflections,
strains, capacities, field measurements, and the paper's own analysis results (finite
element or program output, design factors, regression fits, test-to-predicted ratios,
parametric-study inputs and outputs). Do NOT include: literature-review tables,
summaries of other papers' results, tables of code/specification coefficients, symbol or
nomenclature lists, or purely descriptive tables with no numbers. If the paper has no
such tables, return an empty `tables` list.

For each table you return:
- table_label: the table label exactly as printed ("5", "V", "3-2", "A.1").
- table_number: the same label as Arabic digits (roman numerals converted, e.g. "V" → "5";
  "3-2" stays "3-2").
- continued: true if the table runs across more than one printed table ("Table 5 cont'd")
  — merge all continuation parts into ONE table with all rows.
- pages: the page number(s) of the table in the PDF text, e.g. "34-37" (use the
  `=== PAGE n ===` markers).
- short_name: a PascalCase name for the filename, ≤ 32 characters, e.g. "ZSectionDimensions",
  "BoltTestResults", "MeasuredYieldStrength".
- data_basis: ONE short phrase saying how the numbers were obtained, so a reader knows
  whether they are measured or computed: e.g. "measured: load cell and dial gauges during
  four-point bend test", "measured: calipers on fabricated specimens", "measured: field
  fan-pressurization test per ASTM E779", "computed: BASP finite-element buckling
  analysis", "computed: least-squares fit to the FE results", "input: nominal section
  dimensions chosen for the parametric study", "mixed: measured failure loads with
  formula-predicted capacities for comparison".
- content: ONE sentence saying what was measured and under what condition.
- units: units per column (e.g. "all columns in inches" or "t_in inches; fy_ksi ksi; p_kip kips")
  or "see column headers" when every header carries its unit.
- anomaly_flag: null normally. If the printed table has a labelling error, duplicate
  specimen ID, inconsistent numbering, a value that contradicts its own row, or any other
  oddity, describe it here and state that the value is preserved verbatim as printed and
  NOT corrected.
- notes: extra lines needed to read the table — meaning of specimen-ID suffixes or
  abbreviations, footnote text, the figure that defines the dimensions, etc. Empty list
  if none.
- columns: column names in lowercase snake_case with the unit as a suffix, kept short:
  specimen_id, t_in, h_in, b1_in, b2_in, d1_in, r_in, n_in, l_in, fy_ksi, fu_ksi,
  p_test_kip, p_calc_kip, p_test_over_p_calc, m_test_kip_in, delta_max_in, e_ksi,
  span_ft, ... Use the paper's own symbol when it exists (e.g. B1 → b1_in, D1 → d1_in).
  Dimensionless columns get no unit suffix. Never use spaces, capitals or slashes.
- column_definitions: one plain-language definition per column, in the SAME ORDER as
  `columns` (same number of entries), each ≤ 90 characters, written as
  "name = what the quantity is, how the paper defines it, unit". Examples:
  "l_in = length of the bolt, inches", "specimen_id = test specimen label (see notes for
  suffixes)", "p_test_kip = maximum load reached during the test, kips",
  "b1_in = width of the top flange, inches (Fig. 11)". Scan the paper's text, figures,
  nomenclature list and table footnotes for the definition. If the paper never defines a
  symbol, say so: "x_in = not defined in the paper; appears to be ...".
- rows: every data row, in printed order, as a list of strings (one per column). Copy
  values EXACTLY as printed: same digits, same decimals, same labels, same duplicates,
  same typos. Do not compute, round, convert units, fix labels, or fill blanks — an
  empty cell is "" and a printed dash is "-". Keep footnote markers attached to the
  value if they are printed there (e.g. "12.3*"). Every row must have exactly as many
  entries as `columns`.

Two different kinds of "error" — treat them differently:
1. Errors in the PRINTED source (a duplicated specimen label, a mis-numbered row, a
   value inconsistent with its neighbours): keep them verbatim and describe them in
   anomaly_flag. Never correct them.
2. Text-extraction (OCR) artifacts that are clearly NOT in the printed source — a letter
   standing in for a digit inside a number ("lUI" for 11.11, "t46" for 146, "lOI.6" for
   101.6, "O.75" for 0.75): repair only when the intended digits are unambiguous from the
   pattern of the surrounding column, and list EVERY repaired cell in anomaly_flag as
   "OCR REPAIR: <raw> → <value> (row X, column Y)". If the intended value is not
   unambiguous, keep the raw extracted text and flag it instead.

- extraction_quality: an honest grade of the rows you return —
  "clean" when every value was copied as extracted with no change;
  "ocr_repaired" when only unambiguous single-character OCR repairs were made (all listed
  in anomaly_flag);
  "reconstructed" when you had to infer anything more than that — restore lost decimal
  points, infer column identities, or drop an unreadable column. Reconstructed tables
  need a human check against the PDF, so say exactly what was inferred in anomaly_flag.
  If a table is so garbled that even reconstruction would be guesswork, leave it out and
  mention it in the notes of the nearest table instead.

Also give first_author_last_name (letters only), author_citation as it should appear in a
reference ("Cain, D.E." or "Douty, R.T. and McGuire, W."), and the publication year.
"""

const TABLES_ASK = "Extract every table of the paper's own numerical data (measured, tested, or computed) in the required JSON format."

const TABLE_SCHEMA = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false,
    "required" => ["table_label", "table_number", "continued", "pages", "short_name", "data_basis", "content", "units",
                   "anomaly_flag", "notes", "extraction_quality", "columns", "column_definitions", "rows"],
    "properties" => Dict{String,Any}(
        "column_definitions" => str_array("One plain-language definition per column, same order and count as `columns`: \"name = meaning, unit\""),
        "data_basis" => str_schema("How the numbers were obtained: \"measured: ...\", \"computed: ...\", \"input: ...\" or \"mixed: ...\""),
        "extraction_quality" => Dict{String,Any}("type" => "string", "enum" => ["clean", "ocr_repaired", "reconstructed"],
            "description" => "clean = verbatim; ocr_repaired = unambiguous character fixes only; reconstructed = decimals/columns inferred, needs human check"),
        "table_label" => str_schema("Table label as printed, e.g. \"V\" or \"5\""),
        "table_number" => str_schema("Arabic form of the label, e.g. \"5\""),
        "continued" => Dict{String,Any}("type" => "boolean", "description" => "true if merged from a continued table"),
        "pages" => str_schema("PDF page number(s), e.g. \"34-37\""),
        "short_name" => str_schema("PascalCase name for the filename, ≤ 32 characters"),
        "content" => str_schema("One sentence: what was measured, under what condition"),
        "units" => str_schema("Units per column, or \"see column headers\""),
        "anomaly_flag" => nullable_str("Description of any printed oddity (preserved verbatim), else null"),
        "notes" => str_array("Extra interpretation notes (suffix meanings, footnotes); may be empty"),
        "columns" => str_array("snake_case column names with unit suffixes"),
        "rows" => Dict{String,Any}("type" => "array", "description" => "Data rows, verbatim",
            "items" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}("type" => "string")))))

const TABLES_SCHEMA = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false,
    "required" => ["first_author_last_name", "author_citation", "year", "tables"],
    "properties" => Dict{String,Any}(
        "first_author_last_name" => str_schema("First author's last name, letters only"),
        "author_citation" => str_schema("Authors as cited, e.g. \"Cain, D.E.\""),
        "year" => str_schema("Four-digit publication year"),
        "tables" => Dict{String,Any}("type" => "array", "items" => TABLE_SCHEMA,
                                     "description" => "All of the paper's own data tables (measured or computed); empty if none")))

# Note on caching: the JSON output schema is part of the cached prompt prefix, so the two
# passes (different schemas) cannot share the cached paper text. A single combined schema
# was tried and rejected by the API ("compiled grammar is too large"), so each pass sends
# the paper once. Output tokens dominate the cost anyway.

"""
    ask_tables(client, paper_text; model, effort, max_tokens, fallbacks) -> (Dict, resp, body)

Pass 2: measured-data tables as JSON following `TABLES_SCHEMA`. Returns the request
body too so a validation failure can be answered in the same conversation.
"""
function ask_tables(client::Client, paper_text::AbstractString; model=DEFAULT_MODEL,
                    effort="high", max_tokens::Int=64_000, fallbacks::Bool=true)
    body = build_body(TABLES_SYSTEM, paper_text, TABLES_ASK;
                      model, effort, max_tokens, schema=TABLES_SCHEMA, fallbacks)
    parsed, resp = ask_json(client, body; betas=betas_for(fallbacks))
    return parsed, resp, body
end

"""
    reprompt_tables(client, body, resp, problems; fallbacks) -> (Dict, resp)

Continue the same conversation: append the model's answer and a user message listing
the validation problems, and ask for the complete corrected JSON.
"""
function reprompt_tables(client::Client, body::AbstractDict, resp::AbstractDict,
                         problems::AbstractVector{<:AbstractString}; fallbacks::Bool=true)
    body2 = deepcopy(body)
    push!(body2["messages"], Dict{String,Any}("role" => "assistant", "content" => resp["content"]))
    msg = "Your JSON did not pass validation:\n- " * join(problems, "\n- ") *
          "\n\nReturn the COMPLETE corrected JSON (all tables, all rows). Every row must have exactly as many entries as `columns`. Keep values verbatim from the paper."
    push!(body2["messages"], Dict{String,Any}("role" => "user", "content" => msg))
    return ask_json(client, body2; betas=betas_for(fallbacks))
end

# ---- naming --------------------------------------------------------------------------

"""
    snake_case(name) -> String

`"B1 (in.)"` → `"b1_in"`, `"Fy, ksi"` → `"fy_ksi"`, `"P test / P n"` → `"p_test_p_n"`.
"""
function snake_case(name::AbstractString)
    s = lowercase(strip(name))
    s = replace(s, r"[′']" => "", r"[%]" => "pct", r"[°]" => "deg", r"[/]" => "_over_")
    s = replace(s, r"[^a-z0-9]+" => "_")
    s = replace(s, r"_+" => "_")
    s = strip(s, '_')
    isempty(s) && (s = "col")
    isdigit(first(s)) && (s = "c_" * s)
    return String(s)
end

letters_only(s) = replace(String(s), r"[^A-Za-z]" => "")
alnum_only(s) = replace(String(s), r"[^A-Za-z0-9]" => "")

function pascal_case(s::AbstractString)
    words = split(replace(s, r"[^A-Za-z0-9]+" => " "))
    isempty(words) && return "Table"
    return join(uppercasefirst.(String.(words)))
end

"""
    table_filename(code_tag, last_name, year, table_number, short_name) -> String

`MBMA_9408_Cain1995_Table5_ZSectionDimensions.csv`
"""
function table_filename(code_tag, last_name, year, table_number, short_name)
    ln = letters_only(last_name); isempty(ln) && (ln = "Unknown")
    yr = replace(String(year), r"[^0-9]" => ""); isempty(yr) && (yr = "0000")
    tn = replace(String(table_number), "-" => "_", "." => "_")
    tn = replace(tn, r"[^A-Za-z0-9_]" => ""); isempty(tn) && (tn = "0")
    sn = pascal_case(short_name); sn = first(alnum_only(sn), 40)
    return string(code_tag, "_", ln, yr, "_Table", tn, "_", sn, ".csv")
end

const QUALITY_TEXT = Dict(
    "clean" => "clean — values copied exactly as extracted from the PDF text",
    "ocr_repaired" => "ocr_repaired — only unambiguous single-character OCR fixes, each listed under ANOMALY FLAG",
    "reconstructed" => "reconstructed — decimal points / column identities were inferred from context; VERIFY against the PDF before use")
quality_line(q) = get(QUALITY_TEXT, String(q), String(q))
is_reconstructed(t::AbstractDict) = String(get(t, "extraction_quality", "clean")) == "reconstructed"

# ---- CSV writing -----------------------------------------------------------------------

function csv_field(s::AbstractString)
    needs = occursin(r"[,\"\r\n]", s) || startswith(s, " ") || endswith(s, " ")
    needs || return String(s)
    return "\"" * replace(s, "\"" => "\"\"") * "\""
end
csv_line(fields) = join((csv_field(String(f)) for f in fields), ",")

# Comment lines must stay on one line each.
oneline(s) = String(strip(replace(String(s), r"\s*[\r\n]+\s*" => " ")))

"""
    unique_columns(cols) -> Vector{String}

snake_case every header and make duplicates unique (`x_in`, `x_in_2`, ...).
"""
function unique_columns(cols)
    out = String[]
    seen = Dict{String,Int}()
    for c in cols
        s = snake_case(String(c))
        n = get(seen, s, 0) + 1
        seen[s] = n
        push!(out, n == 1 ? s : string(s, "_", n))
    end
    return out
end

"""
    render_csv(code_tag, author_citation, year, table::AbstractDict) -> String

The CSV text: header-comment block, snake_case header row, verbatim data rows.
"""
function render_csv(code_tag::AbstractString, author_citation::AbstractString, year::AbstractString, t::AbstractDict)
    label = oneline(get(t, "table_label", get(t, "table_number", "?")))
    number = oneline(get(t, "table_number", label))
    cont = get(t, "continued", false) === true ? ", cont'd" : ""
    pages = oneline(get(t, "pages", ""))
    short = uppercase(alnum_only(pascal_case(String(get(t, "short_name", "TABLE")))))
    cols = unique_columns(get(t, "columns", Any[]))

    io = IOBuffer()
    println(io, "# Source: ", code_tag, " | ", oneline(author_citation), " (", oneline(year), "), Table ", label, cont,
            isempty(pages) ? "" : ", pp." * pages)
    println(io, "# Tag: ", code_tag, "_TABLE", alnum_only(replace(number, "-" => "_")), "_", short)
    println(io, "# Content: ", oneline(get(t, "content", "")))
    println(io, "# Data basis: ", oneline(get(t, "data_basis", "")))
    println(io, "# Units: ", oneline(get(t, "units", "see column headers")))
    defs = get(t, "column_definitions", Any[])
    if length(defs) == length(cols) && !isempty(cols)
        println(io, "# Column definitions:")
        for (c, d) in zip(cols, defs)
            d = oneline(d)
            # make sure every line starts with the snake_case name actually used in the header
            m = match(r"^\s*[^=]+=\s*(.*)$", d)
            meaning = m === nothing ? d : String(m[1])
            println(io, "#   ", c, " = ", meaning)
        end
    end
    println(io, "# EXTRACTION QUALITY: ", quality_line(get(t, "extraction_quality", "clean")))
    flag = get(t, "anomaly_flag", nothing)
    if flag !== nothing && !isempty(strip(String(flag)))
        println(io, "# ANOMALY FLAG: ", oneline(flag))
    end
    for n in get(t, "notes", Any[])
        s = oneline(n)
        isempty(s) || println(io, "# ", s)
    end
    println(io, csv_line(cols))
    for r in get(t, "rows", Any[])
        println(io, csv_line(String.(r)))
    end
    return String(take!(io))
end

# ---- validation -------------------------------------------------------------------------

"""
    validate_table(t) -> Vector{String}

Problems with one table as returned by the model (empty vector = OK).
"""
function validate_table(t::AbstractDict)
    problems = String[]
    name = string("Table ", get(t, "table_label", "?"), " (", get(t, "short_name", ""), ")")
    cols = get(t, "columns", Any[])
    rows = get(t, "rows", Any[])
    isempty(cols) && push!(problems, "$name: no columns")
    isempty(rows) && push!(problems, "$name: no data rows")
    (isempty(cols) || isempty(rows)) && return problems
    nc = length(cols)
    bad = [i for (i, r) in enumerate(rows) if !(r isa AbstractVector) || length(r) != nc]
    if !isempty(bad)
        shown = join(string.(first(bad, 8)), ", ")
        length(bad) > 8 && (shown *= ", ...")
        push!(problems, string(name, ": ", length(bad), " row(s) do not have ", nc, " entries (rows ", shown, ")"))
    end
    isempty(strip(String(get(t, "short_name", "")))) && push!(problems, "$name: short_name is empty")
    isempty(strip(String(get(t, "table_number", "")))) && push!(problems, "$name: table_number is empty")
    isempty(strip(String(something(get(t, "data_basis", ""), "")))) &&
        push!(problems, "$name: data_basis is empty — say how the numbers were obtained (measured / computed / input / mixed)")
    defs = get(t, "column_definitions", Any[])
    length(defs) == nc ||
        push!(problems, "$name: column_definitions has $(length(defs)) entries but there are $nc columns — give exactly one definition per column, in order")
    return problems
end

"""
    validate_csv_text(csv) -> Vector{String}

Parse the finished CSV text back (skipping `#` comment lines) and check that every
row has the header's column count.
"""
function validate_csv_text(csv::AbstractString)
    problems = String[]
    header = nothing
    nrows = 0
    for (ln, line) in enumerate(eachline(IOBuffer(csv)))
        s = rstrip(line, ['\r', '\n'])
        isempty(strip(s)) && continue
        startswith(s, "#") && continue
        f = parse_csv_line(s)
        if header === nothing
            header = f
            any(isempty, header) && push!(problems, "line $ln: empty column name in header")
        else
            nrows += 1
            length(f) == length(header) || push!(problems, "line $ln: $(length(f)) fields, expected $(length(header))")
        end
    end
    header === nothing && push!(problems, "no header row")
    nrows == 0 && push!(problems, "no data rows")
    return problems
end

"""
    csv_outputs(code_tag, parsed) -> (files::Vector{Pair{String,String}}, problems::Vector{String})

Turn the model's tables JSON into `filename => csv_text` pairs, validating each table.
Tables with problems are left out and their problems returned.
"""
function csv_outputs(code_tag::AbstractString, parsed::AbstractDict)
    files = Pair{String,String}[]
    problems = String[]
    last = String(get(parsed, "first_author_last_name", "Unknown"))
    cite = String(get(parsed, "author_citation", last))
    year = String(get(parsed, "year", "0000"))
    used = Set{String}()
    for t in get(parsed, "tables", Any[])
        p = validate_table(t)
        if !isempty(p)
            append!(problems, p)
            continue
        end
        csv = render_csv(code_tag, cite, year, t)
        p2 = validate_csv_text(csv)
        if !isempty(p2)
            append!(problems, string("Table ", get(t, "table_label", "?"), ": ", x) for x in p2)
            continue
        end
        fname = table_filename(code_tag, last, year, get(t, "table_number", "0"), get(t, "short_name", "Table"))
        k = 1
        base = fname
        while fname in used
            k += 1
            fname = string(chopsuffix(base, ".csv"), "_", k, ".csv")
        end
        push!(used, fname)
        push!(files, fname => csv)
    end
    return files, problems
end
