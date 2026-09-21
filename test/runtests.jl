using Test
using JSON
using DataExtractor
const DE = DataExtractor

const CANNED = joinpath(@__DIR__, "canned")
# The SteelDataInitiative sample PDFs live one folder above the package.
const SAMPLE_PDFS = normpath(joinpath(@__DIR__, "..", "..", "test_pdfs"))
const SAMPLE_SORTED = normpath(joinpath(@__DIR__, "..", "..", "test_pdfs_sorted"))

sample(pattern) = begin
    isdir(SAMPLE_PDFS) || return nothing
    hits = filter(f -> occursin(pattern, f), readdir(SAMPLE_PDFS; join=true))
    isempty(hits) ? nothing : first(hits)
end

@testset "DataExtractor" begin

@testset "code tags from filenames" begin
    @test code_tag_from_filename("100__MBMA_7505 - Effects of Reduction in Bolt Size.pdf") == "MBMA_7505"
    @test code_tag_from_filename("19__MBMA_0403 - Effects of Variable Pretension -19- (1).pdf") == "MBMA_0403"
    @test code_tag_from_filename("254_MBMA_9912_Some_Report.pdf") == "MBMA_9912"
    @test code_tag_from_filename("349__MBMA_9808 - Lateral-Torsional Stability [349].pdf") == "MBMA_9808"
    @test code_tag_from_filename("C:/x/y/565__MBMA_2207 - Certified Test Report [565].pdf") == "MBMA_2207"
    @test code_tag_from_filename("Report AISI_1234 web crippling.pdf") == "AISI_1234"   # falls back to a LETTERS_DIGITS token
    @test code_tag_from_filename("some random paper.pdf") == "some_random_paper"
end

@testset "snake_case column names" begin
    @test DE.snake_case("B1 (in.)") == "b1_in"
    @test DE.snake_case("Fy, ksi") == "fy_ksi"
    @test DE.snake_case("t_in") == "t_in"
    @test DE.snake_case("P test / P n") == "p_test_over_p_n"
    @test DE.snake_case("Specimen ID") == "specimen_id"
    @test DE.snake_case("2nd Peak (kip)") == "c_2nd_peak_kip"
    @test DE.unique_columns(["h in", "h_in", "H_IN"]) == ["h_in", "h_in_2", "h_in_3"]
end

@testset "CSV line parser" begin
    @test DE.parse_csv_line("a,b,c") == ["a", "b", "c"]
    @test DE.parse_csv_line("a,\"b, with comma\",c") == ["a", "b, with comma", "c"]
    @test DE.parse_csv_line("a,\"he said \"\"hi\"\"\",") == ["a", "he said \"hi\"", ""]
    @test DE.csv_line(["x", "y, z", "q\"r"]) == "x,\"y, z\",\"q\"\"r\""
end

@testset "table filenames" begin
    @test DE.table_filename("MBMA_9408", "Cain", "1995", "5", "ZSectionDimensions") ==
          "MBMA_9408_Cain1995_Table5_ZSectionDimensions.csv"
    @test DE.table_filename("MBMA_7505", "O'Neil", "1975", "3-2", "bolt test results") ==
          "MBMA_7505_ONeil1975_Table3_2_BoltTestResults.csv"
end

