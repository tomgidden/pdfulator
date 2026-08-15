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
    installBrowser: false,
    listBrowsers: false,
    inputs: [],
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-h' || a === '--help')          { opts.help = true; }
    else if (a === '-d' || a === '--debug')    { opts.debug = true; }
    else if (a === '-v' || a === '--verbose')  { opts.verbose = true; }
    else if (a === '-w' || a === '--watch')    { opts.watch = true; }
    else if (a === '--install-browser')        { opts.installBrowser = true; }
    else if (a === '--list-browsers')          { opts.listBrowsers = true; }
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
  pdfulator [options] input.md [output.pdf]  convert one file
  pdfulator [options] dir/ [outdir/]         convert every *.md in a directory
  pdfulator [options] -                      stdin → stdout
  pdfulator --watch [options] dir/ [outdir/] watch mode

Options:
  -t, --theme <name|path>   theme to use
  -d, --debug               keep intermediate files
  -v, --verbose             verbose output
  -w, --watch               watch for changes (directory mode)
      --list-browsers       list Chromium-based browsers found here
      --install-browser     download a private Chromium for pdfulator's use
  -h, --help                show this help

The browser to render with is never chosen automatically: set CHROME_PATH, or
use the bundled pdfulator's --browser auto|find|install|<path>.

Theme resolution:
  1. Path supplied to --theme (absolute or relative to cwd)
  2. <cwd>/themes/<name>/
  3. ~/.local/share/pdfulator/themes/<name>/
  4. <pdfulator-dir>/themes/<name>/
  5. Built-in default theme
`);
}


// Theme resolution

const BUILTIN_THEME = path.join(SCRIPT_DIR, 'theme');

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

// A named theme is looked for in the working directory, then the user's
// installation, then alongside the script. A path is taken as given.
//
// Not finding one is an error, not a fallback. Quietly rendering with the
// default theme means a typo produces a plausible-looking PDF in the wrong
// style -- the kind of mistake you only catch by eye, after sending it.
function resolveTheme(name) {
  if (!name) return BUILTIN_THEME;

  // Absolute or explicit relative path: the user has told us exactly where.
  if (path.isAbsolute(name) || name.startsWith('./') || name.startsWith('../')) {
    if (!isDir(name)) {
      console.error(`Error: theme directory not found: ${name}`);
      process.exit(1);
    }
    return name;
  }

  // $PDFULATOR_HOME rather than a hardcoded ~/.local/share/pdfulator, so a
  // relocated install finds its own themes.
  const home = process.env.PDFULATOR_HOME
    || path.join(os.homedir(), '.local', 'share', 'pdfulator');

  // Deduplicated: cwd and SCRIPT_DIR coincide when running from a checkout,
  // and listing the same path twice in the error below reads like a bug.
  const candidates = [...new Set([
    path.join(process.cwd(), 'themes', name),
    path.join(home, 'themes', name),
    path.join(SCRIPT_DIR, 'themes', name),
  ])];

  for (const c of candidates) {
    if (isDir(c)) return c;
  }

  // Deliberately not falling back to BUILTIN_THEME: it exists unconditionally,
  // so including it above would make this unreachable.
  console.error(`Error: no theme named "${name}".`);
  console.error('Looked in:');
  for (const c of candidates) console.error(`  ${c}`);
  process.exit(1);
}


// Chromium detection

const HOME = os.homedir();

// Per-platform lists, most-preferred first. Only the current platform's list is
// consulted, so a name that means different things on different systems (say
// `chrome` on Windows vs a stray script on Linux) can't leak across.
const CHROMIUM_CANDIDATES_BY_PLATFORM = {
  darwin: [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary',
    '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
    `${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
    `${HOME}/Applications/Chromium.app/Contents/MacOS/Chromium`,
    `${HOME}/Applications/Brave Browser.app/Contents/MacOS/Brave Browser`,
    `${HOME}/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`,
  ],

  linux: [
    // Distro packages
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/brave-browser',
    '/usr/bin/microsoft-edge',
    '/usr/bin/microsoft-edge-stable',
    '/usr/bin/vivaldi-stable',
    // Locally installed / vendor tarballs
    '/usr/local/bin/chromium',
    '/usr/local/bin/google-chrome',
    '/opt/google/chrome/chrome',
    '/opt/microsoft/msedge/msedge',
    '/opt/brave.com/brave/brave-browser',
    // Snap
    '/snap/bin/chromium',
    '/snap/bin/google-chrome',
    '/snap/bin/brave',
    // Flatpak — the wrapper binaries inside the runtime tree. Launching these
    // directly (rather than via `flatpak run`) keeps puppeteer's --flags and
    // stdio behaviour intact; the sandbox still applies.
    '/var/lib/flatpak/app/com.google.Chrome/current/active/files/chrome/chrome',
    '/var/lib/flatpak/app/org.chromium.Chromium/current/active/files/chromium/chromium',
    '/var/lib/flatpak/app/com.brave.Browser/current/active/files/brave/brave',
    `${HOME}/.local/share/flatpak/app/com.google.Chrome/current/active/files/chrome/chrome`,
    `${HOME}/.local/share/flatpak/app/org.chromium.Chromium/current/active/files/chromium/chromium`,
  ],

  win32: [
    // %LOCALAPPDATA% first: per-user installs are the common case and don't
    // need admin rights, so they're what a desktop user most likely has.
    ...(process.env.LOCALAPPDATA
      ? [
          `${process.env.LOCALAPPDATA}\\Google\\Chrome\\Application\\chrome.exe`,
          `${process.env.LOCALAPPDATA}\\Chromium\\Application\\chrome.exe`,
          `${process.env.LOCALAPPDATA}\\Microsoft\\Edge\\Application\\msedge.exe`,
          `${process.env.LOCALAPPDATA}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`,
        ]
      : []),
    ...(process.env.PROGRAMFILES
      ? [
          `${process.env.PROGRAMFILES}\\Google\\Chrome\\Application\\chrome.exe`,
          `${process.env.PROGRAMFILES}\\Microsoft\\Edge\\Application\\msedge.exe`,
          `${process.env.PROGRAMFILES}\\BraveSoftware\\Brave-Browser\\Application\\brave.exe`,
        ]
      : []),
    ...(process.env['PROGRAMFILES(X86)']
      ? [
          `${process.env['PROGRAMFILES(X86)']}\\Google\\Chrome\\Application\\chrome.exe`,
          `${process.env['PROGRAMFILES(X86)']}\\Microsoft\\Edge\\Application\\msedge.exe`,
        ]
      : []),
  ],
};

