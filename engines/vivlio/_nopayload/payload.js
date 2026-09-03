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
// called (`markup`, `stylesheet`), and the ORDER is
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
//
// --- A SECOND IMPLEMENTATION EXISTS. READ THIS BEFORE EDITING ----------------
//
// lib/payload/payload.sh answers two of these same questions in POSIX sh, for
// engines that run inside a container where no JS runtime is present. It is
// staged into every payload at _lib/. Two implementations exist because the
// two live on opposite sides of a language boundary and neither can call the
// other.
//
//     payload.js         payload.sh      what it answers      duplicated?
//     ---------------    ------------    ------------------   -------------
//     templateDir()      p_template      which template dir   YES
//     engineOf()         p_engine        engine and styler    YES
//     markup()           cmd_markup      the structural file  YES
//     readConf/confGet   conf.sh         the conf grammar     YES (via sh)
//     stylesheets()      --              the §5 cascade       no: see below
//
// **stylesheets() IS NOT DUPLICATED.** payload.sh had a `stylesheets` command
// and it was removed unused: both pandoc engines link the `print.css` that the
// WRAPPER concatenated (lib/styling.sh), so nothing ever called it. What it
// left behind was a third implementation of §5's order with no consumer, and
// it had already drifted -- omitting the engine band this file emits -- with
// the comparison test unable to see it. So the cascade order lives in exactly
// two places: HERE, and lib/styling.sh.
//
// **THE ONE THAT MATTERS: this file and lib/styling.sh must agree.** The
// wrapper resolves the cascade to build print.css; this file resolves it again
// to emit <link>s. They are checked against each other by
// tests/payloadmatrix.sh, over a fixture that must stay three themes deep,
// with two sheets per object, and with the fixture engine declaring a
// stylesheet -- each of those three properties is load-bearing, and each was
// added because a mutation survived without it. A divergence between them does
// not raise an error: it renders a document with the wrong stylesheet order,
// which only an eye catches.
//
// A change to any function marked "duplicated" above obliges a matching change
// in payload.sh, and vice versa. Each side carries comments naming the other's
// corresponding statements.

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
// needs all of them: `stylesheet = +a.css` twice means two stylesheets.
function confGetAll(file, key) {
  return readConf(file).filter(([k]) => k === key).map(([, v]) => v);
}


// --- Values that name files --------------------------------------------------

// `+foo.css` adds to the list; a bare `foo.css` replaces it. The marker lives
// on the value rather than the key because the grammar splits on the first
// `=`: `stylesheet += x` would parse as the key `stylesheet ` with
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
// sh: p_engine -- which returns "<id> <styler>" on one line, because that is
// what a shell caller can split.
export function engineOf(payload) {
  // sh: _pe_dir="$1/input/engines"
  const dir = path.join(payload, INPUT, 'engines');

  // sh: [ -d "$_pe_dir" ] || return 0 -- an absent directory is empty, not an
  // error.
  let names;
  try {
    names = fs.readdirSync(dir).filter(n => isDir(path.join(dir, n)));
  } catch {
    return { id: '', styler: '' };
  }
  if (!names.length) return { id: '', styler: '' };

  // sh: _pe_id=$(basename -- "$_pe") on the first iteration.
  // The FIRST entry, not a search: staging copies the chosen engine and no
  // other, so there is exactly one. Both sides rely on that same fact rather
  // than on agreeing about how to pick among several.
  const id = names[0];

  // sh: conf_get "$_pe/engine.conf" styler
  // Read rather than assumed: vivlio and vivlio-docker run this same file with
  // different ids and the same styler, so neither can be a constant.
  return { id, styler: confGet(path.join(dir, id, 'engine.conf'), 'styler') };
}


// The template this payload was built for.
//
// There is exactly one -- staging copies the selected template and no other --
// so it is found rather than named. An engine with no template concept has
// none, and gets ''.
// sh: p_template
function templateDir(payload) {
  // sh: _pt_dir="$1/input/templates"
  const dir = path.join(payload, INPUT, 'templates');

  // sh: [ -d "$_pt_dir" ] || return 0
  let names;
  try {
    names = fs.readdirSync(dir).filter(n => isDir(path.join(dir, n)));
  } catch {
    return '';
  }

  // sh: the first matching iteration of `for _pt in "$_pt_dir"/*`.
  // Same single-entry reliance as engineOf.
  return names.length ? path.join(dir, names[0]) : '';
}


// --- What an engine wants ----------------------------------------------------

