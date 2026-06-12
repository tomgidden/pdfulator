#!/usr/bin/env bun
// pdfulator.js — Markdown to PDF converter
//
// Modes:
//   pdfulator [options] input.md [output.pdf]
//   pdfulator [options] -              # stdin → stdout
//   pdfulator [options] dir/           # convert all *.md in directory
//   pdfulator --watch [options] dir/   # watch mode
//
// Options:
//   -t, --theme <name|path>   theme name (resolved below) or path to theme dir
//   -d, --debug               keep intermediate HTML file
//   -v, --verbose             verbose output
//   -w, --watch               watch for changes (directory mode only)
//   -h, --help                show help
//
// Theme resolution order:
//   1. Absolute/relative path supplied with --theme
//   2. <cwd>/themes/<name>/
//   3. ~/.local/share/pdfulator/themes/<name>/
//   4. <script-dir>/themes/<name>/        (sibling of pdfulator.js)
//   5. <script-dir>/theme/                (built-in default theme)

import fs from 'fs';
import path from 'path';
import os from 'os';
import { execSync, spawn } from 'child_process';
import { createServer } from 'http';
import { fileURLToPath } from 'url';


// Dependencies — installed alongside this script or in node_modules

import MarkdownIt from 'markdown-it';
import mdDeflist from 'markdown-it-deflist';
import mdTaskLists from 'markdown-it-task-lists';
import yaml from 'js-yaml';
import Mustache from 'mustache';
import puppeteer from 'puppeteer-core';


// Paths

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULTS_DIR = path.join(SCRIPT_DIR, 'defaults');


// CLI argument parsing

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    theme: null,
    debug: false,
    verbose: false,
    watch: false,
    help: false,
    inputs: [],
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-h' || a === '--help')          { opts.help = true; }
    else if (a === '-d' || a === '--debug')    { opts.debug = true; }
    else if (a === '-v' || a === '--verbose')  { opts.verbose = true; }
    else if (a === '-w' || a === '--watch')    { opts.watch = true; }
    else if (a === '-t' || a === '--theme')    { opts.theme = args[++i]; }
    else if (a.startsWith('--theme='))         { opts.theme = a.slice(8); }
    else                                        { opts.inputs.push(a); }
  }

  return opts;
}

function showHelp() {
  console.log(`\
pdfulator — Markdown to PDF converter

Usage:
  pdfulator [options] input.md [output.pdf]
  pdfulator [options] -                      stdin → stdout
  pdfulator [options] dir/                   convert all *.md in directory
  pdfulator --watch [options] dir/           watch mode

Options:
  -t, --theme <name|path>   theme to use
  -d, --debug               keep intermediate files
  -v, --verbose             verbose output
  -w, --watch               watch for changes (directory mode)
  -h, --help                show this help

Theme resolution:
  1. Path supplied to --theme (absolute or relative to cwd)
  2. <cwd>/themes/<name>/
  3. ~/.local/share/pdfulator/themes/<name>/
  4. <pdfulator-dir>/themes/<name>/
  5. Built-in default theme
`);
}


// Theme resolution

function resolveTheme(name) {
  if (!name) {
    return path.join(SCRIPT_DIR, 'theme');
  }

  // Absolute or explicit relative path
  if (path.isAbsolute(name) || name.startsWith('./') || name.startsWith('../')) {
    return name;
  }

  const candidates = [
    path.join(process.cwd(), 'themes', name),
    path.join(os.homedir(), '.local', 'share', 'pdfulator', 'themes', name),
    path.join(SCRIPT_DIR, 'themes', name),
    path.join(SCRIPT_DIR, 'theme'),
  ];

  for (const c of candidates) {
    if (fs.existsSync(c) && fs.statSync(c).isDirectory()) return c;
  }

  console.error(`Warning: theme "${name}" not found, using built-in default`);
  return path.join(SCRIPT_DIR, 'theme');
}


// Chromium detection

