# Draw the structure JSON (structure.jl) as a self-contained SVG "report schema".
#
# Layout, top to bottom: page frame · title block · BACKGROUND (navy) · RESEARCH PROGRAM
# header with parallel branch boxes (slate) fanning out and back in · KEY OUTPUT (orange)
# · SYNOPSIS (white) · RECOMMENDATIONS (orange, 1–2 boxes) · OUTCOME (navy) · footer
# title block. Colours are CSS variables in the <style> block so the palette can be
# reskinned by editing one place.

const SVG_W = 1600.0
const CX = SVG_W / 2
const CONTENT_X0 = 100.0
const CONTENT_W = SVG_W - 2 * CONTENT_X0
const FONT = "'Helvetica Neue', Helvetica, Arial, sans-serif"

# Approximate average glyph width as a fraction of font size (Helvetica/Arial).
charw(fs, bold) = fs * (bold ? 0.58 : 0.53)
maxchars(width, fs, bold) = max(4, floor(Int, width / charw(fs, bold)))

fmt(x::Real) = string(round(x; digits=1))

function xml_escape(s::AbstractString)
    s = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
    return s
end

"""
    wrap(text, maxchars) -> Vector{String}

Greedy word wrap. Words longer than `maxchars` are split.
"""
function wrap(text::AbstractString, maxchars::Int)
    words = split(strip(text))
    isempty(words) && return String[]
    lines = String[]
    cur = ""
    for w in words
        w = String(w)
        while length(w) > maxchars
            isempty(cur) || (push!(lines, cur); cur = "")
            push!(lines, first(w, maxchars))
            w = String(w[nextind(w, 0, maxchars + 1):end])
        end
        if isempty(cur)
            cur = w
        elseif length(cur) + 1 + length(w) <= maxchars
            cur *= " " * w
        else
            push!(lines, cur)
            cur = w
        end
    end
    isempty(cur) || push!(lines, cur)
    return lines
end

mutable struct Canvas
    io::IOBuffer
end
Canvas() = Canvas(IOBuffer())
Base.print(c::Canvas, xs...) = print(c.io, xs...)

# ---- primitives -------------------------------------------------------------------------

function rect!(c::Canvas, x, y, w, h; cls="", r=0, extra="")
    print(c, "<rect x=\"", fmt(x), "\" y=\"", fmt(y), "\" width=\"", fmt(w), "\" height=\"", fmt(h), "\"",
          r > 0 ? " rx=\"$(fmt(r))\"" : "", isempty(cls) ? "" : " class=\"$cls\"", isempty(extra) ? "" : " " * extra, "/>\n")
end

# Rectangle with only the bottom corners rounded (body below a header band).
function bottom_round_rect!(c::Canvas, x, y, w, h, r; cls="")
    print(c, "<path d=\"M", fmt(x), " ", fmt(y), " h", fmt(w), " v", fmt(h - r),
          " a", fmt(r), " ", fmt(r), " 0 0 1 -", fmt(r), " ", fmt(r), " h-", fmt(w - 2r),
          " a", fmt(r), " ", fmt(r), " 0 0 1 -", fmt(r), " -", fmt(r), " z\" class=\"", cls, "\"/>\n")
end

function line!(c::Canvas, x1, y1, x2, y2; cls="ln")
    print(c, "<line x1=\"", fmt(x1), "\" y1=\"", fmt(y1), "\" x2=\"", fmt(x2), "\" y2=\"", fmt(y2), "\" class=\"", cls, "\"/>\n")
end

# Vertical arrow from y1 down to y2 (arrowhead at y2).
function arrow!(c::Canvas, x, y1, y2; orange=false)
    cls = orange ? "ln-orange" : "ln"
    marker = orange ? "url(#ah-orange)" : "url(#ah-navy)"
    print(c, "<line x1=\"", fmt(x), "\" y1=\"", fmt(y1), "\" x2=\"", fmt(x), "\" y2=\"", fmt(y2 - 2),
          "\" class=\"", cls, "\" marker-end=\"", marker, "\"/>\n")
end

