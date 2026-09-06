#!/usr/bin/env bun
// engines/vivlio/main.js — the vivlio engine's converter.
//
//   main.js <input|-> <output|-> <payload-dir>
//
// One document in, one document out. Everything else -- which files to
// convert, where the output goes, whether it may be overwritten, which payload
// that directory name came from, which browser to drive -- was decided by the
// wrapper before this ran, and arrives as three arguments and $CHROME_PATH.
//
// This is what remains of the v2 pdfulator.js after the common layer took the
// rest. The pipeline is unchanged, and deliberately so: markdown-it for the
// markdown, Mustache over the payload's markup template for the page, then the
// Vivliostyle viewer served over a local mux server and printed by Chromium
// through puppeteer-core's page.pdf().
//
// What left, and where it went:
//
//   parseArgs, main()          -> lib/args.sh, lib/jobs.sh
//   classifyPath, isMarkdownInput -> lib/paths.sh
//   resolveTheme               -> lib/theme.sh
//   listChromiumCandidates     -> lib/browser.sh
//   watchDir                   -> lib/watch.sh
//
// The browser *download* stayed (see install-browser.js): it is a genuine JS
// dependency on @puppeteer/browsers, not a path table, and only engines that
// drive a browser need one at all.

import fs from 'fs';
import path from 'path';
import os from 'os';
import { spawn } from 'child_process';
import { createServer } from 'http';
import { fileURLToPath } from 'url';


// Dependencies — installed alongside this script in node_modules

import MarkdownIt from 'markdown-it';
import mdDeflist from 'markdown-it-deflist';
import mdTaskLists from 'markdown-it-task-lists';
import { footnote as mdFootnote } from '@mdit/plugin-footnote';
import { figure as mdFigure } from '@mdit/plugin-figure';
import { imgSize as mdImgSize, legacyImgSize as mdImgSizeLegacy }
  from '@mdit/plugin-img-size';
import yaml from 'js-yaml';
import Mustache from 'mustache';
import puppeteer from 'puppeteer-core';

// The payload reader: what the staged directory says it contains. Local to
// this engine rather than a dependency -- it reads conf files and nothing else.
import { markup, stylesheets, engineOf, features } from './payload.js';


// Paths
//
// There is no defaults directory any more. What used to live there -- a
// stylesheet, a template and three font families -- was engine-specific
// content in a shared place, and the copy the pandoc engine kept beside it had
// already drifted 640 lines away. Both are now themes, and the wrapper hands
// this engine a staged directory holding everything a conversion needs:
// print.css, fonts.css, the fonts themselves, and the template.

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

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
const FEATURE_PARSERS = new Map();

