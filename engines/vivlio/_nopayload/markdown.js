// engines/vivlio/_nopayload/markdown.js — pdfulator-flavoured Markdown, and
// the page around it.
//
// It lives beside the vivlio engine's main.js rather than in a shared
// directory of its own, which is the pattern already in the tree: vivlio owns
// main.js and payload.js, and vivlio-docker reuses them by path rather than
// keeping copies. The `pagedjs` engine does the same with this file. A
// directory of genuinely shared modules would be tidier, but it would mean
// imports reaching across engine directories and Dockerfiles copying from two
// places, for one file.
//
// Everything both markdown-it engines do BEFORE they paginate: resolve the
// dialect, build a parser, read frontmatter and a sidecar, normalise metadata,
// and fill the Mustache template. What is left in each engine's own main.js is
// the renderer -- the Vivliostyle viewer over a mux server for `vivlio`,
// pagedjs-cli for `pagedjs` -- and nothing else.
//
// WHY THIS IS SHARED RATHER THAN COPIED. The two engines are meant to render
// the same document the same way, differing only in the paginator. If each
// carried its own plugin list, `markdown_features` resolution and metadata
// handling, they would drift -- and the drift would show up as a rendering
// difference that looks like a paginator bug. The pandoc pair demonstrates the
// failure mode: two templates of the same ancestry, kept separate because they
// had stopped being interchangeable. One module means a difference in output
// is genuinely the paginator's, which is what makes cross-engine parity a
// testable claim rather than a hope.
//
// The one thing NOT shared is how a stylesheet is addressed. `vivlio` serves
// the payload over a local mux server and needs `/payload/print.css`;
// `pagedjs` hands pagedjs-cli a file and needs an absolute filesystem path.
// That is a real difference between the renderers rather than an accident, so
// buildHtml takes an `href` function instead of assuming either.

import fs from 'fs';
import path from 'path';

import MarkdownIt from 'markdown-it';
import mdDeflist from 'markdown-it-deflist';
import mdTaskLists from 'markdown-it-task-lists';
import { footnote as mdFootnote } from '@mdit/plugin-footnote';
import { figure as mdFigure } from '@mdit/plugin-figure';
import { imgSize as mdImgSize, legacyImgSize as mdImgSizeLegacy }
  from '@mdit/plugin-img-size';
import { katex as mdKatex } from '@mdit/plugin-katex';
import { attrs as mdAttrs } from '@mdit/plugin-attrs';
import { sub as mdSub } from '@mdit/plugin-sub';
import { sup as mdSup } from '@mdit/plugin-sup';
import { alert as mdAlert } from '@mdit/plugin-alert';
import { anchor as mdAnchor } from '@mdit/plugin-anchor';
import { container as mdContainer } from '@mdit/plugin-container';
import { full as mdEmoji } from 'markdown-it-emoji';
import mdBracketedSpans from 'markdown-it-bracketed-spans';
// Both engines' package.json carry an `overrides` entry pinning this plugin's
// markdown-it peer to ours, and it is load-bearing rather than tidying: the
// plugin's declared peer caps at markdown-it 14 while the @mdit/* family wants
// 15, so npm refuses the tree outright without it. The cap is stale -- the
// plugin was exercised against 15 before the override was written -- but only
// its author can lift it. Remove the override and `npm install` stops working.
import { markdownItFancyListPlugin as mdFancyLists } from 'markdown-it-fancy-lists';
import yaml from 'js-yaml';
import Mustache from 'mustache';

import { markup, stylesheets, engineOf, features } from './payload.js';