"""
    text!(c, x, top, lines; fs, cls, bold, italic, anchor, lh, indents, spacing) -> height

Write wrapped lines as one <text> with <tspan>s. `top` is the top of the first line;
returns the block height. `indents` shifts individual lines (hanging bullets).
`bold_prefix` renders the leading part of the first line in bold.
"""
function text!(c::Canvas, x, top, lines::AbstractVector{<:AbstractString}; fs=22, cls="t-ink", bold=false,
               italic=false, anchor="middle", lh=1.35, indents=nothing, spacing=nothing, bold_prefix="")
    isempty(lines) && return 0.0
    baseline = top + fs * 0.85
    print(c, "<text x=\"", fmt(x), "\" y=\"", fmt(baseline), "\" font-size=\"", fmt(fs), "\" class=\"", cls, "\"",
          bold ? " font-weight=\"700\"" : "", italic ? " font-style=\"italic\"" : "",
          " text-anchor=\"", anchor, "\"", spacing === nothing ? "" : " letter-spacing=\"$(fmt(spacing))\"", ">")
    for (i, l) in enumerate(lines)
        xi = x + (indents === nothing ? 0.0 : indents[i])
        print(c, "<tspan x=\"", fmt(xi), "\" dy=\"", i == 1 ? "0" : fmt(fs * lh), "\">")
        if i == 1 && !isempty(bold_prefix) && startswith(l, bold_prefix)
            print(c, "<tspan font-weight=\"700\">", xml_escape(bold_prefix), "</tspan>", xml_escape(chopprefix(l, bold_prefix)))
        else
            print(c, xml_escape(l))
        end
        print(c, "</tspan>")
    end
    print(c, "</text>\n")
    return length(lines) * fs * lh
end

# Bullets with hanging indent. Returns (lines, indents) ready for text!.
function bullet_lines(items, width, fs; bold=false)
    lines = String[]; indents = Float64[]
    mc = maxchars(width - 18, fs, bold)
    for it in items
        ls = wrap(String(it), mc)
        for (i, l) in enumerate(ls)
            push!(lines, i == 1 ? "• " * l : l)
            push!(indents, i == 1 ? 0.0 : 18.0)
        end
    end
    return lines, indents
end

getstr(d, k, default="") = (v = get(d, k, nothing); v === nothing ? default : String(v))
getlist(d, k) = (v = get(d, k, nothing); v === nothing ? Any[] : v)

# ---- blocks -------------------------------------------------------------------------------
# Every block function takes the top y and returns the bottom y.

function section_box!(c::Canvas, y, sec::AbstractDict, w; navy=true)
    x = CX - w / 2
    fs_h, fs_b, pad = 26.0, 22.0, 26.0
    hl = wrap(getstr(sec, "heading"), maxchars(w - 2pad, fs_h, true))
    bl = wrap(getstr(sec, "body"), maxchars(w - 2pad, fs_b, false))
    h = pad + length(hl) * fs_h * 1.3 + (isempty(bl) ? 0 : 10 + length(bl) * fs_b * 1.4) + pad
    if navy
        rect!(c, x, y, w, h; cls="box-navy", r=6)
        cls = "t-white"
    else
        rect!(c, x, y, w, h; cls="box-white", r=6)
        cls = "t-ink"
    end
    yy = y + pad
    yy += text!(c, CX, yy, hl; fs=fs_h, cls, bold=true, lh=1.3)
    isempty(bl) || text!(c, CX, yy + 10, bl; fs=fs_b, cls, lh=1.4)
    return y + h
end

function title_block!(c::Canvas, y, s::AbstractDict)
    tl = wrap(getstr(s, "title", "REPORT SCHEMA"), maxchars(CONTENT_W - 100, 44, true))
    y += text!(c, CX, y, uppercase.(tl); fs=44, cls="t-ink", bold=true, lh=1.2, spacing=2.0)
    st = wrap(getstr(s, "subtitle"), maxchars(CONTENT_W - 100, 24, false))
    isempty(st) || (y += 12 + text!(c, CX, y + 12, st; fs=24, cls="t-muted", lh=1.3))
    org = getstr(s, "organization")
    isempty(org) || (y += 8 + text!(c, CX, y + 8, wrap(org, maxchars(CONTENT_W - 100, 20, false)); fs=20, cls="t-muted", lh=1.3))
    y += 22
    line!(c, CONTENT_X0, y, CONTENT_X0 + CONTENT_W, y; cls="rule")
    return y
end

struct BranchLayout
    title::Vector{String}
    subtitle::Vector{String}
    bullets::Vector{String}
    indents::Vector{Float64}
    finding::Vector{String}
    head_h::Float64
    body_h::Float64
end

