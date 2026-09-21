# Full-document text extraction with Poppler's pdftotext / pdfinfo.

pdfinfo_cmd(path) = `$(Poppler_jll.pdfinfo()) -enc UTF-8 $path`
# -layout keeps table columns aligned, which matters a lot for reading data tables.
pdftotext_cmd(path) = `$(Poppler_jll.pdftotext()) -layout -enc UTF-8 -q $path -`

"""
    run_capture(cmd; timeout=120) -> String

Run `cmd`, return its stdout, kill it after `timeout` seconds. Throws on non-zero exit.
"""
function run_capture(cmd::Cmd; timeout::Real=120)
    killed = Ref(false)
    proc = open(pipeline(ignorestatus(cmd); stderr=devnull), "r")
    timer = Timer(timeout) do _
        if process_running(proc)
            killed[] = true
            kill(proc)
        end
    end
    local out::String
    try
        out = read(proc, String)
        wait(proc)
    finally
        close(timer)
    end
    if proc.exitcode != 0
        exe = basename(cmd.exec[1])
        killed[] && error("`$exe` timed out after $(timeout)s")
        error("`$exe` exited with code $(proc.exitcode)")
    end
    return out
end

function parse_pdfinfo(s::AbstractString)
    d = Dict{String,String}()
    for line in eachline(IOBuffer(s))
        m = match(r"^([A-Za-z][A-Za-z0-9 _\-]*):\s*(.*)$", line)
        m === nothing && continue
        d[String(m[1])] = String(strip(m[2]))
    end
    return d
end

"""
    PDFText(text, pages, has_text, meta)

Result of [`extract_text`](@ref). `text` has `=== PAGE n ===` markers between pages so
the model can cite page numbers. `has_text` is false for scanned PDFs without a text layer.
"""
struct PDFText
    text::String
    pages::Int
    has_text::Bool
    meta::Dict{String,String}
end

# A PDF "has text" when the text layer holds a reasonable amount of real content.
const MIN_TEXT_CHARS = 200

"""
    extract_text(path; timeout=120) -> PDFText

Extract the full text of a PDF with Poppler. Never throws for a bad PDF: failures are
logged and reported as `has_text=false`.
"""
function extract_text(path::AbstractString; timeout::Real=120)
    meta = Dict{String,String}()
    try
        meta = parse_pdfinfo(run_capture(pdfinfo_cmd(path); timeout))
    catch e
        @warn "pdfinfo failed" file = basename(path) error = sprint(showerror, e)
    end
    raw = ""
    try
        raw = run_capture(pdftotext_cmd(path); timeout)
    catch e
        @warn "pdftotext failed" file = basename(path) error = sprint(showerror, e)
    end
    pages = split(raw, '\f'; keepempty=true)
    # pdftotext ends each page with a form feed, so the last piece is normally empty
    !isempty(pages) && isempty(strip(pages[end])) && pop!(pages)
    io = IOBuffer()
    for (i, p) in enumerate(pages)
        print(io, "\n=== PAGE ", i, " ===\n")
        print(io, rstrip(p), "\n")
    end
    text = String(take!(io))
    # judge the text layer on the raw Poppler output, not on our page markers
    n_alnum = count(c -> isletter(c) || isdigit(c), raw)
    has_text = n_alnum >= MIN_TEXT_CHARS
    npages = something(tryparse(Int, get(meta, "Pages", "")), length(pages))
    return PDFText(text, npages, has_text, meta)
end
