# pdfulator-flavoured Markdown

**PFM is [`commonmark_x`](https://pandoc.org/MANUAL.html#extensions).**

That is the whole definition, and naming it that way rather than listing
features is the point. `commonmark_x` is pandoc's curated CommonMark superset:
[CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) plus twenty named
extensions, each one *written down* in the
[pandoc manual](https://pandoc.org/MANUAL.html#extensions). A dialect defined
as "CommonMark plus whatever the parser happens to do" is not something a
document can be checked against; this is.

`pandoc --list-extensions=commonmark_x` names the twenty but does not define
them — it emits a list of identifiers, not a grammar. The prose in the manual
is the specification, and it is where a question about what an extension
*means* has to be settled.

It also settles arguments that would otherwise be ours to have. Attribute
syntax, maths delimiters, footnotes, tables — each has two or three plausible
spellings, and adopting a specification means taking its answer rather than
picking.

This document exists because **no engine implements it completely** — and
that includes the pandoc ones.


## What the benchmark is

Four different things are easily confused here, and keeping them apart is
what makes the rest of this document meaningful:

| | |
|---|---|
| **(a)** | PFM, defined as `commonmark_x` |
| **(b)** | `commonmark_x` **as specified** — the pandoc manual's extension definitions |
| **(c)** | **pandoc's implementation** of `commonmark_x` |
| **(d)** | **markdown-it's implementation** of CommonMark plus the equivalent plugins |

**The benchmark is (b).** PFM is the specification, not any program's reading
of it. That matters because (c) and (d) each fall short of (b) in their own
places, and neither gets to redefine the target by doing so.

An earlier version of this document took (c) as the reference — it said the
pandoc engines *were* the reference implementation. That was a category error,
and it produced a table that was wrong in both directions: behaviour measured
from pandoc was recorded as though it were the specification, so wherever
pandoc under-implemented an extension, the engine that got it *right* was
marked as the one with the gap.

PFM is implemented by pandoc and by markdown-it rather than by anything
bespoke, so PFM inherits their shortfalls. That is expected and it is not a
failure of the definition. The commitment is not that every engine is
perfectly conformant; it is that **every deviation from (b) is written down
here**, whichever engine it belongs to.

If another tool's `commonmark_x` differs from ours, that is a fact about that
tool, not a defect on either side — provided we have stated ours.


## The table

Checked against the pandoc manual's extension definitions — (b) — with each
engine's behaviour measured to see whether it matches. Measurement alone is
not enough: an engine and a specification can disagree, and it is the
specification that decides which one is the gap.

`xslt` is `pandoc-xslt`, which reads the same Markdown as `pagedjs` but
targets DocBook, so its gaps are in what DocBook can express.

| Extension | vivlio | pagedjs | xslt |
|---|---|---|---|
| `definition_lists` | yes | yes | yes |
| `footnotes` | yes | yes | yes |
| `pipe_tables` | yes | yes | yes |
| `raw_html` | yes | yes | **partial** — see below |
| `smart` | yes | yes | yes |
| `strikeout` | yes | yes | yes |
| `task_lists` | yes | yes | yes |
| `tex_math_dollars` | yes | yes | yes — since pandoc 3.11 |
| `yaml_metadata_block` | yes | yes | yes |
| `alerts` | yes | yes | yes |
| `attributes` | yes | yes | yes |
| `bracketed_spans` | yes | yes | **no** — no DocBook `<phrase>` emitted |
| `emoji` | yes | yes | yes |
| `fancy_lists` | **partial** — no `(a)` | **partial** — no `#.` | **partial** — no `#.` |
| `fenced_divs` | yes | yes | yes |
| `gfm_auto_identifiers` | yes | yes | yes |
| `implicit_header_references` | ? | yes | ? |
| `raw_attribute` | **no** — see below | yes | ? |
| `subscript` | yes | yes | yes |
| `superscript` | yes | yes | yes |

The vivlio column is what is left after wiring in `@mdit/plugin-attrs`,
`-sub`, `-sup`, `-alert`, `-anchor`, `-container`, `markdown-it-emoji`,
`markdown-it-bracketed-spans` and `markdown-it-fancy-lists`.

`raw_attribute` is the one genuine absence, and it is not a missing plugin
but a missing *token*. `@mdit/plugin-attrs` consumes the braces of
`` `<u>x</u>`{=html} `` and discards the `=`-prefixed content, so the code
span reaches the renderer with `attrs` null and the target gone — there is
nothing left to act on. Closing it needs an inline rule that claims the
syntax before `attrs` eats it, which is real work rather than a dependency.

**`fancy_lists` is partial in *every* engine, and this is the clearest case
of why the benchmark has to be the specification.** The spec says:

> List markers may be enclosed in parentheses or followed by a single
> right-parenthesis or period.

and, further down:

> The `fancy_lists` extension also allows '`#`' to be used as an ordered
> list marker in place of a numeral.
>
> Note: the '`#`' ordered list marker doesn't work with `commonmark`.

So both `(a)` and `#.` are in `commonmark_x` as specified. Neither engine
implements both:

| | spec (b) | vivlio | pandoc engines |
|---|---|---|---|
| `a.` `a)` `i.` `I)` `A)` | yes | yes | yes |
| `A.` `I.` with one space | no — initials rule | no | no |
| `(a) item` | **yes** | **no** | yes |
| `#. item` | **yes** | yes | **no** |

Each gap belongs to a different engine, and each is a deliberate, documented
decision by its implementer rather than an oversight:

**`#.`** is pandoc's shortfall, admitted in pandoc's own manual in the note
quoted above. The commonmark reader does not implement this part of an
extension it otherwise enables. vivlio is the conformant one here.

**`(a)`** is `markdown-it-fancy-lists`' shortfall, disclosed in its README
under "two small differences with Pandoc's syntax": it declines parenthesised
markers *because CommonMark declines them for Arabic numerals too*, and the
author preferred internal consistency over matching pandoc. That reasoning
checks out — bare markdown-it does leave `(1) one` as a paragraph, so pandoc
is the one relaxing its own stated base. Sound, and still a deviation from
(b), so it is recorded as one.

The third row is worth keeping in view: `A. one` and `I. one` stay paragraphs
*everywhere*, and that is correct. The spec requires two spaces after a
capital-letter-and-period marker, so that "B. Russell won a Nobel Prize" is
not turned into a list. Both implementations honour it because it is
specified, not by coincidence.

Neither gap is being patched. Overriding a maintainer's published decision
with a local rule would leave PFM *less* internally consistent than the
plugin — we would accept `(a)` while our `(1)` still followed CommonMark —
and closing that properly would mean relaxing CommonMark ourselves.

One partial worth stating: `fenced_divs` under vivlio takes a **fixed set of
names** — `note`, `warning`, `tip`, `caution`, `important`, `info`, `danger`,
`example`, `quote` — because the markdown-it plugin registers one name at a
time, where pandoc accepts any name and puts it on the `<div>` as a class. A
name outside the set stays literal text rather than becoming an unstyled div,
which is the visible failure rather than the silent one.

A `?` means nobody has tested it. It is not a claim of absence — the first
version of this document guessed at several of these and got tables and
strikethrough wrong in the guessing, so the rest were measured: the vivlio
column against its actual plugin stack, the other two by running a probe
document through pandoc in each engine's own image.

Measuring is necessary and is not sufficient. A measurement says what an
engine *does*, and a row is only settled once that is compared against what
the extension *says* — otherwise the engine defines the target and every
engine is trivially conformant. The `fancy_lists` row above is the worked
example: measurement alone made vivlio look like the only offender, and
reading the spec showed the gaps were one each.

The xslt `no`s are worth reading as a group. That engine reads the same
Markdown as `pagedjs` — same pandoc, same extensions — and loses them on the
way *out*, because DocBook has no element to carry them.

`raw_html` there is **partial in the worst way**. A block-level `<figure>` is
dropped, so a hand-written figure loses its wrapper and caption. But an inline
`<b>bold</b>` is passed *through* into the DocBook verbatim, where it is not
valid DocBook at all — so it reaches the XSL-FO stage as an element the
stylesheet has no template for. Neither half is reported. A document relying
on raw HTML should not use this engine.

Maths under `xslt` used to be the other costly one, and is now fixed by the
pandoc version rather than by anything here. Debian 12's pandoc 3.1.11.1
degraded `$x^2$` to italic text plus a superscript; 3.11 -- which the image now
takes from `pandoc/minimal:latest-static` rather than apt -- emits a proper
`<inlineequation><mml:math>`, and FOP renders it without complaint.

Verified against pandoc 3.11 and 3.1.11.1 side by side. The table above was
otherwise measured on 3.1.11.1; the HTML path gained real MathML in the same
upgrade, where it previously emitted `<span class="math inline">` holding the
TeX as text.


## Changing the dialect: `markdown_features`

A document may change what it is written in, using pandoc's own extension
grammar:

```yaml
---
markdown_features: -smart                 # relative: PFM, minus smart
markdown_features: commonmark_x-smart     # absolute: names its own base
---
```

A value starting with `+` or `-` is **relative** and is appended to PFM;
anything else **replaces** it. Absent means PFM as-is. The rule is pandoc's,
so a pandoc engine passes the value to `-f` untouched and lets pandoc validate
it; the vivlio engine resolves it against the table above and **reports what it
cannot do** rather than ignoring it silently.


## What PFM adds to `commonmark_x`

Two things, both off by default.

**`implicit_figures`** — an image alone in a paragraph becomes a `<figure>`
captioned by its alt text. `commonmark_x` can turn this on and an earlier draft
of PFM included it in the baseline; it is opt-in instead because the wrapping
applies to *any* lone image, and neither parser can see the `<figure>` it might
already be inside. A document with hand-written figures gets a nested one with
the caption repeated. Captions carrying markup, and two plates sharing one
caption, can only be written as raw HTML — so those documents cannot avoid the
collision. Opt in with `markdown_features: +implicit_figures`.

**Image sizing** — pdfulator's own, not a pandoc extension, and always on:

```markdown
![a](fig.png =400x300)      after the URL — the GitLab/Typora convention
![a =400x300](fig.png)      inside the alt text
![a](fig.png =400x)         width only
![a](fig.png =50%x)         percentage
```

Adding width and height to an `<img>` cannot change a document's structure,
which is why this needs no flag. Note that `commonmark_x`'s `attributes`
extension expresses the same thing as `![a](fig.png){width=400}` — a third
spelling, and now the one to prefer: `attributes` works in every engine, and
it sets an `id` at the same time — `![a](fig.png){#plot width=400}` — which the
`=400x300` forms cannot do.


## Frontmatter

Three spellings, all handled by the wrapper before any engine sees the
document (`lib/frontmatter.sh`), so all three work under every engine:

```markdown
---                     <!--yaml                ---
title: A                title: A                title: A
---                     -->                     ...
```

The `<!--yaml` form exists so that a README carrying pdfulator metadata does
not display a block of YAML when GitHub renders it. Other tools see an
ordinary HTML comment. It is spelled after ` ```yaml ` rather than invented:
it names the content, not the tool.

**At the start only.** Frontmatter at the *end* was implemented, tested, and
removed: pandoc's native `markdown` reader accepts a metadata block anywhere,
but `commonmark_x` does not, and neither does Jekyll, Hugo, MultiMarkdown,
Obsidian, 11ty, Astro or Docusaurus. A document using one would render
correctly here and lose its metadata everywhere else, silently — which is the
divergence this document exists to prevent.

A **sidecar** `.yaml` or `.yml` beside the document does the same job and wins
over a block inside it. It is the recommended form for a file like a README
that other tools also read.

The metadata keys themselves — `title`, `date`, `authors`, `revision`,
`copyright`, `footer` — are documented in
[README.md](README.md#metadata-entries).


## `layout_features`

A separate axis, and the reason for the name. `markdown_features` says what the
markup *means*; `layout_features` says how the page should *look* —
`justify`, `shade_monospace`, `no_math` and the rest, listed in
[README.md](README.md#pdfulator_features). `pdfulator_features` is the older
name for this key and still works.


## Parity is the goal, not the assumption

Three parsers and three styling engines will not agree on everything, and this
document does not pretend otherwise. What it commits to is that a divergence is
**written down** rather than discovered.

Where an engine can reasonably close a gap, it should — a **no** in any
column is a candidate for work, not a statement of policy. Where it cannot,
that is a fact about the engine worth knowing before choosing it:
`pandoc-xslt` will never render raw HTML, because DocBook has nowhere to
put it.

Not every gap is worth closing, and one test separates those that are. A gap
that fails **visibly** — the source appears on the page as written, as `(a)`
does — costs a reader nothing but a moment's confusion, and the document can
be fixed. A gap that fails **silently**, rendering plausibly but differently
from every other tool, is the one that does damage. Those are worth real
effort; the visible ones can wait their turn, documented.

Note that a deviation is not automatically the engine's fault, and where it
is, the implementer may well have been right. `markdown-it-fancy-lists`
declines `(a)` for a stated and defensible reason. Recording it as a
deviation from (b) is not a complaint about the plugin.

An engine may also *manufacture* what it cannot parse — a polyfill. One rule
keeps that honest: **a polyfill may transform the engine's own intermediate
representation, but must not rewrite Markdown as text.** A pandoc engine may
manipulate its AST; nothing may run a regular expression over the source and
call the result parsing. A second parser that disagrees with the first is worse
than an unsupported feature, because it fails silently and inconsistently.