@testset "CSV rendering and validation (canned MBMA_9408)" begin
    parsed = JSON.parsefile(joinpath(CANNED, "tables_mbma9408.json"))
    files, problems = DE.csv_outputs("MBMA_9408", parsed)
    # table V is valid, table 6 has a short row and must be left out and reported
    @test length(files) == 1
    @test length(problems) == 1
    @test occursin("Table 6", problems[1])
    fname, csv = files[1]
    @test fname == "MBMA_9408_Cain1995_Table5_ZSectionDimensions.csv"
    lines = split(csv, '\n'; keepempty=false)
    @test lines[1] == "# Source: MBMA_9408 | Cain, D.E. (1995), Table V, cont'd, pp.34-37"
    @test lines[2] == "# Tag: MBMA_9408_TABLE5_ZSECTIONDIMENSIONS"
    @test startswith(lines[3], "# Content: Measured cross-sectional dimensions")
    @test lines[4] == "# Data basis: measured: calipers and micrometer on fabricated Z-section specimens before web crippling tests"
    @test lines[5] == "# Units: all columns in inches"
    @test lines[6] == "# Column definitions:"
    # one definition line per column, keyed by the snake_case name actually used in the header
    @test lines[7] == "#   specimen_id = test specimen label; -F suffix means flanges fastened to the support"
    @test lines[9] == "#   b1_in = width of the top (loaded) flange, inches (Fig. 11)"
    @test lines[16] == "#   l_in = span length between supports, inches"
    @test startswith(lines[17], "# EXTRACTION QUALITY: clean")
    @test startswith(lines[18], "# ANOMALY FLAG: source table lists the fourth Z2 specimen")
    @test startswith(lines[19], "# n_tension flanges:")
    # header normalised to snake_case, values verbatim (duplicate label kept)
    hdr = findfirst(l -> !startswith(l, "#"), lines)
    @test hdr == 20
    @test lines[hdr] == "specimen_id,t_in,b1_in,b2_in,d1_in,d2_in,d3_in,r_in,n_in,l_in"
    @test lines[end-1] == "Z2.3-F,0.083,1.656,1.719,6.469,0.406,0.438,0.250,2.625,30.000"
    @test lines[end] == "Z2.3-F,0.083,1.688,1.719,6.469,0.469,0.469,0.250,2.625,30.000"
    @test isempty(DE.validate_csv_text(csv))
    # the re-read CSV parses to the right shape
    mktempdir() do d
        path = joinpath(d, fname); write(path, csv)
        header, rows = DE.read_csv(path)
        @test length(header) == 10
        @test length(rows) == 4
        @test all(r -> length(r) == 10, rows)
    end
    # compare with the hand-made reference file shipped with the project, if present
    ref = normpath(joinpath(@__DIR__, "..", "..", "MBMA_9408_Cain1995_Table5_ZSectionDimensions.csv"))
    if isfile(ref)
        rh, rrows = DE.read_csv(ref)
        @test lowercase.(rh) == split(lines[hdr], ",")
    end
end

@testset "validators" begin
    base = Dict("table_label" => "1", "table_number" => "1", "short_name" => "X", "data_basis" => "measured: load cell",
                "columns" => ["a", "b"], "column_definitions" => ["a = first, in", "b = second, kip"], "rows" => [["1", "2"]])
    @test isempty(DE.validate_table(base))
    bad = merge(base, Dict("rows" => [["1"]]))
    @test !isempty(DE.validate_table(bad))
    # every table must say how its numbers were obtained
    nobasis = merge(base, Dict("data_basis" => ""))
    @test any(p -> occursin("data_basis", p), DE.validate_table(nobasis))
    # definitions must match the columns one-to-one
    nodefs = merge(base, Dict("column_definitions" => ["a = first, in"]))
    @test any(p -> occursin("column_definitions", p), DE.validate_table(nodefs))
    @test !isempty(DE.validate_table(Dict("columns" => [], "rows" => [])))
    @test !isempty(DE.validate_csv_text("# c\na,b\n1,2,3\n"))
    @test isempty(DE.validate_csv_text("# c\na,b\n1,2\n\"x, y\",3\n"))
end

@testset "SVG rendering (canned lubricant structure)" begin
    s = JSON.parsefile(joinpath(CANNED, "structure_lubricant.json"))
    svg = render_schema_svg(s; code_tag="STEELCO_2002")
    @test startswith(svg, "<?xml")
    @test occursin("<svg", svg) && endswith(strip(svg), "</svg>")
    @test occursin("--navy:", svg) && occursin("--orange:", svg) && occursin("--slate:", svg)
    @test occursin("var(--navy)", svg)
    @test occursin("RESEARCH PROGRAM", svg)
    @test occursin("KEY OUTPUT: FIVE LUBRICANT FAMILIES", svg)
    @test occursin("Bare coils need Grp C", svg)
    @test occursin("SPECIFIC RECOMMENDATIONS", svg)
    @test occursin("SHEET 1 OF 1", svg)
    @test occursin("&amp;", svg)                       # "G90 HDG & AZ55" is escaped
    @test count("<rect", svg) > 10
    # every opened tag is closed: crude well-formedness check on the tags we emit
    for tag in ("text", "tspan", "svg", "style", "defs", "marker")
        @test count("<$tag", svg) == count("</$tag>", svg)
    end
    # a minimal paper (no branches, no recommendations, null synopsis/outcome) still renders
    mini = Dict("title" => "T", "subtitle" => "S", "organization" => nothing, "citation" => "C",
                "background" => Dict("heading" => "BACKGROUND", "body" => "why"),
                "research_program" => Dict("heading" => "METHOD", "branches" => Any[]),
                "key_output" => Dict("heading" => "RESULT", "items" => [Dict("label" => "L", "text" => "t")]),
                "synopsis" => nothing, "recommendations" => Any[], "outcome" => nothing)
    svg2 = render_schema_svg(mini)
    @test occursin("RESULT", svg2) && !occursin("RECOMMEND", svg2)
