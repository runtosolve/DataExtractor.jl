# Which PDFs to process, and what we already know about each one.

"""
    Paper

One input PDF plus its identifiers. `code_tag` (e.g. `MBMA_9408`) is derived from the
filename prefix and used in every output filename. `pcode`, `title`, `theme`, `topic`
and `subtopic` come from PDFTopicSorter's `index.csv` when available (else empty).
"""
struct Paper
    path::String
    name::String
    code_tag::String
    pcode::String
    title::String
    theme::String
    topic::String
    subtopic::String
end

Paper(path, code_tag) = Paper(String(path), basename(path), String(code_tag), "", "", "", "", "")

Base.show(io::IO, p::Paper) = print(io, "Paper(", p.code_tag, ", \"", p.name, "\")")

ispdf(path::AbstractString) = occursin(r"\.pdf$"i, path)

# ---- code tags -----------------------------------------------------------------------

"""
    code_tag_from_filename(name) -> String

Derive the report code from a filename such as
`100__MBMA_7505 - Effects of ... -100-.pdf` → `MBMA_7505` or
`254_MBMA_9912_...` → `MBMA_9912`. Falls back to any `LETTERS_DIGITS` token in the
name, then to a sanitized filename stem.
"""
function code_tag_from_filename(name::AbstractString)
    stem = splitext(basename(name))[1]
    # leading index number, separators, then ORG_NNNN
    m = match(r"^\s*\d+\s*[_\-\s]+\s*([A-Za-z]{2,}[_\-]?\d{2,}[A-Za-z]?)", stem)
    m === nothing && (m = match(r"\b([A-Z]{2,}[_\-]\d{3,}[A-Za-z]?)\b", stem))
    if m !== nothing
        tag = uppercase(replace(String(m[1]), "-" => "_"))
        # normalise "MBMA9408" → "MBMA_9408"
        tag = replace(tag, r"^([A-Z]+)(\d)" => s"\1_\2")
        return tag
    end
    s = replace(stem, r"[^A-Za-z0-9]+" => "_")
    s = strip(s, '_')
    return String(first(isempty(s) ? "PAPER" : s, 40))
end

# ---- tiny CSV reader (for PDFTopicSorter's index.csv) --------------------------------

"""
    parse_csv_line(line) -> Vector{String}

Split one RFC-4180 style CSV line (double quotes, doubled quotes inside quotes).
"""
function parse_csv_line(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    inq = false
    chars = collect(line)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if inq
            if c == '"'
                if i < length(chars) && chars[i+1] == '"'
                    write(buf, '"'); i += 1
                else
                    inq = false
                end
            else
                write(buf, c)
            end
        else
            if c == '"'
                inq = true
            elseif c == ','
                push!(fields, String(take!(buf)))
            else
                write(buf, c)
            end
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end

"""
    read_csv(path) -> (header::Vector{String}, rows::Vector{Vector{String}})

Read a small CSV file, skipping `#` comment lines and blank lines.
"""
function read_csv(path::AbstractString)
    header = String[]
    rows = Vector{String}[]
    for line in eachline(path)
        s = rstrip(line, ['\r', '\n'])
        isempty(strip(s)) && continue
        startswith(strip(s), "#") && continue
        f = parse_csv_line(s)
        if isempty(header)
            header = f
        else
            push!(rows, f)
        end
    end
    return header, rows
end

# ---- finding PDFs ----------------------------------------------------------------------

function find_pdfs(dir::AbstractString; recursive::Bool=true)
    out = String[]
    if recursive
        for (root, _, files) in walkdir(dir)
            for f in files
                ispdf(f) && push!(out, joinpath(root, f))
            end
        end
    else
        for f in readdir(dir; join=true)
            isfile(f) && ispdf(f) && push!(out, f)
        end
    end
    return sort!(out)
end

# PDFTopicSorter's index.csv records absolute paths that may have moved since sorting.
# If a path is gone, look for a file with the same name near the sorted folder.
function locate_pdf(path::AbstractString, sorted_dir::AbstractString)
    isfile(path) && return String(path)
    name = basename(path)
    for base in unique([sorted_dir, dirname(sorted_dir)])
        for (root, _, files) in walkdir(base)
            name in files && return joinpath(root, name)
        end
    end
    return nothing
end

"""
    collect_papers(input; recursive=true) -> Vector{Paper}

`input` may be:
- PDFTopicSorter's output folder (contains `index.csv`): reuse its codes, titles and
  theme/topic labels; PDF paths come from the index (re-located by name if moved);
- a plain folder of PDFs (searched recursively);
- a single PDF path.
"""
function collect_papers(input::AbstractString; recursive::Bool=true)
    papers = Paper[]
    if isdir(input) && isfile(joinpath(input, "index.csv"))
        header, rows = read_csv(joinpath(input, "index.csv"))
        col = Dict(h => i for (i, h) in enumerate(header))
        get_col(r, k) = haskey(col, k) && col[k] <= length(r) ? r[col[k]] : ""
        for r in rows
            p = locate_pdf(get_col(r, "path"), input)
            if p === nothing
                @warn "PDF listed in index.csv not found; skipping" path = get_col(r, "path")
                continue
            end
            push!(papers, Paper(p, basename(p), code_tag_from_filename(p), get_col(r, "code"),
                                get_col(r, "title"), get_col(r, "theme"), get_col(r, "topic"), get_col(r, "subtopic")))
        end
        sort!(papers; by=p -> p.pcode)
    elseif isdir(input)
        for p in find_pdfs(input; recursive)
            push!(papers, Paper(p, code_tag_from_filename(p)))
        end
    elseif isfile(input)
        ispdf(input) || throw(ArgumentError("not a PDF: $input"))
        push!(papers, Paper(abspath(input), code_tag_from_filename(input)))
    else
        throw(ArgumentError("no such file or directory: $input"))
    end
    disambiguate_tags!(papers)
    return papers
end

# Two different files that map to the same code tag would overwrite each other's outputs.
function disambiguate_tags!(papers::Vector{Paper})
    seen = Dict{String,Int}()
    for (i, p) in enumerate(papers)
        n = get(seen, p.code_tag, 0) + 1
        seen[p.code_tag] = n
        if n > 1
            tag = string(p.code_tag, "_", n)
            @warn "Duplicate code tag; renaming" file = p.name tag
            papers[i] = Paper(p.path, p.name, tag, p.pcode, p.title, p.theme, p.topic, p.subtopic)
        end
    end
    return papers
end