// The structural file: the template's markup, named by its own template.conf.
//
// Returns '' when the payload names none, which is not an error -- an engine
// run against a directory nobody staged falls back to its own built-in, and
// that is the whole point of the contract being paths and nothing else.
// sh: cmd_markup -- with one deliberate interface difference: that side prints
// a path RELATIVE to the payload (via p_rel), because its caller is inside a
// container where the payload's absolute host path names nothing. This side
// returns an absolute path and main.js makes it relative at the point of use,
// in linkTags's href. Same question, different frame of reference.
export function markup(payload) {
  // sh: _cm_t=$(p_template "$1"); [ -n "$_cm_t" ] || return 0
  const tdir = templateDir(payload);
  if (!tdir) return '';

  // sh: conf_get "$_cm_t/template.conf" markup
  const ref = confGet(path.join(tdir, 'template.conf'), 'markup');
  if (!ref) return '';

  // sh: the `case $_cm_ref in /*) ... esac` join.
  // resolveRef also strips a leading `+`; the shell side does not, because
  // markup is a single value rather than a list and `+` has no
  // meaning on one. If that ever changes, both sides change together.
  const file = resolveRef(ref, tdir);

  // sh: [ -f "$_cm_f" ] || return 0
  // A declared-but-missing structural file is empty, not an error: the caller
  // falls back to its own built-in, which is what a bare `docker run` with
  // nothing mounted gets.
  return fs.existsSync(file) ? file : '';
}


// One object's stylesheets, in declaration order.
//
// `stylesheet = +a.css` adds; a bare value replaces everything this
// object had accumulated, which is what makes `stylesheet = mine.css`
// mean "mine, and nothing inherited".
function sheetsOf(dir) {
  const conf = ['template.conf', 'theme.conf', 'theme-engine.conf',
                'theme-styler.conf', 'theme-template.conf', 'engine.conf']
    .map(n => path.join(dir, n))
    .find(p => fs.existsSync(p));
  if (!conf) return [];

  let out = [];
  for (const value of confGetAll(conf, 'stylesheet')) {
    if (!value) continue;
    const file = resolveRef(value, dir);
    if (!file || !fs.existsSync(file)) continue;
    if (isAdd(value)) out.push(file);
    else out = [file];
  }

  // The sheet pdfulator GENERATED for this level, if it wrote one: the CSS
  // rendering of that object's declarative keys (logo.* today, page size and
  // running heads later). It is not declared anywhere -- nothing in a conf
  // names it -- so it is picked up by its agreed name instead, which is what
  // the `_` prefix is for: it marks the one file here that pdfulator wrote
  // rather than the author.
  //
  // AFTER the declared sheets and after a bare-value replacement, so a theme's
  // own stylesheet can override the rule generated for it. That is the way
  // round an author expects, and it matches the shell: stage_styling appends
  // the generated sheets and stable-sorts on the level column only, which
  // leaves them last within their band.
  //
  // sh: stage_styling, which merges stage_payload_css's (level, file) tuples
  //     into styling_list's output and sorts with `sort -k1,1n -s`.
  const generated = path.join(dir, '_payload.css');
  if (fs.existsSync(generated)) out.push(generated);

  return out;
}



