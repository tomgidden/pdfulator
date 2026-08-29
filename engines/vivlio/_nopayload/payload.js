// engines/vivlio/_nopayload/payload.js — reading a payload.
//
// The payload is the directory the wrapper builds and hands an engine: the
// engine that was chosen, the template it names, and the theme chain, each
// object copied whole to its position in the source tree under input/. See
// lib/stage.sh, and PAYLOAD-PLAN.md §4/§5/§9.
//
// This module answers two questions about one:
//
//   markup(payload, engineId, styler)      what is the structural file?
//   stylesheets(payload, engineId, styler) which stylesheets, in what order?
//
// THE PAYLOAD IS SELF-DESCRIBING, AND THAT IS THE POINT. Nothing here is told
// what to read. Each object's conf file says what that object's files are
// called (`template.structure`, `template.styling`), and the ORDER is
// structural -- recovered by walking the tree rather than read out of a
// manifest that staging had to remember to write. An engine that hardcodes
// `article.tmpl` and `print.css` works only for as long as every ecosystem
// agrees on those names, and they do not: handing a Mustache article.tmpl to
// pandoc is the bug the template object exists to make impossible.
//
// WHY WALK RATHER THAN READ A LIST. The order is not data. The engine knows
// its own id and its styler; it can see the mirrored tree; and a theme's
// `extends` names its parent. That is everything needed to reconstruct §5's
// order, so nothing has to be recorded -- and nothing can go stale.

import fs from 'fs';
import path from 'path';


// --- Reading a conf file -----------------------------------------------------
//
// Deliberately the same grammar as lib/conf.sh's conf_get, and no more than
// that: flat key=value, `#` comments, whitespace around `=` insignificant.
// The shell side is the reference implementation -- if these two ever
// disagree, an engine renders something other than what the wrapper staged,
// and the difference shows up as a styling bug rather than as an error.
//
// Not YAML, not JSON, and never eval'd: a conf file comes out of a theme, and
// a theme is data that anybody may share. Parsing it with a language runtime
// is how a downloaded theme gets to run code.

function readConf(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return [];       // absent is empty, exactly as conf_get treats it
  }

  const out = [];
  for (const raw of text.split('\n')) {
    const line = raw.replace(/^[ \t]+/, '');
    if (line === '' || line.startsWith('#')) continue;

    const eq = line.indexOf('=');
    if (eq < 0) continue;                      // no '=' at all: not a setting

    const key = line.slice(0, eq).replace(/[ \t]+$/, '');
    const value = line.slice(eq + 1).replace(/^[ \t]+/, '').replace(/[ \t]+$/, '');
    out.push([key, value]);
  }
  return out;
}

// The first value for a key, or '' -- conf_get's contract.
function confGet(file, key) {
  const hit = readConf(file).find(([k]) => k === key);
  return hit ? hit[1] : '';
}

// Every value for a key, in file order -- conf_get_all's contract. A list key
// needs all of them: `template.styling = +a.css` twice means two stylesheets.
function confGetAll(file, key) {
  return readConf(file).filter(([k]) => k === key).map(([, v]) => v);
}


// --- Values that name files --------------------------------------------------

// `+foo.css` adds to the list; a bare `foo.css` replaces it. The marker lives
// on the value rather than the key because the grammar splits on the first
// `=`: `template.styling += x` would parse as the key `template.styling ` with
// the `+` orphaned. See lib/styling.sh.
function isAdd(value) {
  return value.startsWith('+');
}

function stripAdd(value) {
  return isAdd(value) ? value.slice(1).replace(/^[ \t]+/, '') : value;
}

// Paths in a conf file are relative to THE FILE THAT DECLARED THEM, never to
// the caller's working directory or to the payload root. That is what lets a
// theme write `./theme.css` and mean its own, and it is why resolution happens
// where the declaring file is known.
function resolveRef(value, baseDir) {
  const v = stripAdd(value);
  if (!v) return '';
  return path.isAbsolute(v) ? v : path.join(baseDir, v);
}


// --- The payload's shape -----------------------------------------------------

const INPUT = 'input';

function objectDir(payload, kind, name) {
  return path.join(payload, INPUT, kind, name);
}

function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}


// The theme chain, root first.
//
// Recovered by following `extends` from the leaf, which is the same walk the
// wrapper does over the same conf files -- now present in the payload because
// every selected object was mirrored whole, including a theme that contributes
// no stylesheet at all. Such a theme is invisible in a list of stylesheets and
// indispensable to this walk: it carries the `extends` that reaches its parent.
//
// Root first because that is cascade order: the floor, then each refinement.
//
// The leaf is the theme no other theme in the payload extends. That is well
// defined here -- the payload holds exactly the chain that was selected, so
// there is exactly one -- and it avoids the engine having to be told which
// theme the user named.
function themeChain(payload) {
  const themesDir = path.join(payload, INPUT, 'themes');
  let names;
  try {
    names = fs.readdirSync(themesDir).filter(n => isDir(path.join(themesDir, n)));
  } catch {
    return [];
  }

  const parentOf = new Map();
  for (const name of names) {
    const ext = confGet(path.join(themesDir, name, 'theme.conf'), 'extends');
    // `extends` may be a bare name or a path; only the basename identifies the
    // directory the mirror created.
    parentOf.set(name, ext ? path.basename(ext) : '');
  }

  const isParent = new Set([...parentOf.values()].filter(Boolean));
  const leaf = names.find(n => !isParent.has(n));
  if (!leaf) return [];                        // a cycle: better nothing than a hang

  const chain = [];
  const seen = new Set();
  for (let cur = leaf; cur && parentOf.has(cur) && !seen.has(cur); cur = parentOf.get(cur)) {
    seen.add(cur);
    chain.unshift(path.join(themesDir, cur));
  }
  return chain;
}


