#!/usr/bin/env bun
// engines/pagedjs/main.js — the pagedjs engine's converter.
//
//   main.js <input|-> <output|-> <payload-dir>
//
// markdown-it + Mustache + Paged.js. The same pipeline as the vivlio engines
// as far as the HTML, and a different paginator after it -- which is exactly
// what markdown.js exists to guarantee: both engines import the same dialect,
// the same plugin list and the same template, so a difference in their output
// is the paginator's and nothing else.
//
// NOT engines/pandoc-pagedjs. That one parses with pandoc and fills a pandoc
// template; this one shares the markdown-it half with vivlio. They target the
// same paginator and are otherwise unrelated -- see DIALECT.md for what that
// costs in dialect terms.

import fs from 'fs';
import path from 'path';
import os from 'os';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';


// Everything from Markdown to filled-in HTML, imported from the vivlio
// engine's directory rather than copied or symlinked here.
//
// By path, and reaching across engine directories, which is unusual enough to
// justify: a copy would drift, and a symlink is invisible to the installer --
// install.sh builds its manifest with `find -type f`, so a symlink is never
// recorded, never removed, and leaves the application directory behind on
// uninstall. (Found exactly that way: tests/sourcematrix.sh failed on "the
// application directory goes".)
//
// fileHref rather than payloadHref: pagedjs-cli reads a file from disk and
// resolves relative hrefs against it, where vivlio serves the payload over a
// mux server and addresses it as /payload/...
import { buildHtml, fileHref } from '../../vivlio/_nopayload/markdown.js';