const CHROMIUM_CANDIDATES = [
  // macOS — system and user Applications
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  `${os.homedir()}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
  `${os.homedir()}/Applications/Chromium.app/Contents/MacOS/Chromium`,
  `${os.homedir()}/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`,
  // Linux
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/brave-browser',
  '/usr/bin/microsoft-edge',
  '/snap/bin/chromium',
];

function findChromium() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;

  for (const p of CHROMIUM_CANDIDATES) {
    if (fs.existsSync(p)) return p;
  }

  // Try which/where as a fallback
  for (const name of ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable']) {
    try {
      const found = execSync(`which ${name} 2>/dev/null`, { encoding: 'utf8' }).trim();
      if (found) return found;
    } catch { /* not found */ }
  }

  return null;
}


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


// File processing

async function processFile(inputPath, outputPath, opts, themeDir, chromiumPath) {
  const inputBase = inputPath.replace(/\.[^.]+$/, '');
  const leaf = path.basename(inputBase);

  // Skip non-markdown
  if (!/\.(md|markdown)$/i.test(inputPath)) return;

  // Skip if output is up to date
  if (!opts.debug && fs.existsSync(outputPath)) {
    const inStat = fs.statSync(inputPath);
    const outStat = fs.statSync(outputPath);
    if (inStat.mtimeMs < outStat.mtimeMs) {
      if (opts.verbose) console.error(`Skipping ${inputPath} (unchanged)`);
      return;
    }
  }

  if (opts.verbose) console.error(`Processing ${inputPath}...`);

  const mdSource = fs.readFileSync(inputPath, 'utf8');
  const html = buildHtml(mdSource, inputBase, themeDir, null);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `pdfulator-${leaf}-`));
  const htmlPath = path.join(tmpDir, `${leaf}.html`);

  try {
    fs.writeFileSync(htmlPath, html);
    await htmlToPdf(htmlPath, outputPath, chromiumPath, themeDir, opts.verbose);
    if (opts.verbose) console.error(`Written: ${outputPath}`);
  } finally {
    if (!opts.debug) fs.rmSync(tmpDir, { recursive: true, force: true });
    else if (opts.verbose) console.error(`Debug: kept ${tmpDir}`);
  }
}

async function processStdin(opts, themeDir, chromiumPath) {
  const mdSource = await new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => data += chunk);
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });

  if (!mdSource.trim()) {
    console.error('Error: empty input on stdin');
    process.exit(1);
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pdfulator-stdin-'));
  const htmlPath = path.join(tmpDir, 'stdin.html');
  const pdfPath = path.join(tmpDir, 'stdin.pdf');

  try {
    const html = buildHtml(mdSource, path.join(tmpDir, 'stdin'), themeDir, null);
    fs.writeFileSync(htmlPath, html);
    await htmlToPdf(htmlPath, pdfPath, chromiumPath, themeDir, opts.verbose);
    const pdfData = fs.readFileSync(pdfPath);
    process.stdout.write(pdfData);
  } finally {
    if (!opts.debug) fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}


// Watch mode (macOS + Linux)

function watchDir(dir, callback) {
  // Use fs.watch for portability (works on macOS and Linux without inotifywait)
  fs.watch(dir, { persistent: true }, (event, filename) => {
    if (filename && /\.(md|markdown|ya?ml)$/i.test(filename)) {
      callback(path.join(dir, filename));
    }
  });
}


// Main

async function main() {
  const opts = parseArgs(process.argv);

  if (opts.help) { showHelp(); process.exit(0); }

  const themeDir = resolveTheme(opts.theme);
  if (opts.verbose) console.error(`Theme: ${themeDir}`);

  // Chromium check
  const chromiumPath = findChromium();
  if (!chromiumPath) {
    console.error(`\
Error: no Chromium-based browser found.

Install one of:
  macOS:  brew install --cask google-chrome
          brew install --cask chromium
  Linux:  sudo apt install chromium   (or chromium-browser, google-chrome-stable)

Or set CHROME_PATH=/path/to/chrome
`);
    process.exit(1);
  }
  if (opts.verbose) console.error(`Chromium: ${chromiumPath}`);

  // stdin mode
  if (opts.inputs.includes('-')) {
    await processStdin(opts, themeDir, chromiumPath);
    return;
  }

  // No inputs → process cwd
  if (opts.inputs.length === 0) {
    opts.inputs.push(process.cwd());
  }

  const tasks = [];

  for (const input of opts.inputs) {
    const resolved = path.resolve(input);

    if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) {
      const files = fs.readdirSync(resolved)
        .filter(f => /\.(md|markdown)$/i.test(f))
        .map(f => path.join(resolved, f));

      for (const f of files) {
        const out = f.replace(/\.(md|markdown)$/i, '.pdf');
        tasks.push(() => processFile(f, out, opts, themeDir, chromiumPath));
      }

      if (opts.watch) {
        // Process immediately then watch
        await Promise.all(tasks.map(t => t()));
        console.error(`Watching ${resolved} for changes...`);
        watchDir(resolved, async changedPath => {
          if (/\.(md|markdown)$/i.test(changedPath)) {
            const out = changedPath.replace(/\.(md|markdown)$/i, '.pdf');
            try { await processFile(changedPath, out, opts, themeDir, chromiumPath); }
            catch (e) { console.error(`Error processing ${changedPath}: ${e.message}`); }
          }
        });
        return; // keep process alive
      }

    } else if (/\.(md|markdown)$/i.test(resolved)) {
      // Explicit file: optional second positional arg is output path
      const outArg = opts.inputs[opts.inputs.indexOf(input) + 1];
      const out = (outArg && /\.pdf$/i.test(outArg))
        ? path.resolve(outArg)
        : resolved.replace(/\.(md|markdown)$/i, '.pdf');
      tasks.push(() => processFile(resolved, out, opts, themeDir, chromiumPath));

    } else if (/\.pdf$/i.test(resolved)) {
      // This is an output path argument already consumed above — skip
      continue;

    } else {
      console.error(`Error: not found or unrecognised: ${input}`);
      process.exit(1);
    }
  }

  await Promise.all(tasks.map(t => t()));
}

main().catch(e => {
  console.error(`Fatal: ${e.message}`);
  if (process.env.DEBUG) console.error(e.stack);
  process.exit(1);
});