// Which engine this payload was built for, and which styler it uses.
//
// Derived from the payload rather than passed in, because the contract is
// three paths and nothing else, and widening it for something the payload
// already states would be the wrong trade. Staging copies the CHOSEN engine
// and no other, so `input/engines/` has exactly one entry; that entry's
// engine.conf declares the styler.
//
// It matters that this is read rather than assumed: `vivlio` and
// `vivlio-docker` run the same code from the same file, so the id cannot be a
// constant here, and a future engine sharing this renderer would be wrong
// again in the same way.
export function engineOf(payload) {
  const dir = path.join(payload, INPUT, 'engines');
  let names;
  try {
    names = fs.readdirSync(dir).filter(n => isDir(path.join(dir, n)));
  } catch {
    return { id: '', styler: '' };
  }
  if (!names.length) return { id: '', styler: '' };

  const id = names[0];
  return { id, styler: confGet(path.join(dir, id, 'engine.conf'), 'styler') };
}


// The template this payload was built for.
//
// There is exactly one -- staging copies the selected template and no other --
// so it is found rather than named. An engine with no template concept has
// none, and gets ''.
function templateDir(payload) {
  const dir = path.join(payload, INPUT, 'templates');
  let names;
  try {
    names = fs.readdirSync(dir).filter(n => isDir(path.join(dir, n)));
  } catch {
    return '';
  }
  return names.length ? path.join(dir, names[0]) : '';
}


// --- What an engine wants ----------------------------------------------------

// The structural file: the template's markup, named by its own template.conf.
//
// Returns '' when the payload names none, which is not an error -- an engine
// run against a directory nobody staged falls back to its own built-in, and
// that is the whole point of the contract being paths and nothing else.
export function markup(payload) {
  const tdir = templateDir(payload);
  if (!tdir) return '';

  const ref = confGet(path.join(tdir, 'template.conf'), 'template.structure');
  if (!ref) return '';

  const file = resolveRef(ref, tdir);
  return fs.existsSync(file) ? file : '';
}


// One object's stylesheets, in declaration order.
//
// `template.styling = +a.css` adds; a bare value replaces everything this
// object had accumulated, which is what makes `template.styling = mine.css`
// mean "mine, and nothing inherited".
function sheetsOf(dir) {
  const conf = ['template.conf', 'theme.conf', 'theme-engine.conf',
                'theme-styler.conf', 'engine.conf']
    .map(n => path.join(dir, n))
    .find(p => fs.existsSync(p));
  if (!conf) return [];

  let out = [];
  for (const value of confGetAll(conf, 'template.styling')) {
    if (!value) continue;
    const file = resolveRef(value, dir);
    if (!file || !fs.existsSync(file)) continue;
    if (isAdd(value)) out.push(file);
    else out = [file];
  }
  return out;
}


// Every stylesheet that applies, lowest priority first.
//
// THE ORDER IS §5's, AND IT IS AXIS-OUTER / CHAIN-INNER:
//
//     engine
//     template
//     grandparent theme,        parent theme,        theme
//     grandparent theme-engine, parent theme-engine, theme-engine
//     grandparent theme-styler, parent theme-styler, theme-styler
//
// NOT chain-outer. Tom's rationale, which generalises to any axis added later:
// an object's stylesheet is really its parent's with changes, so the
// inheritance is logically private to that object -- each axis is its own
// chain, resolved end to end before it meets the next. The rejected order
// interleaves them and lets a *grandparent's* styler-specific rule beat the
// rule the theme in front of you wrote.
//
// Engine and template are at the bottom, adjacent, as the machinery: the
// template knows its own DOM and is the floor a theme is written against. If
// the template's sheet came after the theme's, no theme could restyle anything
// the template had an opinion about without specificity hacks.
//
// The inversion is invisible with a two-level chain, which is how the old
// implementation survived a year -- it takes three themes to show.
export function stylesheets(payload, engineId, styler) {
  const chain = themeChain(payload);
  const out = [];

  const engineDir = objectDir(payload, 'engines', engineId);
  if (isDir(engineDir)) out.push(...sheetsOf(engineDir));

  const tdir = templateDir(payload);
  if (tdir) out.push(...sheetsOf(tdir));

  // One pass per axis, each pass walking the whole chain root-first.
  for (const sub of ['', `engines/${engineId}`, `stylers/${styler}`]) {
    for (const themeDir of chain) {
      const dir = sub ? path.join(themeDir, sub) : themeDir;
      if (isDir(dir)) out.push(...sheetsOf(dir));
    }
  }

  // --css, the highest level, staged under external/ because the user may
  // point it at any file on the disk and a path from their home has no place
  // in a directory that gets mounted or shipped. It has no conf file to
  // declare it -- it is not an object -- so it is picked up by position, which
  // is the same "the tree says it" rule as everything above.
  out.push(...externalSheets(payload));

  return out;
}


// Stylesheets staged from outside any object: today, --css.
//
// Sorted by name so the order is defined rather than filesystem-dependent.
// There is at most one today; sorting costs nothing and means a second will
// not be ordered by luck.
function externalSheets(payload) {
  const root = path.join(payload, INPUT, 'external');
  const out = [];
  let dirs;
  try {
    dirs = fs.readdirSync(root).filter(n => isDir(path.join(root, n))).sort();
  } catch {
    return out;
  }
  for (const d of dirs) {
    const dir = path.join(root, d);
    for (const f of fs.readdirSync(dir).sort()) {
      if (f.endsWith('.css')) out.push(path.join(dir, f));
    }
  }
  return out;
}