end

@testset "text wrapping" begin
    @test DE.wrap("one two three four", 9) == ["one two", "three", "four"]
    @test DE.wrap("", 10) == String[]
    @test DE.wrap("abcdefghijkl", 5) == ["abcde", "fghij", "kl"]
end

@testset "resume logic" begin
    mktempdir() do out
        @test !DE.already_done(out, "X_1")
        mkpath(joinpath(out, "_logs"))
        write(joinpath(out, "X_1_schema.svg"), "<svg/>")
        @test !DE.already_done(out, "X_1")
        write(joinpath(out, "_logs", "X_1_tables.json"), "{\"written\":[\"X_1_A2000_Table1_B.csv\"]}")
        @test DE.already_done(out, "X_1")
        @test DE.existing_csvs(joinpath(out, "_logs", "X_1_tables.json")) == [joinpath(out, "X_1_A2000_Table1_B.csv")]
    end
end

@testset "collect_papers" begin
    if isdir(SAMPLE_PDFS)
        ps = collect_papers(SAMPLE_PDFS)
        @test length(ps) >= 3
        @test all(p -> startswith(p.code_tag, "MBMA_"), ps)
        @test allunique(p.code_tag for p in ps)
    else
        @info "sample PDFs not found; skipping" SAMPLE_PDFS
    end
    if isdir(SAMPLE_SORTED) && isfile(joinpath(SAMPLE_SORTED, "index.csv"))
        ps = collect_papers(SAMPLE_SORTED)
        @test !isempty(ps)
        @test all(p -> startswith(p.pcode, "P"), ps)          # PDFTopicSorter codes reused
        @test any(p -> !isempty(p.theme), ps)
    end
end

@testset "Poppler text extraction" begin
    f = sample(r"MBMA_7505")
    if f !== nothing
        pt = extract_text(f)
        @test pt.has_text
        @test pt.pages > 1
        @test occursin("=== PAGE 1 ===", pt.text)
    end
    g = sample(r"MBMA_0403")           # PDFTopicSorter reported this one has no text layer
    if g !== nothing
        pt = extract_text(g)
        @test !pt.has_text
    end
end

# ---- live tests: only when explicitly enabled (they call the API and cost money) ----------------
live = get(ENV, "DATAEXTRACTOR_LIVE", "0") == "1"
DE.load_dotenv!()
if live && !isempty(get(ENV, "ANTHROPIC_API_KEY", "")) && isdir(SAMPLE_PDFS)
    @testset "live extraction on sample PDFs" begin
        out = joinpath(SAMPLE_PDFS, "..", "test_pdfs_live_test_output")
        picks = filter(!isnothing, [sample(r"MBMA_7505"), sample(r"MBMA_9808"), sample(r"MBMA_0403")])
        for f in picks
            r = extract_paper(f; out)
            tag = r.paper.code_tag
            if tag == "MBMA_0403"
                @test r.status == :no_text
            else
                @test r.status in (:done, :skipped_existing)
                @test r.svg_path !== nothing && isfile(r.svg_path)
                for c in r.csv_paths
                    @test isfile(c)
                    @test isempty(DE.validate_csv_text(read(c, String)))
                end
            end
        end
        @test isfile(joinpath(out, "_logs", "usage.jsonl"))
        @test isfile(joinpath(out, "_logs", "usage_total.json"))
    end
else
    @info "Live API tests skipped (set DATAEXTRACTOR_LIVE=1 and ANTHROPIC_API_KEY to run them)"
end

end # testset