function readInput(input) {
  if (input !== '-') return fs.promises.readFile(input, 'utf8');
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', d => { data += d; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}


// HTML → PDF via pagedjs-cli.
//
// THE HTML IS WRITTEN BESIDE THE DOCUMENT, not into a temp directory, and that
// is the whole of this engine's relative-asset story. pagedjs-cli loads a file
// and the browser resolves `<img src="fig.png">` against that file's own
// location -- so HTML in $TMPDIR looks for the figure in $TMPDIR and finds
// nothing. The vivlio engine solves the same problem by serving the document's
// directory over its mux server; there is no server here, so the page has to
// physically sit where its assets are.
//
// Hence the dotted name and the unlink in the caller: it is a scratch file in
// somebody's source directory for the duration of one render, and it must not
// survive the run or collide with a concurrent one.
//
// Falls back to the temp directory when the document's own is not writable --
// a read-only mount, most likely. Relative assets are then broken, but a
// document that renders without its figures beats one that does not render.
// pagedjs-cli is this engine's own dependency, so it is run from this engine's
// own node_modules rather than looked up on PATH.
//
// Spawning the bare name `pagedjs-cli` meant the engine only worked when the
// user happened to have it installed globally -- `pdfulator -e pagedjs` failed
// with "not installed or not on PATH" on a machine where `pdfulator --install`
// had done everything correctly and the binary was sitting in node_modules/.bin
// beside this file. The `convert` shim already checks that node_modules exists;
// it just never said where it was.
//
// Falls back to the bare name if the local binary is absent, which keeps a
// global install working and keeps the ENOENT message meaningful.
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

function pagedjsCliPath() {
  const local = path.join(SCRIPT_DIR, 'node_modules', '.bin', 'pagedjs-cli');
  return fs.existsSync(local) ? local : 'pagedjs-cli';
}

function pagedjsPdf(htmlPath, pdfPath, browserPath, verbose) {
  return new Promise((resolve, reject) => {
    const args = [
      htmlPath,
      '-o', pdfPath,
      // Not optional in a container: --no-sandbox because Chromium's sandbox
      // needs privileges a default `docker run` does not grant, and
      // --disable-dev-shm-usage because /dev/shm defaults to 64MB, which a
      // paginating renderer exhausts on a document of any size.
      '--browserArgs',
      '--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage',
    ];

    const cli = pagedjsCliPath();
    if (verbose) console.error(`${cli} ${args.join(' ')}`);

    const env = { ...process.env };
    if (browserPath) {
      env.PUPPETEER_EXECUTABLE_PATH = browserPath;
      env.CHROME_PATH = browserPath;
    }

    const child = spawn(cli, args, {
      env,
      stdio: ['ignore', 'inherit', verbose ? 'inherit' : 'pipe'],
    });

    let stderr = '';
    if (!verbose && child.stderr) {
      child.stderr.on('data', d => { stderr += d; });
    }

    child.on('error', err => {
      reject(new Error(err.code === 'ENOENT'
        ? 'pagedjs-cli is not installed or not on PATH'
        : err.message));
    });

    child.on('close', code => {
      if (code === 0) return resolve();
      if (stderr) process.stderr.write(stderr);
      reject(new Error(`pagedjs-cli exited ${code}`));
    });
  });
}


async function convert(input, output, payloadDir, opts) {
  const mdSource = await readInput(input);

  // Empty stdin is an error; an empty *file* is not. The asymmetry is shared
  // with every other engine: a pipe that produced nothing is a broken command
  // line, while an empty document is one someone has started and not written.
  if (input === '-' && !mdSource.trim()) {
    console.error('Error: empty input on stdin');
    process.exit(1);
  }

  const leaf = input === '-' ? 'stdin' : path.basename(input).replace(/\.[^.]+$/, '');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), `pdfulator-${leaf}-`));

  // stdin has no sidecar to find; a file's sits beside it.
  const inputBase = input === '-'
    ? path.join(tmpDir, 'stdin')
    : input.replace(/\.[^.]+$/, '');

  // Where the generated page goes -- see pagedjsPdf above for why this is not
  // simply the temp directory.
  const docDir = input === '-' ? tmpDir : path.dirname(path.resolve(input));
  let htmlDir = tmpDir;
  if (input !== '-') {
    try {
      fs.accessSync(docDir, fs.constants.W_OK);
      htmlDir = docDir;
    } catch { /* not writable: assets will not resolve, but the text will */ }
  }

  const htmlPath = path.join(htmlDir, `.pdfulator-${leaf}-${process.pid}.html`);

  try {
    fs.writeFileSync(htmlPath, buildHtml(mdSource, inputBase, payloadDir, null, fileHref()));

    // Render to a temporary PDF and move it into place, so an interrupted run
    // cannot leave a half-written file that still looks like a PDF.
    const tmpPdf = path.join(tmpDir, `${leaf}.pdf`);
    await pagedjsPdf(htmlPath, tmpPdf, process.env.CHROME_PATH, opts.verbose);

    if (output === '-') {
      process.stdout.write(fs.readFileSync(tmpPdf));
    } else {
      fs.mkdirSync(path.dirname(output), { recursive: true });
      // rename(2) cannot cross filesystems, and in a container that is the
      // normal case rather than bad luck: the output directory is a bind
      // mount, so every write to it crosses a device boundary and the rename
      // fails with EXDEV having rendered the document perfectly.
      try {
        fs.renameSync(tmpPdf, output);
      } catch (err) {
        if (err.code !== 'EXDEV') throw err;
        fs.copyFileSync(tmpPdf, output);
        fs.unlinkSync(tmpPdf);
      }
    }
  } finally {
    if (!opts.debug) {
      fs.rmSync(htmlPath, { force: true });
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } else {
      console.error(`Debug: kept ${tmpDir} and ${htmlPath}`);
    }
  }
}


async function main() {
  const argv = process.argv.slice(2);
  const opts = {
    verbose: !!process.env.PDFULATOR_VERBOSE,
    debug: !!process.env.PDFULATOR_DEBUG,
  };

  const [input, output, payloadDir] = argv;

  if (argv.length !== 3) {
    console.error('pagedjs: usage: main.js <input|-> <output|-> <payload-dir>');
    console.error('(this is the engine contract; run pdfulator instead)');
    process.exit(2);
  }

  // The wrapper resolves the browser and passes it in the environment. An
  // engine never goes looking for one.
  if (!process.env.CHROME_PATH) {
    console.error('pagedjs: no browser given (CHROME_PATH unset).');
    console.error('Run `pdfulator --browser auto`, or --browser install.');
    process.exit(1);
  }

  if (!fs.existsSync(payloadDir)) {
    console.error(`pagedjs: payload directory not found: ${payloadDir}`);
    process.exit(1);
  }

  await convert(input, output, payloadDir, opts);
}

main().catch(err => {
  console.error(`pagedjs: ${err && err.message ? err.message : err}`);
  if (process.env.PDFULATOR_DEBUG) console.error(err);
  process.exit(1);
});