// Names to look for on $PATH when no known location matched.
const CHROMIUM_PATH_NAMES = process.platform === 'win32'
  ? ['chrome.exe', 'msedge.exe', 'chromium.exe']
  : [
      'chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable',
      'brave-browser', 'microsoft-edge', 'vivaldi-stable',
    ];

// Every browser we can find, best-guess first. Detection only ever *offers*
// candidates -- choosing one is the user's call, made once via --browser and
// pinned thereafter. Nothing here is launched as a side effect of searching.
function listChromiumCandidates() {
  const found = [];
  const seen = new Set();
  const add = (p, source) => {
    if (!p || seen.has(p)) return;
    seen.add(p);
    found.push({ path: p, source });
  };

  const managed = findManagedBrowser();
  if (managed) add(managed, 'installed by pdfulator');

  for (const p of CHROMIUM_CANDIDATES_BY_PLATFORM[process.platform] || []) {
    if (fs.existsSync(p)) add(p, 'system');
  }

  // $PATH last: it's the least predictable source, since anything named
  // `chromium` anywhere on the path will match.
  const lookup = process.platform === 'win32' ? 'where' : 'which';
  for (const name of CHROMIUM_PATH_NAMES) {
    try {
      const out = execSync(`${lookup} ${name}`, {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      });
      for (const line of out.split(/\r?\n/)) {
        const p = line.trim();
        if (p && fs.existsSync(p)) add(fs.realpathSync(p), 'on PATH');
      }
    } catch { /* not found */ }
  }

  return found;
}

// The browser to actually use. Only ever an explicit choice: $CHROME_PATH from
// the caller, or the path the wrapper pinned. No implicit search.
function resolveChromium() {
  return process.env.CHROME_PATH || null;
}