// Used only when the payload names no structural file, which the wrapper never
// allows -- see buildHtml.
//
// The stylesheet links are {{{stylesheets}}} here as in every template: which
// sheets apply and in what order is the engine's answer, given once, rather
// than a list each template has to keep in step. See buildHtml.
const FALLBACK_TMPL = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{title}}</title>
{{{stylesheets}}}
</head>
<body class="{{pdfulator_features}}">
  <article>
    <hgroup>
      <h1>{{{title}}}</h1>
      {{#subtitle}}<p>{{{subtitle}}}</p>{{/subtitle}}
    </hgroup>
    {{{body}}}
  </article>
</body>
</html>
`;


// Markdown → HTML

// The dialect is CommonMark plus the extensions below, each one named here
// rather than assumed -- see DIALECT.md for what is in and what is not.
//
// Footnotes are not in CommonMark, and their absence was not uniformly quiet:
// a definition that is a bare word or a URL parses as a shortcut reference
// link, so `[^1]: https://example.com/paper` silently turned the marker into a
// live link and dropped the note. (A definition that reads as a sentence falls
// through as literal text instead -- visible, and merely ugly.)
//
// Image sizing (`![a](f.jpg =400x300)`) is always on: it adds width/height to
// an <img> and cannot change a document's structure. Figure wrapping is opt-in
// -- see parserFor below.
// `auto_figure` is opt-in, and the reason is compatibility rather than taste.
// The plugin wraps ANY lone image in a paragraph, and markdown-it parses raw
// HTML blocks opaquely -- so an image inside a hand-written <figure> gets a
// second, nested <figure> with the alt text repeated as a visible caption. A
// document doing that is not doing anything wrong: a caption carrying bold
// text or maths cannot live in alt text, and two plates sharing one caption
// cannot be written as `![]()` at all. Defaulting this on would break every
// such document silently, in the layout rather than with an error.
//
// (The plugin offers no way to skip images already inside a figure, and could
// not: by the time it sees the image, the surrounding <figure> is an opaque
// HTML block token.)
// Maths is ON by default, and `no_math` turns it off.
//
// On by default because KaTeX renders at parse time, here, with no script in
// the page and no network: the cost of having it available is a stylesheet in
// the payload, not a slower or more fragile render. That is also why KaTeX and
// not MathJax -- 4.7MB against 112MB installed, most of MathJax's bulk being a
// speech-rule engine that means nothing on paper.
//
// The `$...$` delimiters are the ones CommonMark's own math threads worry
// about colliding with prose. In practice the plugin requires no space after
// the opening `$`, so "it cost $5 and then $10" stays text, code spans are
// untouched and `\$` escapes. A sentence like "$1,200 in $2024$ terms" does
// misfire -- but that text is genuinely delimiter-shaped, and `no_math` is
// there for a document that would rather not have the ambiguity at all.
const FEATURE_PARSERS = new Map();

// pdfulator-flavoured Markdown, as an extension set rather than a plugin list.
//
// PFM is `commonmark_x` -- pandoc's curated CommonMark superset. Naming it
// that way makes the dialect a specification someone can check a document
// against, and makes the pandoc engines the reference implementation rather
// than the odd ones out: they get this by passing the string to `pandoc -f`,
// while this engine has to assemble the equivalent out of markdown-it plugins.
//
// implicit_figures is deliberately NOT in the baseline, though commonmark_x
// can turn it on and an earlier draft of PFM included it. The plugin wraps ANY
// lone image, and markdown-it parses raw HTML opaquely -- so an image inside a
// hand-written <figure> gets a second, nested one with the alt text repeated
// as a visible caption. A caption carrying markup, or two plates under one
// caption, can only be written as raw HTML, so those documents cannot avoid
// it. Opt in with `markdown_features: +implicit_figures`.
//
// The gap is real and is not hidden. Everything commonmark_x turns on that
// this engine cannot yet do is listed in UNSUPPORTED below, and asking for one
// is reported rather than silently ignored. See DIALECT.md for the table.
const PFM_FORMAT = 'commonmark_x';

// What commonmark_x enables by default (pandoc 3.1.11.1), and what this engine
// does about each. `true` means implemented; a string names it as a known gap.
const COMMONMARK_X = {
  alerts:                     true,
  attributes:                 true,
  bracketed_spans:            true,
  definition_lists:           true,
  emoji:                      true,
  fancy_lists:                true,
  fenced_divs:                true,
  footnotes:                  true,
  gfm_auto_identifiers:       true,
  implicit_header_references: 'depends on gfm_auto_identifiers; untested',
  pipe_tables:                true,
  // Not a missing plugin but a missing token: mdAttrs consumes the `{=html}`
  // braces and discards the `=`-prefixed content, so by the time any renderer
  // override could run there is nothing left to read -- the code span arrives
  // with attrs null and the target gone. Closing this needs an inline rule
  // that claims the syntax before mdAttrs eats it. Measured, not assumed.
  raw_attribute:              'mdAttrs discards {=target}, leaving no token to render',
  raw_html:                   true,
  smart:                      true,
  strikeout:                  true,
  subscript:                  true,
  superscript:                true,
  task_lists:                 true,
  tex_math_dollars:           true,
  yaml_metadata_block:        true,
};

// Extensions pandoc knows that are OFF in commonmark_x. Only the ones this
// engine can actually act on are listed; the rest reach reportUnsupported.
const OPTIONAL = {
  implicit_figures: true,
};

// Parse pandoc's extension grammar into a set of enabled extension names.
//
//   markdown_features: -smart              relative: PFM, minus smart
//   markdown_features: commonmark_x-smart  absolute: names its own base
//   (absent)                               PFM as-is
//
// A value starting with + or - is relative and is appended to PFM; anything
// else replaces it. Same rule as the pandoc engines, so one document means one
// dialect whichever engine renders it.
function resolveFeatures(markdownFeatures) {
  const raw = String(markdownFeatures || '').trim();
  const spec = !raw ? PFM_FORMAT
             : /^[+-]/.test(raw) ? PFM_FORMAT + raw
             : raw;

  const base = spec.split(/[+-]/)[0];
  const on = new Set();

  // Only commonmark_x is understood as a base. Another one is not an error
  // here -- pandoc would accept it and this engine cannot -- so it is reported
  // and treated as commonmark_x, which is the closest thing available.
  const unknownBase = base !== 'commonmark_x' ? base : null;
  for (const [ext, supported] of Object.entries(COMMONMARK_X)) {
    if (supported === true) on.add(ext);
  }

  const asked = [];
  for (const m of spec.slice(base.length).matchAll(/([+-])([a-z_0-9]+)/g)) {
    asked.push(m[2]);
    if (m[1] === '+') on.add(m[2]); else on.delete(m[2]);
  }

  // What was asked for that this engine cannot do. Two kinds: an extension
  // commonmark_x has that is not implemented here, and one nobody has heard
  // of. Both are worth saying out loud -- a dialect flag that silently does
  // nothing is how a document comes out wrong with no indication why.
  const gaps = [];
  for (const ext of on) {
    if (COMMONMARK_X[ext] === true || OPTIONAL[ext] === true) continue;
    gaps.push(`${ext} (${COMMONMARK_X[ext] || 'not a commonmark_x extension'})`);
  }

  return { on, gaps, unknownBase, spec, asked };
}

function reportFeatureGaps({ gaps, unknownBase, spec }) {
  if (unknownBase) {
    console.error(`vivlio: markdown_features names the base "${unknownBase}", `
                + `which this engine does not implement; using commonmark_x.`);
  }
  for (const gap of gaps.sort()) {
    console.error(`vivlio: ${spec} asks for ${gap}`);
  }
}

function parserFor(markdownFeatures, layoutFeatures) {
  const resolved = resolveFeatures(markdownFeatures);
  const { on } = resolved;

  // Layout features are a separate axis: they say how the page should look,
  // not what the markup means. auto_figure is accepted here as the older
  // spelling of implicit_figures, which is where it properly belongs.
  const layout = ` ${layoutFeatures || ''} `;
  if (layout.includes(' auto_figure ')) on.add('implicit_figures');
  if (layout.includes(' no_auto_figure ')) on.delete('implicit_figures');
  if (layout.includes(' no_math ')) on.delete('tex_math_dollars');

  const key = [...on].sort().join(',');
  let parser = FEATURE_PARSERS.get(key);
  if (parser) return parser;

  reportFeatureGaps(resolved);

  parser = new MarkdownIt({
    html: on.has('raw_html'),
    linkify: true,
    typographer: on.has('smart'),
  });

  if (on.has('definition_lists')) parser = parser.use(mdDeflist);
  if (on.has('task_lists'))       parser = parser.use(mdTaskLists, { enabled: true });
  if (on.has('footnotes'))        parser = parser.use(mdFootnote);
  if (on.has('implicit_figures')) parser = parser.use(mdFigure);
  if (on.has('subscript'))        parser = parser.use(mdSub);
  if (on.has('superscript'))      parser = parser.use(mdSup);
  if (on.has('emoji'))            parser = parser.use(mdEmoji);
  if (on.has('alerts'))           parser = parser.use(mdAlert);

  // `attributes` covers `# H {#id}`, `para {.cls}` and `![a](f.png){width=400}`
  // -- the last being pandoc's own spelling of image sizing, and the one to
  // prefer over the two `=400x300` forms below now that it works here.
  //
  // On its own it does NOT give `bracketed_spans`: `[text]{.cls}` attaches the
  // class to the paragraph rather than creating a <span>, because mdAttrs
  // decorates elements and does not create them. Inline attributes on an
  // element that already exists (`*em*{.cls}`) do work. The plugin below
  // supplies the missing element.
  // bracketed_spans: `[text]{.cls #id lang=fr}` becomes a <span> carrying the
  // attributes. It must be registered BEFORE mdAttrs: it creates the element
  // that mdAttrs then decorates. (Both orders happen to work today, because
  // the plugin installs its own inline rule rather than post-processing, but
  // the dependency is real and the order states it.)
  if (on.has('bracketed_spans')) parser = parser.use(mdBracketedSpans);

  if (on.has('attributes')) parser = parser.use(mdAttrs);

  // gfm_auto_identifiers: a heading gets an id derived from its text, which is
  // what makes `[see](#my-heading)` resolve. `permalink: false` because a
  // printed page has nowhere to click an anchor link to.
  if (on.has('gfm_auto_identifiers')) {
    parser = parser.use(mdAnchor, { permalink: false });
  }

  // fenced_divs: `::: warning` ... `:::`. pandoc allows any name and puts it on
  // the <div> as a class; this plugin takes one name per registration, so the
  // set below is what a theme can style. A name outside it stays literal text
  // rather than becoming an unstyled div, which is the visible failure rather
  // than the silent one.
  if (on.has('fenced_divs')) {
    for (const name of ['note', 'warning', 'tip', 'caution', 'important',
                        'info', 'danger', 'example', 'quote']) {
      parser = parser.use(mdContainer, { name });
    }
  }

  // fancy_lists: `a.` `a)` `i.` `I)` give <ol type="a"|"i"|"I">, and the first
  // marker sets `start` -- `iv.` opens a list at 4.
  //
  // The plugin's three options (allowMultiLetter, allowOrdinal and its
  // siblings) are all left OFF deliberately: with defaults it matches pandoc
  // on every marker measured, including the ones pandoc REFUSES. `A. one` and
  // `I. one` stay paragraphs in both, because a lone capital and a period is
  // more often an initial ("A. Turing wrote...") than a list; turning either
  // option on would break that agreement.
  //
  // Two markers in the SPECIFICATION are handled differently by the two
  // implementations, and the gaps are one each -- measured against the pandoc
  // manual's definition of fancy_lists, not against pandoc's behaviour. The
  // distinction matters: comparing engine to engine made this look like one
  // engine's fault, and it is not.
  //
  //   `#. item`   IS specified ("the fancy_lists extension also allows '#'
  //               to be used as an ordered list marker"), and this plugin
  //               implements it. Pandoc's commonmark reader does NOT -- its
  //               own manual carries the note "the '#' ordered list marker
  //               doesn't work with `commonmark`". So a document using `#.`
  //               renders as a list here and as a paragraph under the pandoc
  //               engines, and THIS engine is the conformant one. Do not
  //               "fix" it by suppressing the marker.
  //
  //   `(a) item` IS specified too ("list markers may be enclosed in
  //               parentheses"), and this plugin declines it -- deliberately,
  //               per its README, because CommonMark rejects `(1)` for Arabic
  //               numerals and the author preferred internal consistency to
  //               matching pandoc. Bare markdown-it does leave `(1) one` as a
  //               paragraph, so the reasoning holds. Left alone: a local rule
  //               accepting `(a)` while `(1)` still followed CommonMark would
  //               be less consistent than the plugin, and it fails visibly
  //               anyway -- the brackets show up on the page.
  //
  // Both are recorded in DIALECT.md rather than left to be found in a PDF.
  if (on.has('fancy_lists')) parser = parser.use(mdFancyLists);

  // Image sizing is not a commonmark_x extension -- pandoc spells it with
  // `+attributes`, as `![a](f.png){width=400}`. These two spellings are
  // pdfulator's own, and are always on: adding width/height to an <img>
  // cannot change a document's structure.
  //
  // The registration order is load-bearing. `=400x300` after the URL is the
  // de-facto convention (GitLab, Typora); `![alt =400x300](f.jpg)` is what
  // this plugin's maintained export reads. Registering imgSize first makes
  // the legacy form fail in the worst way -- the `=400x300` survives into the
  // alt text and therefore into the caption.
  parser = parser.use(mdImgSizeLegacy).use(mdImgSize);

  // `throwOnError: false` renders a malformed expression in red rather than
  // aborting the document. A typo in one formula should cost that formula, not
  // the whole conversion -- the same reasoning as a missing image not being
  // fatal.
  if (on.has('tex_math_dollars')) {
    parser = parser.use(mdKatex, {
      delimiters: 'dollars',
      throwOnError: false,
      logger: () => {},
    });
  }

  FEATURE_PARSERS.set(key, parser);
  return parser;
}


function parseFrontMatter(source) {
  const match = source.match(/^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)(\r?\n|$)/);
  if (!match) return { meta: {}, body: source };
  let meta = {};
  try { meta = yaml.load(match[1]) || {}; } catch { /* ignore */ }
  return { meta, body: source.slice(match[0].length) };
}

function loadSidecar(inputBase) {
  for (const ext of ['.yaml', '.yml']) {
    const p = inputBase + ext;
    if (fs.existsSync(p)) {
      try { return yaml.load(fs.readFileSync(p, 'utf8')) || {}; } catch { /* ignore */ }
    }
  }
  return {};
}

function normaliseMeta(raw) {
  const meta = { ...raw };

  // Hoist first H1 → title handled before rendering; this normalises the rest

  // Derive year
  if (!meta.year) {
    if (meta.date && typeof meta.date === 'object' && meta.date.year) {
      meta.year = String(meta.date.year);
    } else if (typeof meta.date === 'string') {
      const m = meta.date.match(/(\d{4})/);
      meta.year = m ? m[1] : String(new Date().getFullYear());
    } else {
      meta.year = String(new Date().getFullYear());
    }
  }

  // Layout features. `layout_features` is the name; `pdfulator_features` is
  // the older one and still works, because documents in the wild use it and
  // breaking them to rename a key would be a poor trade. The split is what the
  // rename is for: `layout_features` says how the page should LOOK, while
  // `markdown_features` says what the MARKUP MEANS, and conflating the two
  // under one key left no room for the second.
  if (meta.layout_features == null && meta.pdfulator_features != null) {
    meta.layout_features = meta.pdfulator_features;
  }
  for (const k of ['layout_features', 'markdown_features']) {
    if (Array.isArray(meta[k])) meta[k] = meta[k].join(' ');
  }
  meta.pdfulator_features = meta.layout_features || '';

  // Normalise project/product aliases
  meta.project = meta.project || meta.product || meta.productname || '';

  return meta;
}

function normaliseAuthors(raw) {
  if (!raw) return [];
  const arr = Array.isArray(raw) ? raw : [raw];
  return arr.map(a => {
    if (typeof a === 'string') return { name: a };
    return { ...a, name: a.name || [a.firstname, a.surname].filter(Boolean).join(' ') || '' };
  });
}

function formatDate(d) {
  if (!d) return '';
  if (typeof d === 'string') return d;
  if (typeof d === 'object') return [d.day, d.month, d.year].filter(Boolean).join(' ');
  return String(d);
}


// Template rendering via Mustache
// {{var}} — escaped, {{{var}}} — raw HTML, {{#var}}...{{/var}} — conditional/loop


// The stylesheet links, in cascade order.
//
// THE ENGINE EMITS THESE, NOT THE TEMPLATE. That is the seam between the HTML
// world and the CSS world, and it is not a workaround: reconciling a list of
// (level, file) into a rendering is the engine's job, and for an HTML engine
// the rendering is a run of <link> elements. An XSL-FO engine reconciles the
// same list completely differently -- it is not additive at all -- which is the
// check that the abstraction is in the right place.
//
// What this buys, concretely: ordering lives in one place. A new level, or a
// theme naming a second stylesheet, never touches a template. Before this,
// three <link>s were written out in every template and in this file's fallback,
// so adding one meant editing all of them and hoping none was missed.
//
// WHY THE HREFS ARE ABSOLUTE. The generated HTML lives in a temp directory
// served at /doc/, while the payload is served at /payload/ -- the document and
// the payload are not in one tree, so a relative href cannot reach across.
// The engine generates them, so no author ever writes the prefix. Note this
// does NOT apply to url() inside a stylesheet: CSS resolves those against the
// stylesheet's own URL, so a mirrored sheet finds the assets mirrored beside
// it. That is exactly why the payload mirrors the source tree.
// A stylesheet staged from outside any object -- --css. It is the top of the
// cascade, so it has to stay above the generated files the payload root holds.
function isExternal(p) {
  return p.split(path.sep).includes('external');
}


function escapeAttr(s) {
  return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;')
                  .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}


// --css is NOT a parameter here. It reaches this function through the payload
// like every other stylesheet: staging copies it in and the walk finds it at
// the top of the cascade. Taking it as an argument would mean emitting the
// path the user typed -- a path on the host filesystem, which the document is
// served over HTTP and a container cannot see at all.
// `href` turns a payload-relative path into whatever the renderer can fetch.
// vivlio serves the payload over a mux server and wants `/payload/print.css`;
// pagedjs hands pagedjs-cli a file and wants an absolute path. Defaulting to
// the served form keeps vivlio's behaviour exactly as it was.
export function payloadHref(payload) {
  return p => '/payload/' + path.relative(payload, p).split(path.sep).join('/');
}

// An absolute filesystem path, for a renderer that loads the page from disk
// rather than over HTTP. NOT a file:// URL: pagedjs-cli hands the path to a
// browser that resolves it against the page's own location, and the legacy
// pandoc-pagedjs engine has always passed a bare path here too -- so this
// matches what is known to work rather than introducing a second convention.
export function fileHref() {
  return p => p;
}

function linkTags(payload, href = payloadHref(payload)) {
  const link = h => `  <link rel="stylesheet" href="${escapeAttr(h)}">`;

  const out = [];

  // Fonts first and unconditionally: it is generated at the payload root, it
  // declares @font-face and the --pdfulator-<role> properties, and every sheet
  // below may refer to them.
  const fontsCss = path.join(payload, 'fonts.css');
  if (fs.existsSync(fontsCss)) out.push(link(href(fontsCss)));

  // Which engine and styler, read from the payload rather than passed in: the
  // contract is three paths, and `vivlio` and `vivlio-docker` run this same
  // file, so neither can be a constant here.
  const { id, styler } = engineOf(payload);
  const sheets = stylesheets(payload, id, styler);

  // NO SPECIAL CASE FOR THE GENERATED SHEET ANY MORE.
  //
  // There used to be one: logo.css was written to the payload ROOT, outside
  // every band, so this had to splice it in by hand -- after the themes that
  // declared it, but before --css, which is the user's last word. Generating
  // it per level (PAYLOAD-PLAN §8) means it arrives from stylesheets() in its
  // own band like anything else, and the ordering falls out of the cascade
  // rather than being decided here.
  const external = sheets.filter(isExternal);
  const declared = sheets.filter(s => !isExternal(s));

  for (const sheet of declared) out.push(link(href(sheet)));
  for (const sheet of external) out.push(link(href(sheet)));

  return out.join('\n');
}


export function buildHtml(mdSource, inputBase, payloadDir, extraCss, href) {
  const sidecar = loadSidecar(inputBase);
  const { meta: docMeta, body: rawBody } = parseFrontMatter(mdSource);

  // Sidecar provides defaults; in-document front matter overrides
  let merged = { ...sidecar, ...docMeta };

  // Hoist first H1 → title
  let body = rawBody;
  if (!merged.title) {
    const h1 = body.match(/^#\s+(.+)$/m);
    if (h1) {
      merged.title = h1[1].trim();
      body = body.replace(/^#\s+.+\n?/m, '');
    }
  }

  const meta = normaliseMeta(merged);

  // A theme's own default features, from theme.conf's `features` key, walked
  // down the chain like everything else. The document's own pdfulator_features
  // still wins: a theme supplies a default, it does not impose one.
  //
  // This used to read a `theme.yaml` at the payload root -- a filename nothing
  // declared and no shipped theme had, and the last by-name lookup left in this
  // file.
  if (!meta.layout_features) {
    const themeFeatures = features(payloadDir);
    if (themeFeatures) {
      meta.layout_features = themeFeatures;
      meta.pdfulator_features = themeFeatures;
    }
  }

  const parser = parserFor(meta.markdown_features, meta.layout_features);
  const renderedBody = parser.render(body);

  // The structural file, named by the payload's own template.conf rather than
  // looked for under an agreed filename. `article.tmpl` at the payload root was
  // a leftover from when the staged directory WAS the theme, and it is the
  // by-name coupling that once let a Mustache template reach pandoc: staging
  // the right file under the expected name fixed the symptom but left every
  // ecosystem obliged to agree on a name.
  //
  // FALLBACK_TMPL is for the engine run on its own, against a directory nobody
  // staged -- which its own test does, and which is the whole point of the
  // engine contract being three paths and nothing else. It is deliberately the
  // minimum that produces a readable page, not a copy of the real template: an
  // engine carrying a second opinion about how a document should look is how
  // defaults/ and the pandoc engine drifted apart.
  const tmplPath = markup(payloadDir);
  const tmpl = tmplPath
    ? fs.readFileSync(tmplPath, 'utf8')
    : FALLBACK_TMPL;

  // Render inline markdown in title/subtitle (e.g. _pdfulator_ → <em>pdfulator</em>)
  const mdInline = s => s ? parser.renderInline(String(s)) : '';

  const ctx = {
    ...meta,
    body: renderedBody,
    title: mdInline(meta.title || ''),
    subtitle: mdInline(meta.subtitle || ''),
    authors: normaliseAuthors(meta.authors || meta.author),
    date: formatDate(meta.date),
    css: extraCss || meta.css || '',
    stylesheets: linkTags(payloadDir, href || payloadHref(payloadDir)),
    // Still `pdfulator_features` in the template context: it becomes the
    // <body> class list, and renaming it would break every theme's CSS
    // selectors for no gain the reader can see.
    pdfulator_features: meta.layout_features || '',
  };

  return Mustache.render(tmpl, ctx);
}
