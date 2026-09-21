# Pass 1: ask the model for the paper's own structure as JSON (drawn as SVG in svg.jl).

const STRUCTURE_SYSTEM = """
You are a structural-engineering research analyst preparing a one-page "report schema":
a flowchart that shows how one research paper or technical report is organised and how
its logic flows from motivation to outcome.

You will be given the complete extracted text of the paper (with `=== PAGE n ===`
markers). Read it and describe the paper's OWN structure — follow the sections the
paper actually has, do not force it into a template. Fill the JSON fields as follows:

- title: a short version of the paper's title for the title block (≤ 60 characters).
- subtitle: authors, organisation, report or journal identifier and date, joined with " · ".
- organization: sponsoring or publishing bodies as short names joined with " · " (or null).
- citation: "LastName, I.I. (Year), Publisher/Report identifier" for the footer.
- background: why the work was done — the problem, the motivation, the objective.
  Put the section number in the heading when the paper numbers its sections
  (e.g. "BACKGROUND · Sec. 1").
- research_program: the methods, experiments, analyses or parallel studies performed.
  One branch per distinct study/method (2 to 6 branches). Each branch has a short title,
  an optional subtitle, 2–5 terse bullets (what was done, how many specimens, ranges,
  parameters) and a one-line italic "finding" (the branch's own conclusion, ≤ 45 chars).
  If the paper has a single method, still describe it as one or two branches.
- key_output: the paper's main result or principal deliverable (a design equation, a
  classification, a set of measured values, a proposed procedure ...). 2–6 items, each a
  bold label plus a short explanation.
- synopsis: the discussion / synthesis of the evaluations (null if the paper has none).
- recommendations: 0, 1 or 2 boxes. Use two boxes when the paper separates general from
  specific (or design vs. research) recommendations, one box otherwise, an empty list
  when the paper makes no recommendations. Each box has a heading and 1–3 groups; a group
  has an optional bold label and 1–5 short bullets.
- outcome: what happens next or what the work achieved (adoption into a specification,
  future work, conclusions). Null if nothing fits.

Length limits matter because the text is drawn inside fixed boxes:
headings ≤ 40 characters; body paragraphs ≤ 320 characters; branch titles ≤ 30 characters;
bullets ≤ 60 characters; key-output labels ≤ 22 characters and texts ≤ 110 characters.
Use plain text only (no markdown). Use the unicode characters × ≈ ≤ ≥ → ° when helpful.
Prefer concrete numbers from the paper over generic phrasing.
"""

const STRUCTURE_ASK = "Describe this paper's structure and logical flow in the required JSON format."

str_schema(desc) = Dict{String,Any}("type" => "string", "description" => desc)
nullable_str(desc) = Dict{String,Any}("type" => ["string", "null"], "description" => desc)
str_array(desc) = Dict{String,Any}("type" => "array", "description" => desc, "items" => Dict{String,Any}("type" => "string"))

section_schema(desc) = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false, "required" => ["heading", "body"],
    "description" => desc,
    "properties" => Dict{String,Any}(
        "heading" => str_schema("Box heading, e.g. \"BACKGROUND · Sec. 1\""),
        "body" => str_schema("Two or three sentences, ≤ 320 characters")))

nullable_section_schema(desc) = begin
    s = section_schema(desc)
    s["type"] = ["object", "null"]
    s
end

const BRANCH_SCHEMA = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false,
    "required" => ["title", "subtitle", "bullets", "finding"],
    "properties" => Dict{String,Any}(
        "title" => str_schema("Branch title, ≤ 30 characters, e.g. \"STACK TESTS\""),
        "subtitle" => nullable_str("Optional second heading line, ≤ 30 characters"),
        "bullets" => str_array("2–5 terse bullets, ≤ 60 characters each"),
        "finding" => nullable_str("One-line conclusion of this branch, ≤ 45 characters")))

const STRUCTURE_SCHEMA = Dict{String,Any}(
    "type" => "object", "additionalProperties" => false,
    "required" => ["title", "subtitle", "organization", "citation", "background", "research_program",
                   "key_output", "synopsis", "recommendations", "outcome"],
    "properties" => Dict{String,Any}(
        "title" => str_schema("Short paper title for the title block, ≤ 60 characters"),
        "subtitle" => str_schema("Authors · organisation · report id · date"),
        "organization" => nullable_str("Sponsors / publishers, short names joined with ' · '"),
        "citation" => str_schema("Footer citation: LastName, I.I. (Year), identifier"),
        "background" => section_schema("Motivation / problem statement"),
        "research_program" => Dict{String,Any}(
            "type" => "object", "additionalProperties" => false, "required" => ["heading", "branches"],
            "properties" => Dict{String,Any}(
                "heading" => str_schema("e.g. \"RESEARCH PROGRAM · Sec. 2\""),
                "branches" => Dict{String,Any}("type" => "array", "items" => BRANCH_SCHEMA,
                                               "description" => "2–6 parallel studies / methods"))),
        "key_output" => Dict{String,Any}(
            "type" => "object", "additionalProperties" => false, "required" => ["heading", "items"],
            "properties" => Dict{String,Any}(
                "heading" => str_schema("e.g. \"KEY OUTPUT: FIVE LUBRICANT FAMILIES\""),
                "items" => Dict{String,Any}("type" => "array", "description" => "2–6 items",
                    "items" => Dict{String,Any}(
                        "type" => "object", "additionalProperties" => false, "required" => ["label", "text"],
                        "properties" => Dict{String,Any}(
                            "label" => str_schema("Bold label, ≤ 22 characters"),
                            "text" => str_schema("Explanation, ≤ 110 characters")))))),
        "synopsis" => nullable_section_schema("Discussion / synthesis (null if none)"),
        "recommendations" => Dict{String,Any}(
            "type" => "array", "description" => "0, 1 or 2 recommendation boxes",
            "items" => Dict{String,Any}(
                "type" => "object", "additionalProperties" => false, "required" => ["heading", "groups"],
                "properties" => Dict{String,Any}(
                    "heading" => str_schema("e.g. \"GENERAL RECOMMENDATIONS · Sec. 4\""),
                    "groups" => Dict{String,Any}("type" => "array", "items" => Dict{String,Any}(
                        "type" => "object", "additionalProperties" => false, "required" => ["label", "bullets"],
                        "properties" => Dict{String,Any}(
                            "label" => nullable_str("Optional bold group label"),
                            "bullets" => str_array("1–5 bullets, ≤ 60 characters each"))))))),
        "outcome" => nullable_section_schema("What happens next / what was achieved (null if none)")))

"""
    ask_structure(client, paper_text; model, effort, max_tokens, fallbacks) -> (Dict, resp)

Pass 1: the paper's structure as a JSON `Dict` following `STRUCTURE_SCHEMA`.
"""
function ask_structure(client::Client, paper_text::AbstractString; model=DEFAULT_MODEL,
                       effort="high", max_tokens::Int=16_000, fallbacks::Bool=true)
    body = build_body(STRUCTURE_SYSTEM, paper_text, STRUCTURE_ASK;
                      model, effort, max_tokens, schema=STRUCTURE_SCHEMA, fallbacks)
    return ask_json(client, body; betas=betas_for(fallbacks))
end