// Shown when nothing is pinned yet. This is setup guidance, not a failure --
// it's the expected first-run state -- so it reads as instructions. It still
// goes to stderr, both because stdout may be a PDF and because the exit is
// non-zero: no document was produced.
function setupMessage() {
  // In the Docker image the browser is baked in and CHROME_PATH is set at build
  // time, so there is no choice to make -- if we got here, the image is broken.
  // Listing the user's browsers would be noise: they aren't in the container.
  if (fs.existsSync('/.dockerenv')) {
    return `\
Error: no browser in this container.

The pdfulator image installs Chromium and sets CHROME_PATH at build time, so
this means the image is broken or CHROME_PATH has been overridden. Rebuild it,
or run with -e CHROME_PATH=/usr/bin/chromium.`;
  }

  const candidates = listChromiumCandidates();
  const flatpak = candidates.length === 0 ? findFlatpakBrowser() : null;

  // Only the bundled wrapper implements --browser and can pin a choice. Run
  // any other way -- in the Docker image, or straight from a checkout -- the
  // equivalent is CHROME_PATH. Advertise whichever the user can actually use.
  const bundled = !!process.env.PDFULATOR_BUNDLED;

  const lines = [
    'pdfulator needs a browser to render PDFs, and none is chosen yet.',
    '',
    'It uses Chrome, Chromium, Brave, Edge or Vivaldi -- the PDF is produced by',
    "Chromium's own print engine, which Firefox and Safari have no equivalent for.",
    '',
    'Choose one, once:',
    '',
  ];

  if (bundled) {
    if (candidates.length > 0) {
      lines.push(`  pdfulator --browser auto        use ${candidates[0].path}`);
      lines.push('  pdfulator --browser find        list every browser found here');
    }
    if (cftPlatform()) {
      // Offered only where a Chrome for Testing build exists; there is no
      // linux-arm64, and promising it there would be a dead end.
      lines.push('  pdfulator --browser install     download a private copy (~96MB)');
    }
    lines.push(
      `  pdfulator --browser ${process.platform === 'win32' ? 'C:\\path\\to\\chrome.exe' : '/path/to/chrome'}   use a specific one`,
    );
  } else {
    // Running pdfulator.js directly: no pin file, so the choice is an env var.
    const set = process.platform === 'win32' ? 'set CHROME_PATH=' : 'export CHROME_PATH=';
    if (candidates.length > 0) {
      lines.push(`  ${set}"${candidates[0].path}"`);
      lines.push('  pdfulator --list-browsers       list every browser found here');
    }
    if (cftPlatform()) {
      lines.push('  pdfulator --install-browser     download a private copy (~96MB)');
    }
  }

  if (candidates.length > 0) {
    lines.push('', `Found ${candidates.length} browser${candidates.length === 1 ? '' : 's'} on this machine:`);
    for (const c of candidates.slice(0, 5)) {
      lines.push(`  ${c.path}  (${c.source})`);
    }
    if (candidates.length > 5) {
      lines.push(`  ...and ${candidates.length - 5} more (${bundled ? '--browser find' : '--list-browsers'})`);
    }
  } else if (flatpak) {
    const how = bundled
      ? `  pdfulator --browser /var/lib/flatpak/app/${flatpak}/current/active/files/chrome/chrome`
      : `  export CHROME_PATH=/var/lib/flatpak/app/${flatpak}/current/active/files/chrome/chrome`;
    lines.push(
      '',
      `The only browser here is the Flatpak ${flatpak}, which cannot be launched`,
      'directly. Point at the binary inside it, e.g.',
      how,
    );
  } else {
    const hint = {
      darwin: '  brew install --cask google-chrome',
      linux: `  sudo apt install chromium              (Debian/Ubuntu)
  sudo dnf install chromium              (Fedora/RHEL)
  sudo pacman -S chromium                (Arch)`,
      win32: '  winget install Google.Chrome',
    }[process.platform];
    if (hint) lines.push('', 'No browser found here. Install one system-wide:', hint);
  }

  lines.push('', bundled
    ? 'Your choice is remembered; --browser again to change it.'
    : 'Set CHROME_PATH in your shell profile to make this permanent.');
  return lines.join('\n');
}

// `--browser find` output: everything, with a ready-to-paste command per entry.
function listBrowsersMessage() {
  const candidates = listChromiumCandidates();
  if (candidates.length === 0) return setupMessage();

  const lines = ['Browsers found on this machine:', ''];
  for (const c of candidates) {
    lines.push(`  ${c.path}`);
    lines.push(`      ${c.source}`);
    lines.push(`      pdfulator --browser ${/\s/.test(c.path) ? `"${c.path}"` : c.path}`);
    lines.push('');
  }
  lines.push('Run one of the above to pin your choice.');
  return lines.join('\n');
}