// The features a theme declares, as a space-separated string.
//
//   theme.conf:  features = shade_monospace justify
//                features = +narrow_monospace      adds to what a parent set
//
// Same grammar as `stylesheet`: `+` adds, a bare value replaces everything the
// chain accumulated, and the chain is walked root-first so a child wins. That
// is what makes `features = justify` in a leaf theme mean "justify, and none of
// what my parents asked for" -- the same thing it means for stylesheets.
//
// This REPLACED a hardcoded `theme.yaml` lookup. Nothing declared that file, no
// shipped theme had one, and it was the last by-name lookup in main.js: an
// engine reading a filename nobody had agreed on, which is the coupling this
// whole plan exists to remove. A document's own pdfulator_features still wins
// over any of this -- the theme is only supplying a default.
//
// sh: no counterpart. lib/payload/payload.sh answers `markup` and `engine`
// only, and adding a third command needs a consumer first (see the comment at
// the top of that file). The pandoc engines get features through their Lua
// filter from document metadata, and no shipped theme declares any.
export function features(payload) {
  let out = '';
  for (const dir of themeChain(payload)) {
    for (const value of confGetAll(path.join(dir, 'theme.conf'), 'features')) {
      if (!value) continue;
      const v = stripAdd(value).trim();
      if (!v) continue;
      out = isAdd(value) ? (out ? out + ' ' + v : v) : v;
    }
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
//     grandparent theme-template, parent theme-template, theme-template
//     grandparent theme-engine,   parent theme-engine,   theme-engine
//     grandparent theme-styler,   parent theme-styler,   theme-styler
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
// THIS IS THE FUNCTION THAT MUST AGREE WITH lib/styling.sh's styling_list.
//
// Not a translation of it -- the two work from different inputs, and that is
// the point rather than an accident:
//
//     styling_list   resolves from the SOURCE tree, before staging, and emits
//                    (level, path) pairs the stager turns into print.css.
//     stylesheets    resolves from the PAYLOAD, after staging, by walking the
//                    mirror the stager built.
//
// Same rule, two vantage points. Neither can be derived from the other, which
// is why both exist; tests/payloadmatrix.sh asserts they produce the same
// list, and that test is the only thing standing between an edit here and a
// document whose stylesheets apply in the wrong order.
//
// The bands correspond one-to-one with styling_list's numbered levels:
//
//     level  styling_list                          here
//     -----  -----------------------------------   ---------------------------
//        5   engine.conf's stylesheet        sheetsOf(engineDir)
//       10   template.conf's stylesheet      sheetsOf(tdir)
//       20   styling_axis "" theme.conf            sub === ''
//       25   styling_axis templates/<id>           sub === `templates/<id>`
//       30   styling_axis engines/<id>             sub === `engines/<id>`
//       40   styling_axis stylers/<s>              sub === `stylers/<s>`
//       50   (neither: the document -- see below)
//       60   the --css argument                    externalSheets()
//
// **Level 50 is produced by NEITHER.** It is the document's own YAML, and the
// wrapper cannot extract it: knowing which YAML block is frontmatter needs a
// real Markdown parser, and this repo's own README would defeat a naive one.
// An engine that wants it splices it in itself, between 40 and 60.
//
// **Adding a level means editing BOTH, plus STYLING_LEVELS in lib/styling.sh.**
// A level present in one and absent from the other is invisible until someone
// declares it -- which is exactly how the engine band (5) came to exist here
// and not there, and stayed that way because no fixture engine declared a
// stylesheet.
export function stylesheets(payload, engineId, styler) {
  const chain = themeChain(payload);
  const out = [];

  // Level 5: the engine's own sheet. The bottom of the cascade, below even the
  // template: an engine's sheet is the most general statement there is.
  // styling_list: the `conf_get_all "$_sl_enginedir/engine.conf"` block.
  const engineDir = objectDir(payload, 'engines', engineId);
  if (isDir(engineDir)) out.push(...sheetsOf(engineDir));

  // Level 10: the template's own sheet -- the floor a theme is written
  // against. If it came after the theme's, no theme could restyle anything the
  // template had an opinion about without specificity hacks.
  // styling_list: the `conf_get_all "$_sl_tdir/template.conf"` block.
  const tdir = templateDir(payload);
  if (tdir) out.push(...sheetsOf(tdir));

  // Levels 20/25/30/40: one pass per axis, each pass walking the whole chain
  // root-first. AXIS OUTER, CHAIN INNER -- this loop nesting IS the rule, and
  // transposing the two `for`s silently produces the rejected order.
  // styling_list: the four consecutive styling_axis calls.
  //
  // templates/ (25) comes before engines/ and stylers/ (§6): the markup is
  // what you are styling, an engine's quirks are narrower than the markup they
  // apply to, and the styler paginates and so gets the last word. It is keyed
  // on the SELECTED template, the same one templateDir() found for level 10 --
  // a theme styling `templates/html-mustache-vivlio/` means "when this markup
  // is in play", which is only meaningful against the template in use.
  const templateAxis = tdir ? `templates/${path.basename(tdir)}` : null;
  const axes = ['', ...(templateAxis ? [templateAxis] : []),
                `engines/${engineId}`, `stylers/${styler}`];
  for (const sub of axes) {
    for (const themeDir of chain) {
      const dir = sub ? path.join(themeDir, sub) : themeDir;
      if (isDir(dir)) out.push(...sheetsOf(dir));
    }
  }

  // Level 60: --css, the highest. styling_list takes it as an argument and
  // emits it directly; here it is found by POSITION, under external/, because
  // by this point it is a staged file like any other and has no conf file to
  // declare it -- it is not an object. Staged under external/ because the user
  // may point it at any file on the disk, and a path from their home has no
  // place in a directory that gets mounted or shipped.
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
