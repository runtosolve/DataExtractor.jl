# Batch driver: resume logic, per-paper processing, logging and token accounting.

"""
    PaperResult

What happened to one PDF. `status` is one of `:done`, `:partial` (one pass failed),
`:skipped_existing`, `:no_text`, `:too_large`, `:failed`.
"""
struct PaperResult
    paper::Paper
    status::Symbol
    svg_path::Union{Nothing,String}
    csv_paths::Vector{String}
    notes::Vector{String}
    usage::Vector{NamedTuple}
end

Base.show(io::IO, r::PaperResult) = print(io, "PaperResult(", r.paper.code_tag, ", ", r.status,
    ", svg=", r.svg_path === nothing ? "no" : "yes", ", csvs=", length(r.csv_paths), ")")

"""
    BatchResult

Everything produced by [`extract_papers`](@ref): the output folder, one
[`PaperResult`](@ref) per PDF, and token/cost totals for this run.
"""
struct BatchResult
    out::String
    results::Vector{PaperResult}
    run_usage::NamedTuple
    total_usage::NamedTuple
end

function Base.show(io::IO, b::BatchResult)
    n(s) = count(r -> r.status == s, b.results)
    print(io, "BatchResult(", length(b.results), " papers: ", n(:done), " done, ", n(:partial), " partial, ",
          n(:skipped_existing), " already done, ", n(:no_text), " no text, ", n(:failed) + n(:too_large), " failed; ",
          sum(length(r.csv_paths) for r in b.results; init=0), " CSVs; this run ≈ \$",
          round(b.run_usage.cost_usd; digits=2), ", all runs ≈ \$", round(b.total_usage.cost_usd; digits=2), ")")
end

# ---- logging ---------------------------------------------------------------------------------

struct RunLog
    path::String
end

function log!(rl::RunLog, level::AbstractString, msg::AbstractString)
    line = string(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), " [", level, "] ", msg)
    println(line)
    open(rl.path, "a") do io
        println(io, line)
    end
    return nothing
end
info!(rl, msg) = log!(rl, "INFO", msg)
warn!(rl, msg) = log!(rl, "WARN", msg)
err!(rl, msg) = log!(rl, "ERROR", msg)

logs_dir(out) = joinpath(out, "_logs")

# ---- token accounting ---------------------------------------------------------------------------

const ZERO_USAGE = (input_tokens=0, output_tokens=0, cache_read_input_tokens=0, cache_creation_input_tokens=0, cost_usd=0.0)

function add_usage(a::NamedTuple, u::NamedTuple)
    return (input_tokens=a.input_tokens + u.input_tokens, output_tokens=a.output_tokens + u.output_tokens,
            cache_read_input_tokens=a.cache_read_input_tokens + u.cache_read_input_tokens,
            cache_creation_input_tokens=a.cache_creation_input_tokens + u.cache_creation_input_tokens,
            cost_usd=a.cost_usd + estimate_cost(u))
end

function record_usage!(out::AbstractString, code_tag::AbstractString, pass::AbstractString, u::NamedTuple)
    d = logs_dir(out)
    mkpath(d)
    entry = Dict("time" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"), "code_tag" => code_tag, "pass" => pass,
                 "model" => u.model, "input_tokens" => u.input_tokens, "output_tokens" => u.output_tokens,
                 "cache_read_input_tokens" => u.cache_read_input_tokens,
                 "cache_creation_input_tokens" => u.cache_creation_input_tokens,
                 "cost_usd_estimate" => round(estimate_cost(u); digits=4))
    open(joinpath(d, "usage.jsonl"), "a") do io
        println(io, JSON.json(entry))
    end
    tot = read_total_usage(out)
    tot = add_usage(tot, u)
    write_total_usage(out, tot)
    return tot
end

function read_total_usage(out::AbstractString)
    f = joinpath(logs_dir(out), "usage_total.json")
    isfile(f) || return ZERO_USAGE
    try
        j = JSON.parse(read(f, String))
        return (input_tokens=Int(get(j, "input_tokens", 0)), output_tokens=Int(get(j, "output_tokens", 0)),
                cache_read_input_tokens=Int(get(j, "cache_read_input_tokens", 0)),
                cache_creation_input_tokens=Int(get(j, "cache_creation_input_tokens", 0)),
                cost_usd=Float64(get(j, "cost_usd_estimate", 0.0)))
    catch
        return ZERO_USAGE
    end
