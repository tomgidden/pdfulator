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

import puppeteer from 'puppeteer-core';

// Everything from Markdown to filled-in HTML, shared with the `pagedjs`
// engine: the dialect, the plugin list, frontmatter, metadata and the Mustache
// template. Only the paginator below is this engine's own -- which is what
// makes a difference between the two engines' output genuinely the
// paginator's. See engines/_shared/markdown.js.
import { buildHtml, payloadHref } from './markdown.js';


// Paths
//
// There is no defaults directory any more. What used to live there -- a
// stylesheet, a template and three font families -- was engine-specific
// content in a shared place, and the copy the pandoc engine kept beside it had
// already drifted 640 lines away. Both are now themes, and the wrapper hands
// this engine a staged directory holding everything a conversion needs:
// print.css, fonts.css, the fonts themselves, and the template.

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));


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