function layout_branch(br::AbstractDict, w, fs_t, fs_b)
    pad = 18.0
    title = wrap(uppercase(getstr(br, "title")), maxchars(w - 2pad, fs_t, true))
    sub = wrap(uppercase(getstr(br, "subtitle")), maxchars(w - 2pad, fs_t, true))
    head_h = 16 + (length(title) + length(sub)) * fs_t * 1.3 + 16
    bl, ind = bullet_lines(getlist(br, "bullets"), w - 2pad, fs_b)
    fl = wrap(getstr(br, "finding"), maxchars(w - 2pad, fs_b, false))
    body_h = pad + length(bl) * fs_b * 1.4 + (isempty(fl) ? 0 : 16 + length(fl) * fs_b * 1.4) + pad
    return BranchLayout(title, sub, bl, ind, fl, head_h, body_h)
end

function research_program!(c::Canvas, y, rp::AbstractDict)
    branches = getlist(rp, "branches")
    heading = getstr(rp, "heading", "RESEARCH PROGRAM")
    y += text!(c, CX, y, [uppercase(heading)]; fs=26, cls="t-slate", bold=true, spacing=5.0)
    isempty(branches) && return y
    n = length(branches)
    gap = 30.0
    bw = min(320.0, (CONTENT_W - (n - 1) * gap) / n)
    fs_t = bw >= 240 ? 22.0 : 18.0
    fs_b = bw >= 240 ? 19.0 : 16.0
    total = n * bw + (n - 1) * gap
    x0 = CX - total / 2
    centers = [x0 + bw / 2 + (i - 1) * (bw + gap) for i in 1:n]
    layouts = [layout_branch(b, bw, fs_t, fs_b) for b in branches]
    head_h = maximum(l.head_h for l in layouts)
    body_h = maximum(l.body_h for l in layouts)

    # fan out: stem, bar, one arrow per branch
    bar_y = y + 22
    line!(c, CX, y + 4, CX, bar_y)
    n > 1 && line!(c, centers[1], bar_y, centers[end], bar_y)
    box_top = bar_y + 34
    for cx in centers
        arrow!(c, cx, bar_y, box_top)
    end
    # boxes
    for (i, (cx, L)) in enumerate(zip(centers, layouts))
        x = cx - bw / 2
        rect!(c, x, box_top, bw, head_h + body_h; cls="box-slate", r=6)
        bottom_round_rect!(c, x + 1.5, box_top + head_h, bw - 3, body_h - 1.5, 5; cls="fill-white")
        yy = box_top + 16
        yy += text!(c, cx, yy, L.title; fs=fs_t, cls="t-white", bold=true, lh=1.3)
        isempty(L.subtitle) || text!(c, cx, yy, L.subtitle; fs=fs_t, cls="t-white", bold=true, lh=1.3)
        yb = box_top + head_h + 18
        yb += text!(c, x + 18, yb, L.bullets; fs=fs_b, cls="t-ink", anchor="start", lh=1.4, indents=L.indents)
        if !isempty(L.finding)
            # findings sit at the bottom of the body so all boxes line up
            fy = box_top + head_h + body_h - 18 - length(L.finding) * fs_b * 1.4
            text!(c, x + 18, fy, L.finding; fs=fs_b, cls="t-orange", italic=true, anchor="start", lh=1.4)
        end
    end
    box_bot = box_top + head_h + body_h
    # fan in: verticals to a bar, then a stem
    bar2 = box_bot + 30
    for cx in centers
        line!(c, cx, box_bot, cx, bar2)
    end
    n > 1 && line!(c, centers[1], bar2, centers[end], bar2)
    return bar2
end

function key_output!(c::Canvas, y, ko::AbstractDict)
    w = 1300.0
    x = CX - w / 2
    fs_h, fs_i, pad = 26.0, 22.0, 26.0
    head_h = 56.0
    items = getlist(ko, "items")
    mc = maxchars(w - 2pad, fs_i, false)
    lines = String[]; prefixes = String[]; starts = Int[]
    for it in items
        label = getstr(it, "label"); txt = getstr(it, "text")
        ls = wrap(isempty(label) ? txt : string(label, " — ", txt), mc)
        push!(starts, length(lines) + 1)
        push!(prefixes, label)
        append!(lines, ls)
    end
    body_h = pad + length(lines) * fs_i * 1.45 + max(0, length(items) - 1) * 6 + pad
    rect!(c, x, y, w, head_h + body_h; cls="box-orange", r=8)
    bottom_round_rect!(c, x + 2, y + head_h, w - 4, body_h - 2, 6; cls="fill-white")
    text!(c, CX, y + (head_h - fs_h * 1.1) / 2, [uppercase(getstr(ko, "heading", "KEY OUTPUT"))]; fs=fs_h, cls="t-white", bold=true, lh=1.1)
    yy = y + head_h + pad
    for (k, it) in enumerate(items)
        last = k == length(items) ? length(lines) : starts[k+1] - 1
        ls = lines[starts[k]:last]
        yy += text!(c, x + pad, yy, ls; fs=fs_i, cls="t-ink", anchor="start", lh=1.45, bold_prefix=prefixes[k]) + 6
    end
    return y + head_h + body_h
