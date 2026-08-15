---
authors:
- name: Tom Gidden
  email: tom@gidden.net
date:
  month: August
  year: 2026
revision: v.2
pdfulator_features: shade_monospace narrow_monospace justify
...

# _pdfulator_, a Markdown to PDF converter

**https://github.com/tomgidden/pdfulator**

## Introduction

`pdfulator` is a Markdown-to-PDF converter using:

- _[markdown-it](https://github.com/markdown-it/markdown-it)_ - Markdown parser
- _[Vivliostyle](https://vivliostyle.org/)_ - Pagination, styling, PDF export
- _[Mustache](https://mustache.github.io/)_ - Templating
- _[Puppeteer](https://pptr.dev/)_ - Browser control
- _[Bun](https://bun.sh/)_ - lightweight, powerful JS engine

and optionally:

- _[Docker](https://docker.com)_ - a containerization engine
- _[Chromium](https://www.chromium.org)_ - contained browser for Puppeteer

or:

- Your existing installation of a browser that Puppeteer can control.

It's not rocket science, but it's fiddly and usually not worth spending the time to assemble into a single utility.  That's what this is for.

## Modes

This version of `pdfulator` is designed to work in two different modes, both
of which are valid, and both have pros and cons.

### Dockerized

The utility can be packaged as a Docker image, to fully self-contain it. If you're
already a Docker user, this is neat. You can pull down the image from Docker Hub:

```zsh
docker pull tomgidden/pdfulator:2
docker tag tomgidden/pdfulator:2 pdfulator
```

or you can build it yourself. To build the image, run:

```zsh
make build
```

or manually:

```zsh
docker build -t pdfulator .
```

Then:

```
docker run --rm --init -i pdfulator - < foo.md > foo.pdf
```

or

```
docker run --rm --init -v $(pwd):/in pdfulator --watch
```

### Bundled

Install with:

```bash
curl -fsSL https://pdfulator.app/install.sh | sh
```

That downloads the current release into `~/.local/share/pdfulator` (override
with `PDFULATOR_HOME`) and puts a `pdfulator` command in `~/.local/bin`
(`PDFULATOR_BIN`). The download is checksum-verified, and reinstalling over an
existing copy keeps your themes.

Nothing else is fetched without you asking. pdfulator runs on
[bun](https://bun.sh) and renders with a Chromium-based browser; if either is
missing it says so and waits. You can get them both up-front if you prefer:

```bash
curl -fsSL https://pdfulator.app/install.sh | sh -s -- --install-runtime --install-browser
```

It can use one of your existing Chromium-based browsers, and even try to locate
them; or you can tell it to install a minimal browser
(`chrome-headless-shell`) for its own use.

On first run, you'll need:

```bash
pdfulator --browser XXX
```

where `XXX` is one of:

- `auto`:    locate an installed Chromium browser and remember it
- `find`:    list located browsers for you to choose
- `install`: install a minimal browser inside the pdfulator install
- a path to a browser executable.

After that, it should remember your choice.

If all goes well, you can just do:

- `pdfulator README.md` (generates `README.pdf`)
- `pdfulator README.md foo.pdf` (generates `foo.pdf`)
- `pdfulator .` (converts every `*.md` in the current folder)
- `pdfulator docs/ pdfs/` (converts `docs/*.md` into `pdfs/`, creating it if needed)
- `pdfulator - < foo.md > foo.pdf` or `cat foo.md | pdfulator - > foo.pdf`

and you can uninstall with `pdfulator --uninstall`

## Options

```
pdfulator [options] input.md [output.pdf]   convert one file
pdfulator [options] dir/ [outdir/]          convert every *.md in a directory
pdfulator [options] -                       stdin → stdout
pdfulator --watch [options] dir/ [outdir/]  rebuild on change
```

There are two shapes, each taking an optional destination: a file becomes a
file, and a directory becomes a directory. Whether the destination is a file or
a directory follows from the source, so nothing changes meaning depending on
what happens to be on disk — `pdfulator *.md` is not a supported form precisely
because its meaning would depend on how many files the glob matched. Use a
directory to convert many files at once.

A destination is only overwritten if it is genuinely a PDF (checked by content,
not by name) or doesn't exist yet. An output that is already newer than its
source is left alone, and says so.

| Option | Meaning |
| --- | --- |
| `-t`, `--theme <name\|path>` | Theme to use |
| `-d`, `--debug` | Keep the intermediate HTML |
| `-v`, `--verbose` | Verbose output |
| `-w`, `--watch` | Watch a directory for changes |
| `-h`, `--help` | Show help |

The bundled wrapper adds a few of its own:

| Option | Meaning |
| --- | --- |
| `-b`, `--browser auto\|find\|install\|<path>` | Choose the rendering browser (remembered) |
| `--install-runtime` | Download a private copy of _bun_ if none is installed |
| `--uninstall` | Remove pdfulator, keeping anything you added or edited |

Nothing is downloaded or launched without you asking: pdfulator will explain
what it needs and wait rather than picking a browser or fetching a runtime on
your behalf.

### What it installs, and where

Everything lives under `$PDFULATOR_HOME` (`~/.local/share/pdfulator` by
default), plus the wrapper itself in `$PDFULATOR_BIN` (`~/.local/bin`):

| Path | Contents | Size |
| --- | --- | --- |
| `pdfulator.js`, `defaults/`, `theme/` | The application | small |
| `node_modules/` | npm dependencies | ~30MB |
| `bun/` | Private _bun_, only if you asked for one | ~60MB |
| `chromium/` | `chrome-headless-shell`, only if you asked for one | ~193MB |

`pdfulator --uninstall` removes all of it, except files you have added or
modified — your themes and any edited stylesheets are kept, and it tells you
what it left behind.

## Customisation and development

Working on pdfulator itself needs [bun](https://bun.sh) and a Chromium-based
browser:

```zsh
bun install
CHROME_PATH=/path/to/chrome bun run pdfulator.js README.md
```

`--debug` keeps the generated HTML next to the PDF, which is usually what you
want when adjusting a theme; `--watch` re-renders on every save:

```zsh
bun run pdfulator.js --debug --theme ./my_theme README.md
bun run pdfulator.js --watch .
```

To build the distributable wrapper from a checkout:

```zsh
make dist             # produces ./pdfulator.tar.gz, what CI publishes
make install-local    # ...and installs it, exactly as install.sh would
```

## Styling

The current CSS is a simple Humanist "white-paper" layout typical of my general tastes. I was influenced in my youth by the original [1995 Java™ white paper](https://web.archive.org/web/20240524160851/https://www.stroustrup.com/1995_Java_whitepaper.pdf)s and other documentation from Sun, and this is somewhat simplified version. It's very rough-and-ready, but it does enough for me right now.  I have been wondering if it's worth having multiple themes somehow.

You can override the styling with a theme folder of your own containing custom stylesheets, fonts and other assets. These override the ones in `defaults`:

```zsh
pdfulator --theme ./my_theme foo.md
```

A named theme is looked for in, in order: `./themes/<name>/`,
`$PDFULATOR_HOME/themes/<name>/`, then `themes/<name>/` alongside the script. So
a theme installed in the second of those is available anywhere:

```zsh
pdfulator --theme corporate foo.md
```

If the named theme isn't found, pdfulator stops and says where it looked. It
won't quietly fall back to the default — a typo would otherwise produce a
perfectly plausible PDF in the wrong style, which you'd only catch by eye.

Under Docker, mount the theme into the container instead:

```zsh
docker run --rm --init -i -v $(pwd)/my_theme:/app/theme \
  tomgidden/pdfulator:2 - < foo.md > foo.pdf
```

### Logo

If the theme folder contains a file called `logo.svg`, it should appear in the top-right.  However, to customise the positioning and style, you'll have to use a little custom CSS.  As there's a little quirk somewhere, you have to add a little content, even though it's specified in the main stylesheet:

```css
@page {
  @top-right {
    content: string("");                    /* seemingly important*/
    background-image: url(/theme/logo.svg);
    background-size: 108pt auto;            /* here's how to size the image */
    /* control `height`, `margin-top` and `margin-right` appropriately, but check 
     * it doesn't crash into content on page 2 onwards.
     */
  }
}
```


## Document metadata

To support the top front-matter in a Markdown file, you can include a YAML block at the top of the file delineated by `---` and `...`; see this `README.yaml` file for an example.

Unfortunately, other Markdown renderers (notably _[GitHub](https://github.com/tomgidden/pdfulator)_) may include this as garbled nonsense in their output.

If this bothers you, you can include the YAML as a separate file next to the Markdown instead, eg. `foo.md` and `foo.yaml`.

### Metadata entries

- `title` - The title of the document. If not included, the first top-level heading (`#`) in the document will be hoisted to the title. It seems weird to leave the title out of the bare Markdown, but this hoisting behaviour is a little unusual.

- `date` - A block containing `month` and `year` to be displayed in the front-matter.

- `revision` - A revision number, to be displayed in the front-matter and the footer.

- `copyright` - An optional copyright attribution to be included in the page footer.  If set, it will be preceded by '©', the year (determined either from `date.year` or `year` in the metadata, or the current year), and then the attribution.

- `footer` - An optional text to be included in the page footer, added to the copyright if there is one.

- `pdfulator_features` - [See below](#pdfulator_features)

### Example metadata

```yaml
title: Set this or just let it use the first `#`

date:
  month: September
  year: 2024
revision: First Draft
authors:
- firstname: Tom
  surname: Gidden
  email: tom@gidden.net
- name: D. C. O'Author
  affiliation: Institute of Documentarian Affairs
- firstname: Harold
  surname: L'astname
  affiliation: Institute of Documentarian Affairs

copyright: Tom Gidden & Institute of Documentarian Affairs
footer: Confidential

pdfulator_features:
- no_wide
- no_wide_pre
- shade_monospace
- strong_monospace
- narrow_monospace
```

### `pdfulator_features`

The document metadata [see above](#document-metadata) can include a `pdfulator_features` line or list that contains a few optional choices controlling formatting.  These can be left in but ignored (ie. disabled) by prefixing them with `no_`, or just removing them.

These include:

- `wide` - Don't indent the main body text. This gives extra space, useful especially for pre- and code-blocks, but at the expense of the left margin.

- `wide_pre` - Don't _further_ indent pre-formatted text blocks.  Again, extra space, but less easily read.

- `shade_monospace`, `shade_pre`, `shade_code` - Use a light grey background for monospaced font material, or just block (`_pre`) or inline (`_code`) sections. This is to further distinguish from the main text.

- `strong_monospace`, `strong_pre`, `strong_code` - Use a bolder font for monospaced. By default it uses a lighter font to try to distinguish from body text, but this goes the other way.

- `narrow_monospace` - Use a narrower font for monospaced content, to try to get it to fit nicely on a page.

- `justify` - Use full justification for body text. I like this, but some of my designer friends say it's bad and ragged edge makes for better typography.

- `strong_href` -- embolden hyperlinks to make them stand out.

## Adding a logo

If there is a file `logo.svg` in the `theme` folder, it will be used in the top-right header box.

# TODO

[X] _Themes_.  

[ ] _TOCs_

[ ] _Better images_. Assets in the theme folder can be referenced, and remote URLs presumably work.  Under Docker they still have to be mounted in, which is awkward.  More thought needed.

[ ] _Improved layout_. This is still a work in progress.

[ ] _Built-in themes_. Instead of having to make a theme, have some premade ones available with settings in metadata.

[ ] _Comprehensive support for the format_

[ ] _HTML_, _EPUB_, etc. The pipeline already produces HTML on the way to PDF, so exposing it should be straightforward. I'm just an old fart that likes neat A4 documents even if I never actually print them out.

[X] _Multiple files_. Handled by the directory form (`pdfulator src/ out/`) rather than a list of filenames, so an argument's meaning never depends on how many files a glob matched.

[ ] Testing of `--watch` and improvement on file globbing and so on.

[ ] _One-line installer_. `curl -fsSL https://.../install.sh | bash`, with the wrapper distributed from CI rather than built from a checkout.

Any feedback, assistance or code contributions welcome.

# History

I've had various DocBook or Markdown to PDF toolchains using XSL-FO, Apache FOP and other tech since the late nineties, usually named "docbot" as I used them in web and email services, Slack bots, etc. 

There are a lot of projects called `docbot` and a lot called `md2pdf`. None of them do exactly what I want, though. Decent pagination was served by the DocBook XSL sheets, but HTML-based ones have been lacking. Most still do. 

 And using DocBook as an intermediary is a bad idea; while DocBook is richer than Markdown (and arguably a far better choice for software documentation) the element semantics aren't suitable for generic documents.

[PagedJS](https://pagedjs.org) now seems to make the HTML route a good option, being a capable polyfill for the print features of CSS3, allowing for running headers and footers and so on.

- v1.0: Released for a short time as "docbot"

- v1.1: Renamed to "pdfulator" and refactored to give a basic "--watch" mode. This is still a work in progress.

- v1.1.1: Themes

- v1.1.2: Preservation of work folder (now in `/work`), and minor styling for logos

# Licence

I hereby release the parts of this project I have written freely under [Creative Commons CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/?ref=chooser-v1).  Attribution and code contributions would be nice though.

This clearly does not apply for the third-party sub-components it uses or the fonts in the `assets` folder which are released under their own licences: [OFL](https://github.com/google/fonts/blob/main/LICENSE) and the GUST/LPPL licence as appropriate.

I've included the fonts (and their licences) in this package purely for performance and simplicity: otherwise they either need to be downloaded on each invocation, or cached somehow between Docker runs, leaving junk on the host machine. I hope that's okay within the terms of those licences.