end

function write_total_usage(out::AbstractString, tot::NamedTuple)
    mkpath(logs_dir(out))
    d = Dict("input_tokens" => tot.input_tokens, "output_tokens" => tot.output_tokens,
             "cache_read_input_tokens" => tot.cache_read_input_tokens,
             "cache_creation_input_tokens" => tot.cache_creation_input_tokens,
             "cost_usd_estimate" => round(tot.cost_usd; digits=4),
             "updated" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"))
    open(joinpath(logs_dir(out), "usage_total.json"), "w") do io
        JSON.print(io, d, 2)
    end
end

# ---- per-paper processing ----------------------------------------------------------------------------

svg_path_for(out, tag) = joinpath(out, tag * "_schema.svg")
tables_json_for(out, tag) = joinpath(logs_dir(out), tag * "_tables.json")
structure_json_for(out, tag) = joinpath(logs_dir(out), tag * "_structure.json")

"""
    already_done(out, code_tag) -> Bool

Both artifacts exist: the schema SVG and the tables record (which may list zero CSVs).
"""
already_done(out, tag) = isfile(svg_path_for(out, tag)) && isfile(tables_json_for(out, tag))

function paper_context(p::Paper)
    parts = String[]
    isempty(p.pcode) || push!(parts, "PDFTopicSorter code: " * p.pcode)
    isempty(p.title) || push!(parts, "Title: " * p.title)
    isempty(p.theme) || push!(parts, "Theme: " * p.theme)
    isempty(p.topic) || push!(parts, "Topic: " * p.topic)
    isempty(p.subtopic) || push!(parts, "Subtopic: " * p.subtopic)
    push!(parts, "Filename: " * p.name)
    return "<metadata>\n" * join(parts, "\n") * "\n</metadata>\n"
end

function process_paper(p::Paper, out::AbstractString, client::Client, rl::RunLog;
                       model=DEFAULT_MODEL, effort="high", fallbacks::Bool=true, resume::Bool=true,
                       max_tokens_structure::Int=16_000, max_tokens_tables::Int=64_000,
                       max_input_tokens::Int=900_000, timeout::Real=120, retry_tables::Bool=true)
    tag = p.code_tag
    notes = String[]
    usage = NamedTuple[]
    svg_path = svg_path_for(out, tag)
    tjson = tables_json_for(out, tag)

    if resume && already_done(out, tag)
        info!(rl, "$tag: already extracted, skipping")
        csvs = existing_csvs(tjson)
        return PaperResult(p, :skipped_existing, svg_path, csvs, notes, usage)
    end

    info!(rl, "$tag: reading text from $(p.name)")
    pt = extract_text(p.path; timeout)
    if !pt.has_text
        warn!(rl, "$tag: no text layer (scanned PDF?) — skipping both passes")
        return PaperResult(p, :no_text, nothing, String[], ["no text layer"], usage)
    end
    ntok = estimate_tokens(pt.text)
    info!(rl, "$tag: $(pt.pages) pages, ≈$(ntok) tokens")
    if ntok > max_input_tokens
        warn!(rl, "$tag: too large for one request (≈$ntok tokens > $max_input_tokens) — skipping")
        return PaperResult(p, :too_large, nothing, String[], ["too large: ≈$ntok tokens"], usage)
    end
    paper_text = paper_context(p) * pt.text

    ok_svg = false
    # ---- pass 1: structure → SVG
    if isfile(svg_path)
        info!(rl, "$tag: schema SVG exists, skipping pass 1")
        ok_svg = true
    else
        try
            info!(rl, "$tag: pass 1 — paper structure")
            structure, resp = ask_structure(client, paper_text; model, effort, max_tokens=max_tokens_structure, fallbacks)
            u = usage_tuple(resp); push!(usage, u); record_usage!(out, tag, "structure", u)
            mkpath(logs_dir(out))
            open(structure_json_for(out, tag), "w") do io
                JSON.print(io, structure, 2)
            end
            svg = render_schema_svg(structure; code_tag=tag)
            write(svg_path, svg)
            info!(rl, "$tag: wrote $(basename(svg_path))  ($(u.input_tokens) in + $(u.cache_creation_input_tokens) cached-write + $(u.cache_read_input_tokens) cached-read / $(u.output_tokens) out tokens)")
            ok_svg = true
        catch e
            e isa InterruptException && rethrow()
            msg = sprint(showerror, e)
            err!(rl, "$tag: pass 1 failed — $msg")
            push!(notes, "pass 1 failed: " * first(msg, 300))
        end
    end

    # ---- pass 2: tables → CSVs
    ok_tables = false
    csv_paths = String[]
    if isfile(tjson)
        info!(rl, "$tag: tables record exists, skipping pass 2")
        csv_paths = existing_csvs(tjson)
        ok_tables = true
    else
        try
            info!(rl, "$tag: pass 2 — data tables")
            parsed, resp, body = ask_tables(client, paper_text; model, effort, max_tokens=max_tokens_tables, fallbacks)
            u = usage_tuple(resp); push!(usage, u); record_usage!(out, tag, "tables", u)
            files, problems = csv_outputs(tag, parsed)
            if !isempty(problems) && retry_tables
                warn!(rl, "$tag: $(length(problems)) table problem(s); asking the model to correct once")
                for pr in problems
                    warn!(rl, "$tag:   " * pr)
                end
                try
                    parsed2, resp2 = reprompt_tables(client, body, resp, problems; fallbacks)
                    u2 = usage_tuple(resp2); push!(usage, u2); record_usage!(out, tag, "tables_retry", u2)
                    files2, problems2 = csv_outputs(tag, parsed2)
                    if length(files2) >= length(files)
                        parsed, files, problems = parsed2, files2, problems2
                    end
                catch e
                    e isa InterruptException && rethrow()
                    warn!(rl, "$tag: retry failed — $(sprint(showerror, e)); keeping the valid tables from the first answer")
                end
            end
            for pr in problems
                warn!(rl, "$tag: table left out — " * pr)
                push!(notes, "table left out: " * pr)
            end
            for (fname, csv) in files
                path = joinpath(out, fname)
                write(path, csv)
                push!(csv_paths, path)
                info!(rl, "$tag: wrote $fname")
            end
            recon = [String(get(t, "short_name", "?")) for t in get(parsed, "tables", Any[]) if is_reconstructed(t)]
            if !isempty(recon)
                warn!(rl, "$tag: $(length(recon)) table(s) marked RECONSTRUCTED (OCR damage; decimals/columns inferred) — verify against the PDF: " * join(recon, ", "))
                push!(notes, "reconstructed tables: " * join(recon, ", "))
            end
            ntab = length(get(parsed, "tables", Any[]))
            ntab == 0 && info!(rl, "$tag: no data tables found in this paper")
            mkpath(logs_dir(out))
            open(tjson, "w") do io
                JSON.print(io, Dict("code_tag" => tag, "file" => p.name, "written" => basename.(csv_paths),
                                    "problems" => problems, "model_output" => parsed), 2)
            end
            info!(rl, "$tag: $(length(csv_paths)) CSV file(s)  ($(u.input_tokens) in + $(u.cache_creation_input_tokens) cached-write + $(u.cache_read_input_tokens) cached-read / $(u.output_tokens) out tokens)")
            ok_tables = true
        catch e
            e isa InterruptException && rethrow()
            msg = sprint(showerror, e)
            err!(rl, "$tag: pass 2 failed — $msg")
            push!(notes, "pass 2 failed: " * first(msg, 300))
        end
    end

    status = ok_svg && ok_tables ? :done : (ok_svg || ok_tables ? :partial : :failed)
    return PaperResult(p, status, ok_svg ? svg_path : nothing, csv_paths, notes, usage)
end

function existing_csvs(tjson::AbstractString)
    isfile(tjson) || return String[]
    try
        j = JSON.parse(read(tjson, String))
        out = dirname(dirname(tjson))
        return [joinpath(out, String(f)) for f in get(j, "written", Any[])]
    catch
        return String[]
    end
end

# ---- index of everything extracted -------------------------------------------------------------------

function update_index!(out::AbstractString, results::Vector{PaperResult})
    f = joinpath(out, "extraction_index.csv")
    rows = Dict{String,Vector{String}}()
    header = ["code_tag", "pcode", "file", "title", "theme", "topic", "subtopic", "status", "schema_svg", "n_csv", "notes", "csv_files"]
    if isfile(f)
        h, rs = read_csv(f)
        if h == header
            for r in rs
                rows[r[1]] = r
            end
        end
    end
    for r in results
        r.status == :skipped_existing && haskey(rows, r.paper.code_tag) && continue
        p = r.paper
        rows[p.code_tag] = [p.code_tag, p.pcode, p.name, p.title, p.theme, p.topic, p.subtopic, String(r.status),
                            r.svg_path === nothing ? "" : basename(r.svg_path), string(length(r.csv_paths)),
                            join(r.notes, " | "), join(basename.(r.csv_paths), "; ")]
    end
    open(f, "w") do io
        println(io, csv_line(header))
        for k in sort!(collect(keys(rows)))
            println(io, csv_line(rows[k]))
        end
    end
    return f
end

# ---- public interface ---------------------------------------------------------------------------------

default_out(input::AbstractString) = begin
    p = abspath(rstrip(input, ['/', '\\']))
    isdir(p) ? p * "_extracted" : joinpath(dirname(p), "extracted")
end

"""
    extract_papers(input; out=nothing, resume=true, model="claude-opus-5", effort="high",
                   fallbacks=true, api_key=nothing, client=nothing, recursive=true, kwargs...) -> BatchResult

Process every PDF in `input`, which may be PDFTopicSorter's output folder (has
`index.csv`), a plain folder of PDFs, or one PDF. Writes into `out` (default:
`<input>_extracted` next to the input):

- `{code_tag}_schema.svg` — the report-schema flowchart;
- `{code_tag}_{Author}{Year}_Table{N}_{Name}.csv` — one per measured-data table;
- `extraction_index.csv` — one row per paper with status and files;
- `_logs/` — raw model answers, `usage.jsonl`, `usage_total.json`, run logs.

With `resume=true` (default) papers that already have both artifacts are skipped, so a
stopped batch can simply be started again. A PDF without a text layer is logged and
skipped; one failing paper never stops the batch.

Other keywords: `max_tokens_structure` (16000), `max_tokens_tables` (64000),
`max_input_tokens` (900000, larger papers are skipped), `timeout` (Poppler seconds),
`retry_tables` (re-prompt once on invalid CSV, default true).
"""
function extract_papers(input::AbstractString; out::Union{Nothing,AbstractString}=nothing, resume::Bool=true,
                        api_key=nothing, client::Union{Nothing,Client}=nothing, recursive::Bool=true,
                        api_timeout::Integer=1800, kwargs...)
    out = out === nothing ? default_out(input) : abspath(out)
    mkpath(out); mkpath(logs_dir(out))
    rl = RunLog(joinpath(logs_dir(out), "run_" * Dates.format(now(), "yyyy-mm-dd") * ".log"))
    papers = collect_papers(input; recursive)
    isempty(papers) && throw(ArgumentError("no PDFs found in $input"))
    c = client === nothing ? Client(; api_key, timeout=api_timeout) : client
    info!(rl, "==== DataExtractor run: $(length(papers)) PDF(s) from $input → $out")

    results = PaperResult[]
    run_usage = ZERO_USAGE
    for (i, p) in enumerate(papers)
        info!(rl, "---- [$i/$(length(papers))] $(p.code_tag)")
        r = try
            process_paper(p, out, c, rl; resume, kwargs...)
        catch e
            e isa InterruptException && rethrow()
            msg = sprint(showerror, e)
            err!(rl, "$(p.code_tag): unexpected failure — $msg")
            PaperResult(p, :failed, nothing, String[], ["unexpected failure: " * first(msg, 300)], NamedTuple[])
        end
        push!(results, r)
        for u in r.usage
            run_usage = add_usage(run_usage, u)
        end
    end
    update_index!(out, results)
    total = read_total_usage(out)
    b = BatchResult(out, results, run_usage, total)
    info!(rl, "==== finished: " * sprint(show, b))
    info!(rl, "This run: $(run_usage.input_tokens) input + $(run_usage.cache_read_input_tokens) cached + $(run_usage.output_tokens) output tokens ≈ \$$(round(run_usage.cost_usd; digits=2)); all runs ≈ \$$(round(total.cost_usd; digits=2))")
    return b
end

"""
    extract_paper(pdf_path; out=nothing, kwargs...) -> PaperResult

Process a single PDF. `out` defaults to a folder named `extracted` next to the PDF.
Keywords are the same as [`extract_papers`](@ref).
"""
function extract_paper(pdf_path::AbstractString; out::Union{Nothing,AbstractString}=nothing, kwargs...)
    isfile(pdf_path) || throw(ArgumentError("no such file: $pdf_path"))
    b = extract_papers(pdf_path; out, kwargs...)
    return only(b.results)
end
