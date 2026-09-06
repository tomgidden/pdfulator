# Vendored KaTeX assets

KaTeX 0.18.7 — `katex.min.css` and the woff2 faces it references, copied from
`_nopayload/node_modules/katex/dist/`.

## Why these are here and not read from node_modules

`_nopayload/` never enters the payload: it holds the engine's *program*, which
is platform-specific and has no business inside a directory that gets mounted
into a container or sent to a remote host. But KaTeX's stylesheet and fonts are
static content that a container engine genuinely needs, so they are vendored
here — outside `_nopayload/` — and stage like any other engine asset.

The CSS is declared as `stylesheet` in ../engine.conf, which puts it at level 5
of the styling cascade: below every theme rule, so a theme can restyle maths
without fighting it.

## What was changed

The upstream `src:` lists offer woff2, woff and ttf. The woff and ttf
alternatives are stripped here and only the woff2 files are vendored: the only
renderer is Chromium, which takes woff2, and a payload carrying `url()`s to
files that are not in it is a dangling reference nothing would report.

## Updating

Bump `katex` in ../_nopayload/package.json, then re-run the vendoring:

    cd engines/vivlio
    cp _nopayload/node_modules/katex/dist/katex.min.css katex/
    cp _nopayload/node_modules/katex/dist/fonts/*.woff2 katex/fonts/
    # then strip the woff/ttf sources from the src: lists again

The parser itself is imported from node_modules as normal — only the CSS and
fonts are duplicated here.