function parserFor(featureList) {
  const wanted = ` ${featureList} `;
  const autoFigure = wanted.includes(' auto_figure ')
                  && !wanted.includes(' no_auto_figure ');
  const key = autoFigure ? 'figure' : 'plain';

  let parser = FEATURE_PARSERS.get(key);
  if (parser) return parser;

  parser = new MarkdownIt({ html: true, linkify: true, typographer: false })
    .use(mdDeflist)
    .use(mdTaskLists, { enabled: true })
    .use(mdFootnote);

  // BOTH size syntaxes, and this registration order is load-bearing.
  // `=400x300` after the URL is the de-facto convention (GitLab, Typora and
  // others); `![alt =400x300](f.jpg)` is what this plugin's maintained export
  // reads. Registering imgSize first makes the legacy form fail in the worst
  // way -- the `=400x300` survives into the alt text and therefore into the
  // caption. legacyImgSize first, then imgSize, and both spellings resolve.
  if (autoFigure) parser = parser.use(mdFigure);
  parser = parser.use(mdImgSizeLegacy).use(mdImgSize);

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

  // Flatten pdfulator_features
  if (Array.isArray(meta.pdfulator_features)) {
    meta.pdfulator_features = meta.pdfulator_features.join(' ');
  }

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
function linkTags(payload) {
  const href = p => '/payload/' + path.relative(payload, p).split(path.sep).join('/');
  const link = h => `  <link rel="stylesheet" href="${escapeAttr(h)}">`;

  const out = [];

  // Fonts first and unconditionally: it is generated at the payload root, it
  // declares @font-face and the --pdfulator-<role> properties, and every sheet
  // below may refer to them.
  if (fs.existsSync(path.join(payload, 'fonts.css'))) out.push(link('/payload/fonts.css'));

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


function buildHtml(mdSource, inputBase, payloadDir, extraCss) {
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
  if (!meta.pdfulator_features) {
    const themeFeatures = features(payloadDir);
    if (themeFeatures) meta.pdfulator_features = themeFeatures;
  }

  const parser = parserFor(meta.pdfulator_features || '');
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
    stylesheets: linkTags(payloadDir),
    pdfulator_features: meta.pdfulator_features || '',
  };

  return Mustache.render(tmpl, ctx);
}


// HTML → PDF via puppeteer-core + Vivliostyle viewer


// Vivliostyle viewer is bundled alongside this script
const VIEWER_DIR = path.join(SCRIPT_DIR, 'node_modules', '@vivliostyle', 'viewer', 'lib');

// docRoot is the directory the SOURCE document came from, not the temporary
// directory the generated HTML lives in. That distinction is the whole of the
// relative-asset fix: `![](fig.png)` becomes `<img src="fig.png">`, the browser
// resolves it against the page's own URL under /doc/, and the file it wants is
// beside the markdown -- never in the temp directory, which holds exactly one
// generated .html and nothing else.
//
// Reachable in both vivlio engines, for different reasons: the bundled one
// reads the user's filesystem directly, and the containerised one gets the
// document's directory bind-mounted at /in (see lib/container.sh, which mounts
// dirname(input) for precisely this reason). A remote engine would have neither
// and needs assets discovered and staged instead -- see DIALECT.md.
//
// The generated HTML is served beside them at /doc/, from memory rather than
// from disk: writing it into the document's directory would mean staging
// writing to the user's source tree, and /in is read-only in any case.
async function htmlToPdf(htmlPath, pdfPath, chromiumPath, payloadDir, docRoot, verbose) {
  const serveRoot = docRoot;
  const htmlFilename = path.basename(htmlPath);
  const htmlBody = fs.readFileSync(htmlPath);

  // Find a free port
  const port = await new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
    s.on('error', reject);
  });

  // One server, muxed by path prefix: the viewer at /vivliostyle/, the document
  // and its assets at /doc/, the payload at /payload/.
  const muxServer = createServer((req, res) => {
    let filePath;
    const url = decodeURIComponent(req.url.split('?')[0]);

    // The generated page is the one thing under /doc/ that is not on disk
    // there. Answered from memory so the document's directory stays untouched
    // and read-only.
    if (url === `/doc/${htmlFilename}`) {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(htmlBody);
      return;
    }

    if (url.startsWith('/vivliostyle/')) {
      filePath = path.join(VIEWER_DIR, url.slice('/vivliostyle/'.length));
    } else if (url.startsWith('/doc/')) {
      filePath = path.join(serveRoot, url.slice('/doc/'.length));
    } else if (url.startsWith('/payload/')) {
      filePath = path.join(payloadDir, url.slice('/payload/'.length));
    } else {
      res.writeHead(404); res.end(''); return;
    }

    fs.readFile(filePath, (err, data) => {
      if (err) { res.writeHead(404); res.end(''); return; }
      const ext = path.extname(filePath).slice(1).toLowerCase();
      const mime = {
        html: 'text/html', css: 'text/css', js: 'application/javascript',
        json: 'application/json', otf: 'font/otf', ttf: 'font/ttf',
        woff: 'font/woff', woff2: 'font/woff2', svg: 'image/svg+xml',
        png: 'image/png', jpg: 'image/jpeg',
      }[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': mime });
      res.end(data);
    });
  });

  await new Promise((resolve, reject) => {
    muxServer.listen(port, '127.0.0.1', resolve);
    muxServer.on('error', reject);
  });

  // src is relative to the viewer base (/vivliostyle/); encode only the filename
  const viewerUrl = `http://127.0.0.1:${port}/vivliostyle/index.html` +
    `#src=../doc/${encodeURIComponent(htmlFilename)}&renderAllPages=true&spread=false`;

  if (verbose) console.error(`Launching Chromium: ${chromiumPath}`);
  if (verbose) console.error(`Viewer URL: ${viewerUrl}`);

  const browser = await puppeteer.launch({
    executablePath: chromiumPath,
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
    ],
  });

  try {
    const page = await browser.newPage();

    if (verbose) {
      page.on('console', msg => { if (msg.type() !== 'debug') console.error(`[browser] ${msg.type()}: ${msg.text()}`); });
      page.on('pageerror', err => console.error(`[browser error] ${err.message}`));
      page.on('requestfailed', req => console.error(`[fetch failed] ${req.url()} — ${req.failure()?.errorText}`));
      page.on('response', resp => { if (resp.status() >= 400) console.error(`[HTTP ${resp.status()}] ${resp.url()}`); });
    }

    await page.goto(viewerUrl, { waitUntil: 'domcontentloaded', timeout: 60000 });

    // Snapshot status after load
    if (verbose) {
      const statusNow = await page.evaluate(() => {
        const el = document.querySelector('[data-vivliostyle-viewer-status]');
        return el ? el.getAttribute('data-vivliostyle-viewer-status') : '(not found)';
      });
      console.error(`Viewer status after domcontentloaded: ${statusNow}`);
    }

    // Wait for Vivliostyle to finish rendering.
    // It sets data-vivliostyle-viewer-status="complete" on the viewport element.
    await page.waitForFunction(
      () => {
        const el = document.querySelector('[data-vivliostyle-viewer-status]');
        if (!el) return false;
        const s = el.getAttribute('data-vivliostyle-viewer-status');
        return s === 'complete' || s === 'ready';
      },
      { timeout: 120000, polling: 500 }
    );

    if (verbose) {
      const status = await page.evaluate(() => {
        const el = document.querySelector('[data-vivliostyle-viewer-status]');
        return el ? el.getAttribute('data-vivliostyle-viewer-status') : '(not found)';
      });
      console.error(`Viewer status after render: ${status}`);
    }
    if (verbose) console.error('Rendering complete, generating PDF...');

    const pdfBuffer = await page.pdf({
      printBackground: true,
      preferCSSPageSize: true,
    });

    fs.writeFileSync(pdfPath, pdfBuffer);
  } finally {
    await browser.close();
    muxServer.close();
  }
}


