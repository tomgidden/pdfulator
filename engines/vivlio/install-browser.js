#!/usr/bin/env bun
// engines/vivlio/install-browser.js — fetch chrome-headless-shell.
//
// Run by `pdfulator --browser install`, never as part of a conversion.
//
// This is the one piece of browser handling that stayed in JS when the rest
// went to lib/browser.sh, and the distinction is worth stating: *finding* a
// browser is a table of paths and a $PATH scan, which sh does perfectly well
// and every browser engine needs. *Downloading* one is @puppeteer/browsers --
// the same downloader puppeteer itself uses, so we inherit its platform
// matrix, proxy support, mirror configuration and resumable downloads instead
// of reimplementing them in shell against the Chrome for Testing feed.
//
// It lives in the engine because only engines that drive a browser need one.
// A pandoc-xslt user should never meet this file, nor the runtime to run it.
//
// headless-shell rather than full Chrome: half the size (~193MB vs ~356MB
// unpacked) and, having no UI layer, exactly what a headless PDF pipeline
// needs. Verified to produce an identical text layer to full Chrome here.
//
// Never automatic -- downloading ~193MB is something the user asks for.

import fs from 'fs';
import path from 'path';
import os from 'os';
import { execSync } from 'child_process';

const PDFULATOR_HOME = process.env.PDFULATOR_HOME
  || path.join(os.homedir(), '.local', 'share', 'pdfulator');

// Must agree with lib/browser.sh, which searches this cache without running
// any of this. The layout is @puppeteer/browsers': <cacheDir>/<browser>/...
const MANAGED_BROWSER_DIR = path.join(PDFULATOR_HOME, 'chromium');
const MANAGED_BROWSER = 'chrome-headless-shell';

// Imported lazily: it pulls in a sizeable tree, and this file is the only
// thing that ever needs it.
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




// The path is printed on stdout, alone, so the wrapper can pin it by reading
// one line. Everything else this file says goes to stderr -- progress and
// diagnostics are for the user, and mixing them into the answer would make
// the caller parse prose again, which is the scrape lib/browser.sh removed.
installBrowser(!!process.env.PDFULATOR_VERBOSE)
  .then(exe => { process.stdout.write(`${exe}\n`); })
  .catch(err => {
    console.error(`vivlio: ${err && err.message ? err.message : err}`);
    process.exit(1);
  });