end

function recommendations!(c::Canvas, y, recs)
    n = length(recs)
    n == 0 && return y
    gap = 40.0
    total_w = 1300.0
    w = n == 1 ? 1100.0 : (total_w - gap) / 2
    xs = n == 1 ? [CX - w / 2] : [CX - total_w / 2, CX + gap / 2]
    fs_h, fs_l, fs_b, pad = 24.0, 21.0, 20.0, 26.0
    # measure
    plans = []
    heights = Float64[]
    for r in recs
        hl = wrap(uppercase(getstr(r, "heading")), maxchars(w - 2pad, fs_h, true))
        groups = []
        h = pad + length(hl) * fs_h * 1.3 + 14
        for g in getlist(r, "groups")
            lab = getstr(g, "label")
            ll = isempty(lab) ? String[] : wrap(lab, maxchars(w - 2pad, fs_l, true))
            bl, ind = bullet_lines(getlist(g, "bullets"), w - 2pad, fs_b)
            h += length(ll) * fs_l * 1.35 + length(bl) * fs_b * 1.4 + 12
            push!(groups, (ll, bl, ind))
        end
        h += pad - 12
        push!(plans, (hl, groups)); push!(heights, h)
    end
    h = maximum(heights)
    for (i, r) in enumerate(recs)
        x = xs[i]
        rect!(c, x, y, w, h; cls="box-orange", r=8)
        hl, groups = plans[i]
        yy = y + pad
        yy += text!(c, x + w / 2, yy, hl; fs=fs_h, cls="t-white", bold=true, lh=1.3) + 14
        for (ll, bl, ind) in groups
            isempty(ll) || (yy += text!(c, x + pad, yy, ll; fs=fs_l, cls="t-white", bold=true, anchor="start", lh=1.35))
            yy += text!(c, x + pad, yy, bl; fs=fs_b, cls="t-white", anchor="start", lh=1.4, indents=ind) + 12
        end
    end
    return y + h
end

function footer!(c::Canvas, y, s::AbstractDict, code_tag, sheet)
    w, rh = 520.0, 30.0
    x = SVG_W - 36 - 40 - w
    mc = maxchars(w - 24, 14, false)
    clip(t) = length(t) > mc ? first(t, mc - 1) * "…" : t
    rows = [clip("TITLE: REPORT SCHEMA — " * uppercase(getstr(s, "title"))),
            clip("SOURCE: " * uppercase(string(code_tag, " · ", getstr(s, "citation")))),
            "SHEET " * sheet * " · NOT TO SCALE"]
    for (i, r) in enumerate(rows)
        rect!(c, x, y + (i - 1) * rh, w, rh; cls="box-white")
        text!(c, x + 12, y + (i - 1) * rh + 8, [r]; fs=14, cls="t-ink", anchor="start", lh=1.0)
    end
    return y + 3rh
end

