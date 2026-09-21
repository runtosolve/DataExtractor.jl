"""
    DataExtractor

Module 2 (Extraction) of the SteelData Initiative pipeline.

For every research PDF this module produces two kinds of artifact with the
Anthropic API:

1. **Schema** – one self-contained SVG flowchart (`{code_tag}_schema.svg`) of the
   paper's own structure: background, research program branches, key output,
   synopsis, recommendations and outcome.
2. **Measured data CSVs** – one CSV per table of measured / tested / reported
   numerical data (`{code_tag}_{Author}{Year}_Table{N}_{Name}.csv`), with a fixed
   header-comment block and values preserved verbatim.

Public interface: [`extract_paper`](@ref) for one PDF and [`extract_papers`](@ref)
for a folder (a plain folder of PDFs, or PDFTopicSorter's output folder).
"""
module DataExtractor

using Dates, Logging
using HTTP, JSON
using Poppler_jll

export extract_paper, extract_papers
export Paper, PaperResult, BatchResult, Client, AnthropicError
export collect_papers, code_tag_from_filename, extract_text, render_schema_svg

include("anthropic.jl")
include("pdftext.jl")
include("sources.jl")
include("structure.jl")
include("svg.jl")
include("tables.jl")
include("run.jl")

end # module