// The engine contract
//
// Reading and writing are separated from converting so that the four
// combinations of file/stdin and file/stdout are one code path rather than
// four. The v2 script had processFile and processStdin doing much the same
// work twice over, which is how they came to differ: only one of them had the
// up-to-date check, and only one wrote atomically.

async function readInput(input) {
  if (input !== '-') return fs.readFileSync(input, 'utf8');

  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => data += chunk);
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}


// Convert one document.
//
// `inputBase` is what loadSidecar looks beside for a .yaml, so it has to be
// the input's own path minus its extension -- and for stdin there is no such
// path, hence no sidecar. That is not a gap: a sidecar is a file named after
// another file, and a stream has no name.
async function convert(input, output, payloadDir, opts) {
  const mdSource = await readInput(input);

  // Empty stdin is an error; an empty *file* is not.
  //
  // The asymmetry is deliberate and predates this refactor. Nothing on stdin
  // means the pipe feeding us produced nothing, which is a failure worth
  // reporting -- writing a blank PDF would hide it. An empty file, by
  // contrast, is a document someone has started and not yet written, and
  // `pdfulator .` over a directory containing one should render it blank
  // rather than abort the whole batch. tests/argmatrix.sh has an empty.md
  // fixture for exactly this case.
  if (input === '-' && !mdSource.trim()) {
    console.error('Error: empty input on stdin');
    process.exit(1);
  }

  const leaf = input === '-' ? 'stdin' : path.basename(input).replace(/\.[^.]+$/, '');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `pdfulator-${leaf}-`));
  const htmlPath = path.join(tmpDir, `${leaf}.html`);

  // stdin has no sidecar to find; a file's sits beside it.
  const inputBase = input === '-'
    ? path.join(tmpDir, 'stdin')
    : input.replace(/\.[^.]+$/, '');

  try {
    fs.writeFileSync(htmlPath, buildHtml(mdSource, inputBase, payloadDir, null));

    // Render to a temporary PDF and move it into place, so an interrupted run
    // cannot leave a half-written file that still looks like a PDF. stdout
    // gets the bytes instead, there being nothing to move.
    const tmpPdf = path.join(tmpDir, `${leaf}.pdf`);
    // Relative references resolve against the document, so the directory the
    // document came from is what gets served -- not the temp directory holding
    // the generated HTML, which is where this used to point and why every
    // `![](fig.png)` rendered as a broken image. stdin has no directory of its
    // own; the temp directory is the honest answer there, and a piped document
    // referencing a relative asset has nothing for that path to mean anyway.
    const docRoot = input === '-' ? tmpDir : path.dirname(path.resolve(input));

    await htmlToPdf(htmlPath, tmpPdf, process.env.CHROME_PATH, payloadDir, docRoot, opts.verbose);

    if (output === '-') {
      process.stdout.write(fs.readFileSync(tmpPdf));
    } else {
      fs.mkdirSync(path.dirname(output), { recursive: true });

      // rename(2) cannot cross filesystems, and the temporary directory is in
      // $TMPDIR while the output is wherever the user asked for -- commonly a
      // different one. In a container that is the normal case rather than an
      // unlucky one: the output directory is a bind mount, so every write to
      // it crosses a device boundary and the rename fails with EXDEV, having
      // rendered the document perfectly.
      //
      // Copy-then-unlink is the fallback rather than the default because the
      // rename is what makes the write atomic: a reader never sees a partial
      // PDF. Copying gives that up, so it is used only where rename cannot
      // work at all.
      try {
        fs.renameSync(tmpPdf, output);
      } catch (err) {
        if (err.code !== 'EXDEV') throw err;
        fs.copyFileSync(tmpPdf, output);
        fs.unlinkSync(tmpPdf);
      }
      if (opts.verbose) console.error(`Written: ${output}`);
    }
  } finally {
    if (!opts.debug) fs.rmSync(tmpDir, { recursive: true, force: true });
    else console.error(`Debug: kept ${tmpDir}`);
  }
}