const SVG_STYLE = """
  <style>
    :root {
      --navy:   #1b2a44;   /* background / outcome boxes, arrows, frame, body text */
      --slate:  #5a6b7d;   /* research-program branch headers */
      --orange: #e8722a;   /* key output, recommendations, findings */
      --paper:  #ecebe6;   /* page background */
      --white:  #ffffff;   /* box interiors */
      --muted:  #6b7583;   /* subtitle text */
      --rule:   #1b2a44;
    }
    .page       { fill: #ecebe6; fill: var(--paper); }
    .frame      { fill: none; stroke: #1b2a44; stroke: var(--navy); stroke-width: 2; }
    .frame-in   { fill: none; stroke: #1b2a44; stroke: var(--navy); stroke-width: 1; }
    .box-navy   { fill: #1b2a44; fill: var(--navy); }
    .box-slate  { fill: #5a6b7d; fill: var(--slate); stroke: #5a6b7d; stroke: var(--slate); stroke-width: 1.5; }
    .box-orange { fill: #e8722a; fill: var(--orange); stroke: #e8722a; stroke: var(--orange); stroke-width: 2; }
    .box-white  { fill: #ffffff; fill: var(--white); stroke: #1b2a44; stroke: var(--navy); stroke-width: 1.5; }
    .fill-white { fill: #ffffff; fill: var(--white); }
    .t-ink      { fill: #1b2a44; fill: var(--navy); }
    .t-white    { fill: #ffffff; fill: var(--white); }
    .t-muted    { fill: #6b7583; fill: var(--muted); }
    .t-slate    { fill: #5a6b7d; fill: var(--slate); }
    .t-orange   { fill: #e8722a; fill: var(--orange); }
    .ln         { stroke: #1b2a44; stroke: var(--navy); stroke-width: 2.5; fill: none; }
    .ln-orange  { stroke: #e8722a; stroke: var(--orange); stroke-width: 2.5; fill: none; }
    .rule       { stroke: #1b2a44; stroke: var(--rule); stroke-width: 1.5; }
    .ah-navy    { fill: #1b2a44; fill: var(--navy); }
    .ah-orange  { fill: #e8722a; fill: var(--orange); }
    text        { font-family: $FONT; }
  </style>
  <defs>
    <marker id="ah-navy" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" class="ah-navy"/>
    </marker>
    <marker id="ah-orange" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" class="ah-orange"/>
    </marker>
  </defs>
"""

"""
    render_schema_svg(structure::AbstractDict; code_tag="", sheet="1 OF 1") -> String

Lay out the structure JSON returned by the model as a complete SVG document.
"""
function render_schema_svg(s::AbstractDict; code_tag::AbstractString="", sheet::AbstractString="1 OF 1")
    body = Canvas()
    y = 70.0
    y = title_block!(body, y, s)
    y += 34

    bg = get(s, "background", nothing)
    if bg isa AbstractDict
        y = section_box!(body, y, bg, 1100.0)
        arrow!(body, CX, y, y + 44); y += 44
    end

    rp = get(s, "research_program", nothing)
    if rp isa AbstractDict && !isempty(getlist(rp, "branches"))
        y = research_program!(body, y + 6, rp)
        arrow!(body, CX, y, y + 44); y += 44
    end

    ko = get(s, "key_output", nothing)
    if ko isa AbstractDict && !isempty(getlist(ko, "items"))
        y = key_output!(body, y, ko)
        arrow!(body, CX, y, y + 44); y += 44
    end

    syn = get(s, "synopsis", nothing)
    recs = getlist(s, "recommendations")
    if syn isa AbstractDict
        y = section_box!(body, y, syn, 1300.0; navy=false)
        arrow!(body, CX, y, y + 44; orange=!isempty(recs)); y += 44
    end

    if !isempty(recs)
        y = recommendations!(body, y, recs)
        arrow!(body, CX, y, y + 44); y += 44
    end

    oc = get(s, "outcome", nothing)
    if oc isa AbstractDict
        y = section_box!(body, y, oc, 1100.0)
    end

    y += 50
    y = footer!(body, y, s, code_tag, sheet)
    H = y + 50

    out = IOBuffer()
    print(out, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    print(out, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"", fmt(SVG_W), "\" height=\"", fmt(H),
          "\" viewBox=\"0 0 ", fmt(SVG_W), " ", fmt(H), "\" font-family=\"", FONT, "\">\n")
    print(out, "<title>", xml_escape(string("Report schema · ", code_tag, " · ", getstr(s, "title"))), "</title>\n")
    print(out, SVG_STYLE)
    print(out, "<rect class=\"page\" x=\"0\" y=\"0\" width=\"", fmt(SVG_W), "\" height=\"", fmt(H), "\"/>\n")
    print(out, "<rect class=\"frame\" x=\"24\" y=\"24\" width=\"", fmt(SVG_W - 48), "\" height=\"", fmt(H - 48), "\"/>\n")
    print(out, "<rect class=\"frame-in\" x=\"36\" y=\"36\" width=\"", fmt(SVG_W - 72), "\" height=\"", fmt(H - 72), "\"/>\n")
    write(out, take!(body.io))
    print(out, "</svg>\n")
    return String(take!(out))
end