// Puppeteer needs a real executable, so a Flatpak-only install can't be driven
// directly. Detecting one lets us give a useful hint instead of "not found".
function findFlatpakBrowser() {
  if (process.platform !== 'linux') return null;

  for (const app of ['com.google.Chrome', 'org.chromium.Chromium', 'com.brave.Browser']) {
    try {
      execSync(`flatpak info ${app}`, { stdio: 'ignore' });
      return app;
    } catch { /* not installed */ }
  }
  return null;
}


// Managed browser
//
// --install-browser fetches chrome-headless-shell into PDFULATOR_HOME/chromium
// via @puppeteer/browsers -- the same downloader puppeteer itself uses, so we
// inherit its platform detection, proxy support, mirror configuration and
// resumable downloads rather than maintaining our own.
//
// headless-shell rather than full Chrome: half the size (~193MB vs ~356MB
// unpacked) and, having no UI layer, exactly what a headless PDF pipeline
// needs. Verified to produce an identical text layer to full Chrome here.
//
// Never automatic -- downloading ~100MB is something the user should ask for.

const PDFULATOR_HOME =
  process.env.PDFULATOR_HOME || path.join(HOME, '.local', 'share', 'pdfulator');
const MANAGED_BROWSER_DIR = path.join(PDFULATOR_HOME, 'chromium');
const MANAGED_BROWSER = 'chrome-headless-shell';

// @puppeteer/browsers is a dependency of puppeteer-core, but we use it
// directly, so it's declared in package.json too. Imported lazily: it pulls in
// a sizeable tree that a normal conversion never needs.
async function puppeteerBrowsers() {
  return import('@puppeteer/browsers');
}

// Whether this platform has a chrome-headless-shell build at all. There is no
// linux-arm64 one, and offering a download that can't work is a dead end.
function browserDownloadSupported() {
  // Cheap structural check, matching @puppeteer/browsers' own platform matrix.
  if (process.platform === 'linux' && process.arch !== 'x64') return false;
  return ['darwin', 'linux', 'win32'].includes(process.platform);
}

// Kept for callers that want a yes/no without importing the browsers package.
const cftPlatform = () => (browserDownloadSupported() ? process.platform : null);

// An already-installed managed browser, if there is one.
function findManagedBrowser() {
  if (!fs.existsSync(MANAGED_BROWSER_DIR)) return null;

  try {
    // getInstalledBrowsers is async, so do the cheap synchronous thing here:
    // the cache layout is <cacheDir>/<browser>/<platform>-<buildId>/...
    const root = path.join(MANAGED_BROWSER_DIR, MANAGED_BROWSER);
    if (!fs.existsSync(root)) return null;

    const exeName = process.platform === 'win32'
      ? 'chrome-headless-shell.exe'
      : 'chrome-headless-shell';

    // Newest build first, so an upgrade takes effect without a manual clean.
    const builds = fs.readdirSync(root).sort().reverse();
    for (const b of builds) {
      const dir = path.join(root, b);
      const hit = findFileNamed(dir, exeName, 3);
      if (hit) return hit;
    }
  } catch { /* unreadable cache: treat as absent */ }

  return null;
}

// Small bounded search: the binary sits 1-3 levels below the build directory
// depending on platform (chrome-headless-shell-linux64/, ...mac-arm64/, etc).
function findFileNamed(dir, name, depth) {
  if (depth < 0) return null;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }

  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isFile() && e.name === name) return full;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      const hit = findFileNamed(path.join(dir, e.name), name, depth - 1);
      if (hit) return hit;
    }
  }
  return null;
}

