#!/usr/bin/env bun
// engines/vivlio/main.js — the vivlio engine's converter.
//
//   main.js <input|-> <output|-> <theme-dir>
//
// One document in, one document out. Everything else -- which files to
// convert, where the output goes, whether it may be overwritten, which theme
// that directory name came from, which browser to drive -- was decided by the
// wrapper before this ran, and arrives as three arguments and $CHROME_PATH.
//
// This is what remains of the v2 pdfulator.js after the common layer took the
// rest. The pipeline is unchanged, and deliberately so: markdown-it for the
// markdown, Mustache over the theme's article.tmpl for the page, then the
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
import yaml from 'js-yaml';
import Mustache from 'mustache';
import puppeteer from 'puppeteer-core';


// Paths
//
// $PDFULATOR_DEFAULTS lets the wrapper point at shared assets that live above
// the engine directory, since defaults/ is not the engine's to own -- every
// engine renders the same document. It falls back to a sibling directory so
// that running main.js straight from a checkout works.

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULTS_DIR = process.env.PDFULATOR_DEFAULTS
  || path.join(SCRIPT_DIR, '..', '..', 'defaults');

// Markdown → HTML

const md = new MarkdownIt({ html: true, linkify: true, typographer: false })
  .use(mdDeflist)
  .use(mdTaskLists, { enabled: true });

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


function buildHtml(mdSource, inputBase, themeDir, extraCss) {
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

  // Theme config can set default pdfulator_features
  const themeConfigPath = path.join(themeDir, 'theme.yaml');
  if (!meta.pdfulator_features && fs.existsSync(themeConfigPath)) {
    try {
      const tc = yaml.load(fs.readFileSync(themeConfigPath, 'utf8')) || {};
      if (tc.pdfulator_features) {
        meta.pdfulator_features = Array.isArray(tc.pdfulator_features)
          ? tc.pdfulator_features.join(' ')
          : tc.pdfulator_features;
      }
    } catch { /* ignore */ }
  }

  const renderedBody = md.render(body);

  // Load template: theme overrides default
  const tmplPath = fs.existsSync(path.join(themeDir, 'article.tmpl'))
    ? path.join(themeDir, 'article.tmpl')
    : path.join(DEFAULTS_DIR, 'article.tmpl');

  const tmpl = fs.readFileSync(tmplPath, 'utf8');

  // Render inline markdown in title/subtitle (e.g. _pdfulator_ → <em>pdfulator</em>)
  const mdInline = s => s ? md.renderInline(String(s)) : '';

  const ctx = {
    ...meta,
    body: renderedBody,
    title: mdInline(meta.title || ''),
    subtitle: mdInline(meta.subtitle || ''),
    authors: normaliseAuthors(meta.authors || meta.author),
    date: formatDate(meta.date),
    css: extraCss || meta.css || '',
    pdfulator_features: meta.pdfulator_features || '',
  };

  return Mustache.render(tmpl, ctx);
}


// HTML → PDF via puppeteer-core + Vivliostyle viewer


// Vivliostyle viewer is bundled alongside this script
const VIEWER_DIR = path.join(SCRIPT_DIR, 'node_modules', '@vivliostyle', 'viewer', 'lib');

function serveDir(dir, port) {
  const server = createServer((req, res) => {
    const filePath = path.join(dir, decodeURIComponent(req.url.split('?')[0]));
    fs.readFile(filePath, (err, data) => {
      if (err) { res.writeHead(404); res.end(); return; }
      const ext = path.extname(filePath).slice(1);
      const mime = {
        html: 'text/html', css: 'text/css', js: 'application/javascript',
        json: 'application/json', pdf: 'application/pdf',
        otf: 'font/otf', ttf: 'font/ttf', woff: 'font/woff', woff2: 'font/woff2',
        svg: 'image/svg+xml', png: 'image/png', jpg: 'image/jpeg',
      }[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': mime });
      res.end(data);
    });
  });
  return new Promise((resolve, reject) => {
    server.listen(port, '127.0.0.1', () => resolve(server));
    server.on('error', reject);
  });
}

async function htmlToPdf(htmlPath, pdfPath, chromiumPath, themeDir, verbose) {
  // Serve from the tmp dir containing the HTML (so relative CSS/font paths work)
  const serveRoot = path.dirname(htmlPath);
  const htmlFilename = path.basename(htmlPath);

  // Find a free port
  const port = await new Promise((resolve, reject) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
    s.on('error', reject);
  });

  const docServer = await serveDir(serveRoot, port);

  // Also serve defaults and theme from the same origin via symlinks would be messy;
  // instead serve from filesystem root so absolute paths work.
  // Vivliostyle viewer needs to be reachable too — serve it at /vivliostyle/
  // We use a single server that muxes by path prefix.
  docServer.close();

  const muxServer = createServer((req, res) => {
    let filePath;
    const url = decodeURIComponent(req.url.split('?')[0]);

    if (url.startsWith('/vivliostyle/')) {
      filePath = path.join(VIEWER_DIR, url.slice('/vivliostyle/'.length));
    } else if (url.startsWith('/doc/')) {
      filePath = path.join(serveRoot, url.slice('/doc/'.length));
    } else if (url.startsWith('/defaults/')) {
      filePath = path.join(DEFAULTS_DIR, url.slice('/defaults/'.length));
    } else if (url.startsWith('/theme/')) {
      filePath = path.join(themeDir, url.slice('/theme/'.length));
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
async function convert(input, output, themeDir, opts) {
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
    fs.writeFileSync(htmlPath, buildHtml(mdSource, inputBase, themeDir, null));

    // Render to a temporary PDF and move it into place, so an interrupted run
    // cannot leave a half-written file that still looks like a PDF. stdout
    // gets the bytes instead, there being nothing to move.
    const tmpPdf = path.join(tmpDir, `${leaf}.pdf`);
    await htmlToPdf(htmlPath, tmpPdf, process.env.CHROME_PATH, themeDir, opts.verbose);

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
  const [input, output, themeDir] = argv;

  if (argv.length !== 3) {
    console.error('vivlio: usage: main.js <input|-> <output|-> <theme-dir>');
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

  if (!fs.existsSync(themeDir)) {
    console.error(`vivlio: theme directory not found: ${themeDir}`);
    process.exit(1);
  }

  await convert(input, output, themeDir, opts);
}

main().catch(err => {
  console.error(`vivlio: ${err && err.message ? err.message : err}`);
  if (process.env.PDFULATOR_DEBUG) console.error(err);
  process.exit(1);
});