async function main() {
  const argv = process.argv.slice(2);
  const opts = {
    verbose: !!process.env.PDFULATOR_VERBOSE,
    debug: !!process.env.PDFULATOR_DEBUG,
  };

  // Positional and fixed. The wrapper is the only caller, and it always passes
  // all three, so anything else is a bug in the wrapper rather than a user
  // mistake -- and is reported as such, since the user cannot act on it.
  const [input, output, payloadDir] = argv;

  if (argv.length !== 3) {
    console.error('vivlio: usage: main.js <input|-> <output|-> <payload-dir>');
    console.error('(this is the engine contract; run pdfulator instead)');
    process.exit(2);
  }

  // The wrapper resolves the browser and passes it in the environment. An
  // engine never goes looking for one: that would be the search-and-launch
  // this project deliberately doesn't do.
  if (!process.env.CHROME_PATH) {
    console.error('vivlio: no browser given (CHROME_PATH unset).');
    console.error('Run `pdfulator --browser auto`, or --browser install.');
    process.exit(1);
  }

  if (!fs.existsSync(payloadDir)) {
    console.error(`vivlio: payload directory not found: ${payloadDir}`);
    process.exit(1);
  }

  await convert(input, output, payloadDir, opts);
}

main().catch(err => {
  console.error(`vivlio: ${err && err.message ? err.message : err}`);
  if (process.env.PDFULATOR_DEBUG) console.error(err);
  process.exit(1);
});