async function installBrowser(verbose) {
  if (!browserDownloadSupported()) {
    console.error(`\
Error: no chrome-headless-shell build for ${process.platform}/${process.arch}.

${process.platform === 'linux' && process.arch === 'arm64'
  ? "On ARM Linux, install your distro's package instead:\n  sudo apt install chromium"
  : 'Install a Chromium-based browser manually and set CHROME_PATH.'}
`);
    process.exit(1);
  }

  const browsers = await puppeteerBrowsers();

  const platform = browsers.detectBrowserPlatform();
  if (!platform) {
    console.error('Error: could not determine this platform for the download.');
    process.exit(1);
  }

  console.error('Resolving latest chrome-headless-shell...');

  let buildId;
  try {
    buildId = await browsers.resolveBuildId(MANAGED_BROWSER, platform, 'stable');
  } catch (err) {
    console.error(`Error: could not reach the Chrome for Testing feed -- ${err.message}`);
    process.exit(1);
  }

  console.error(`Downloading chrome-headless-shell ${buildId} for ${platform}...`);

  // Progress on one rewritten line, and only for a terminal -- in a pipe or a
  // CI log it would just be thousands of stray writes.
  const showProgress = process.stderr.isTTY;
  let lastPct = -1;

  let installed;
  try {
    installed = await browsers.install({
      browser: MANAGED_BROWSER,
      buildId,
      platform,
      cacheDir: MANAGED_BROWSER_DIR,
      downloadProgressCallback: (done, total) => {
        if (!showProgress || !total) return;
        const pct = Math.floor((done / total) * 100);
        if (pct === lastPct) return;
        lastPct = pct;
        process.stderr.write(`\r  ${pct}%  (${(done / 1048576).toFixed(0)}/${(total / 1048576).toFixed(0)}MB)`);
      },
    });
    if (showProgress && lastPct >= 0) process.stderr.write('\n');
  } catch (err) {
    if (showProgress && lastPct >= 0) process.stderr.write('\n');
    console.error(`Error: download failed -- ${err.message}`);
    process.exit(1);
  }

  const exe = installed.executablePath;
  if (!exe || !fs.existsSync(exe)) {
    console.error('Error: the download finished but no binary was found.');
    process.exit(1);
  }

  // Downloads carry macOS's quarantine flag, which blocks launching outright.
  if (process.platform === 'darwin') {
    try {
      execSync(`xattr -dr com.apple.quarantine "${MANAGED_BROWSER_DIR}"`, { stdio: 'ignore' });
    } catch { /* xattr missing or nothing to clear */ }
  }

  if (verbose) console.error(`Cache: ${MANAGED_BROWSER_DIR}`);
  console.error(`\nInstalled to ${exe}`);
  return exe;
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

  // Skip if the output is genuinely up to date. A zero-length file doesn't
  // count -- that's the residue of an interrupted run, and treating it as
  // current means the command silently does nothing.
  if (!opts.debug && fs.existsSync(outputPath)) {
    const inStat = fs.statSync(inputPath);
    const outStat = fs.statSync(outputPath);
    if (outStat.size > 0 && inStat.mtimeMs < outStat.mtimeMs) {
      // Worth saying out loud: an explicitly named file that isn't rebuilt
      // looks like a failure otherwise.
      console.error(`${path.basename(outputPath)} is up to date`);
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


// Argument classification
//
// Extensions are a hint, not proof: what matters for "may I write here?" is
// what the file actually is. Both helpers are cheap -- a stat and, at most,
// the first five bytes.

// 'missing' | 'pdf' | 'dir' | 'other'
function classifyPath(p) {
  const resolved = path.resolve(p);

  let st;
  try {
    st = fs.statSync(resolved);
  } catch {
    return 'missing';
  }

  if (st.isDirectory()) return 'dir';
  if (!st.isFile()) return 'other';
  if (st.size === 0) return 'missing';   // a touched placeholder is fair game

  let fd;
  try {
    fd = fs.openSync(resolved, 'r');
    const buf = Buffer.alloc(5);
    const n = fs.readSync(fd, buf, 0, 5, 0);
    return n === 5 && buf.toString('latin1') === '%PDF-' ? 'pdf' : 'other';
  } catch {
    return 'other';
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// An input we can convert: an existing file that isn't already a PDF. The
// extension decides only when the file is absent, so a missing `foo.md` still
// reports "no such file" rather than "unrecognised".
function isMarkdownInput(p) {
  const kind = classifyPath(p);
  if (kind === 'pdf' || kind === 'dir') return false;
  if (kind === 'other') return true;                     // exists, not a PDF
  return /\.(md|markdown)$/i.test(p);                    // missing: go by name
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

  // Both run on their own, and must work precisely when the browser check
  // below would otherwise stop us.
  if (opts.listBrowsers) {
    console.error(listBrowsersMessage());
    process.exit(0);
  }

  if (opts.installBrowser) {
    await installBrowser(opts.verbose);
    if (opts.inputs.length === 0) process.exit(0);
  }

  const themeDir = resolveTheme(opts.theme);
  if (opts.verbose) console.error(`Theme: ${themeDir}`);

  // Which browser? Only ever an explicit choice -- see setupMessage().
  const chromiumPath = resolveChromium();
  if (!chromiumPath) {
    console.error(setupMessage());
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

  // Work out what the positional arguments mean before doing anything.
  //
  // Two symmetric shapes, each taking an optional destination. Which one
  // applies is decided by the *source*, so no argument's meaning depends on
  // guesswork:
  //
  //   pdfulator in.md              -- write in.pdf beside it
  //   pdfulator in.md out.pdf      -- write out.pdf
  //   pdfulator dir/               -- write each PDF beside its source
  //   pdfulator dir/ outdir/       -- write them into outdir/
  //
  // Earlier versions accepted any number of inputs and guessed per-argument
  // whether each was a source or a destination. That made `pdfulator *.md`
  // change meaning with the number of files the glob matched. A directory is
  // now how you convert many files at once.
  const positional = opts.inputs;

  if (positional.length > 2) {
    console.error(`\
Error: too many arguments.

  pdfulator in.md [out.pdf]    convert one file
  pdfulator dir/ [outdir/]     convert every .md in a directory

To convert several named files, put them in a directory and convert that,
or run pdfulator once per file.`);
    process.exit(1);
  }

  const sourceIsDir = positional.length > 0 && classifyPath(positional[0]) === 'dir';

  let explicitOutput = null;
  if (positional.length === 2) {
    const [source, dest] = positional;
    const destKind = classifyPath(dest);

    if (sourceIsDir) {
      // dir -> dir. The destination may not exist yet; we create it. A
      // trailing slash on either argument is just emphasis, already stripped
      // by path.resolve.
      if (destKind !== 'dir' && destKind !== 'missing') {
        console.error(`\
Error: ${source} is a directory, so ${dest} must be one too.

  pdfulator ${source} outdir/`);
        process.exit(1);
      }
      explicitOutput = path.resolve(dest);

    } else {
      // file -> file. The destination must be a PDF we may replace, or a name
      // not yet taken. Judged by content, not extension: a file called .pdf
      // holding something else is somebody's data.
      if (destKind !== 'missing' && destKind !== 'pdf') {
        console.error(`\
Error: refusing to overwrite ${dest}.

The second argument is the output file, so it must be a PDF or a new name.
${destKind === 'dir'
  ? `${dest} is a directory -- to convert into one, the source must be a directory too.`
  : `${dest} exists and is not a PDF.`}`);
        process.exit(1);
      }
      explicitOutput = path.resolve(dest);

      // The source must not itself be a PDF -- almost always a swapped pair.
      if (classifyPath(source) === 'pdf' || /\.pdf$/i.test(source)) {
        console.error(`Error: ${source} is a PDF, not something to convert.`);
        process.exit(1);
      }
    }

    positional.length = 1;
  }

  const tasks = [];

  for (const input of positional) {
    const resolved = path.resolve(input);

    if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) {
      const files = fs.readdirSync(resolved)
        .filter(f => /\.(md|markdown)$/i.test(f))
        .map(f => path.join(resolved, f));

      // With a destination directory, mirror the names into it; otherwise
      // each PDF lands beside its source.
      const outDir = explicitOutput;
      if (outDir) fs.mkdirSync(outDir, { recursive: true });

      const outFor = f => {
        const pdf = path.basename(f).replace(/\.(md|markdown)$/i, '.pdf');
        return outDir ? path.join(outDir, pdf) : path.join(resolved, pdf);
      };

      for (const f of files) {
        tasks.push(() => processFile(f, outFor(f), opts, themeDir, chromiumPath));
      }

      if (opts.watch) {
        // Process immediately then watch
        await Promise.all(tasks.map(t => t()));
        console.error(`Watching ${resolved} for changes...`);
        watchDir(resolved, async changedPath => {
          if (/\.(md|markdown)$/i.test(changedPath)) {
            try { await processFile(changedPath, outFor(changedPath), opts, themeDir, chromiumPath); }
            catch (e) { console.error(`Error processing ${changedPath}: ${e.message}`); }
          }
        });
        return; // keep process alive
      }

    } else if (classifyPath(resolved) === 'pdf' || /\.pdf$/i.test(resolved)) {
      // A PDF as an input is always a mistake -- most likely a glob that
      // caught the output of a previous run. The name alone is enough to
      // refuse: a zero-length or truncated .pdf is still not source material,
      // and converting it would overwrite it with itself.
      console.error(`Error: ${input} is a PDF, not something to convert.`);
      process.exit(1);

    } else if (fs.existsSync(resolved)) {
      const out = explicitOutput
        || (/\.(md|markdown)$/i.test(resolved)
          ? resolved.replace(/\.(md|markdown)$/i, '.pdf')
          : `${resolved}.pdf`);
      tasks.push(() => processFile(resolved, out, opts, themeDir, chromiumPath));

    } else {
      console.error(`Error: no such file: ${input}`);
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
