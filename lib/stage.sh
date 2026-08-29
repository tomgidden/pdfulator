# lib/stage.sh — building what an engine actually receives.
#
# The engine contract's third argument is a theme directory. Until now that was
# the theme the user named; it is now a directory this file builds, holding
# everything that theme means for this particular engine:
#
#   manifest           what is here and what each thing is (see below)
#   input/             every input file, under a mirror of where it came from
#   print.css          the styling cascade, concatenated in level order
#   fonts.css          generated @font-face and --pdfulator-<role> properties
#   fonts/             the font files themselves
#   fop-fonts.xconf    generated FOP font configuration    (xsl-fo stylers)
#   fo-params          role -> family, for xsltproc        (xsl-fo stylers)
#   metadata.lua, logo.svg, ...
#
# Built on this side of the container boundary, deliberately. An engine then
# needs to know nothing about inheritance, about where fonts come from, or
# about the user's filesystem -- it reads files out of one directory. That is
# what makes the same theme work for a bundled engine, a containerised one
# (mount the directory) and eventually a remote one (send the directory).
#
# --- THE MANIFEST ------------------------------------------------------------
#
# One tab-separated row per file, after a `#` comment line:
#
#   <kind>  <level>  <level-name>  <path>
#
# <kind> is what the row is for -- `styling` for a stylesheet, `structure` for
# the template's structural file. <level> and <level-name> are set for styling
# rows and empty otherwise. <path> is always relative to the staged directory,
# so it survives a mount or a transfer.
#
# The manifest exists so that an engine is TOLD what to read rather than
# guessing. Engines have historically hardcoded a filename -- `article.tmpl`,
# `global.tmpl`, `print.css` -- and looked for it at the root. That is a
# leftover from when the staged directory *was* the theme, and it is the same
# by-name coupling that once let a Mustache template reach pandoc: staging the
# right file under the expected name fixed that symptom but left every
# ecosystem obliged to agree on a filename. A row in the manifest removes the
# obligation.
#
# It is also the (level, file) list the styling design calls for. A CSS engine
# can ignore it and read print.css; an engine that is not additive -- XSL-FO
# especially -- reads the rows and flattens them its own way; an engine
# splicing in its own band (the document's YAML, level 50, which the wrapper
# cannot extract) needs the parts rather than the concatenation.
#
# --- WHY input/ MIRRORS THE SOURCE TREE --------------------------------------
#
# Files are not flattened into one directory, for two reasons:
#
#   1. Basenames collide by design. A theme chain contributes several files
#      called print.css -- one per theme per axis. Renaming them to fit in one
#      directory throws away the provenance that makes a staged directory
#      readable when the output looks wrong.
#
#   2. CSS resolves url() relative to the stylesheet. A theme writing
#      `background-image: url(./bg.png)` gets a dangling reference the moment
#      its stylesheet is moved away from its assets, and a missing background
#      image is not an error anywhere in the pipeline -- it just renders wrong.
#
# So `themes/classic/stylers/vivliostyle/classic.styler-vivliostyle.css`
# arrives at `input/themes/classic/stylers/vivliostyle/...`, with the files
# that sit beside it. Note that url() inside the concatenated print.css at the
# root does NOT resolve into the mirror, which is a further reason for an
# engine to prefer the manifest.
#
# --- WHAT IS MIRRORED, AND WHAT IS NOT ---------------------------------------
#
# Every object the build selected is copied WHOLE -- the engine, the template
# it names, each theme in the chain, and within each theme the engine and
# styler axes that were chosen. Whole, because an object's files refer to each
# other in ways only that object's ecosystem understands: a Mustache partial,
# an @import, a SYSTEM entity, an image behind a url(). The alternative is a
# dependency scanner per ecosystem, which is what template.support exists to
# avoid needing.
#
# The consequence worth stating: EVERY SELECTED OBJECT'S CONF FILE IS PRESENT,
# including a theme that contributes no stylesheet at all -- it still carries
# the `extends` a walk follows, and leaving it out puts a hole in the chain.
# That is what makes the payload self-describing, and it is the precondition
# for an engine reading what each object declared rather than being handed a
# manifest or hunting for a file by an agreed name.
#
# What does not travel: `_nopayload/`, plus whatever an object adds with
# `do.not.payload` in its own conf file. See STAGE_NOPAYLOAD_DEFAULT below.
#
# Requires lib/conf.sh, lib/paths.sh, lib/theme.sh, lib/template.sh,
# lib/styling.sh and lib/fonts.sh.


# Files a theme may supply that are copied through as-is, most specific
# winning. Not a cascade: a theme overriding metadata.lua replaces its
# parent's, since half a filter is not a filter.
#
# Several logo spellings, because a logo is the one asset people arrive with
# already made, in whatever format they were given. Staging all of them costs
# nothing -- a theme has at most one -- and means `logo.png` is not silently
# ignored by a rule that only ever looked for `.svg`.
#
# `article.tmpl` and `global.tmpl` are deliberately NOT here. Staging a
# template by name is what broke both pandoc engines: themes/default's
# article.tmpl is Mustache, this list copied it in for whichever engine asked,
# and engines/pandoc-*/render preferred the staged copy over their own -- so
# pandoc received a template in a syntax it does not know and printed the
# markup into the PDF as text. A template now arrives via the template object,
# which knows which ecosystem it belongs to. See stage_template below.
STAGE_FILES="metadata.lua theme.yaml fo.xsl \
             logo.svg logo.png logo.jpg logo.jpeg logo.webp"

# Files that *are* a cascade: concatenated root-first, so a child's rules come
# after -- and therefore win -- by ordinary CSS precedence rather than by
# replacing the file.
#
# print.css is no longer here: which stylesheets apply, and in what order, is
# now lib/styling.sh's question, and it answers it with (level, file) tuples
# that stage_styling turns into that same concatenation. html.css stays because
# nothing generates or declares it -- it is a plain by-name cascade file, and
# the only one left.
STAGE_CASCADE="html.css"


stage_error() {  # stage_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# Where staged directories live.
stage_root() {
	printf '%s/cache\n' "${PDFULATOR_HOME:-$HOME/.local/share/pdfulator}"
}


# The identity of a staged directory.
#
#   stage_key <chain> <engine> <styler>
#
# Hashed from everything that can change the result: the chain, the engine and
# styler that select within it, and the content of every file that would be
# staged. Content rather than mtime, because a theme edited back and forth
# should not restage, and because mtime is exactly the thing that differs
# between a fresh checkout and the copy that built the cache.
#
# The alternative -- staging into a fresh mktemp every run -- was rejected
# because a directory job or a watch session converts many documents against
# one theme, and re-hardlinking a variable font per document is work nobody
# asked for.
stage_key() {  # stage_key <chain> <engine> <styler> [css]
	{
		printf '%s\n' "$2" "$3"
		# --css is part of the result, so it is part of the identity: two runs
		# differing only in their extra stylesheet must not share a directory.
		if [ -n "${4:-}" ] && [ -f "$4" ]; then
			printf '%s %s\n' "$4" "$(conf_hash_file "$4")"
		fi

		# The template too. Its files are outside every theme in the chain, so
		# without this an edit to a template -- or a theme changing which
		# template it selects -- would keep serving the staged copy made before
		# the change, which is the cache lying rather than being fast.
		_sk_tdir=$(template_select "$1" "$2" "$3" \
			"${ENGINES_DIR:-$PDFULATOR_DIR/engines}/$2" 2>/dev/null) || _sk_tdir=""
		if [ -n "$_sk_tdir" ]; then
			printf '%s\n' "$_sk_tdir"
			for _sk_tf in "$_sk_tdir/template.conf" \
				"$(template_structure "$_sk_tdir" 2>/dev/null)" \
				$(template_support "$_sk_tdir" 2>/dev/null); do
				if [ -n "$_sk_tf" ] && [ -f "$_sk_tf" ]; then
					printf '%s %s\n' "$_sk_tf" "$(conf_hash_file "$_sk_tf")"
				fi
			done
		fi
		# Every stylesheet the cascade selects, in order, with its content. The
		# by-name loop below cannot stand in for this: a theme may now name a
		# stylesheet that is not called print.css and does not sit in a theme
		# directory at all -- the template's own styling is the shipped example
		# -- so a file the result depends on would otherwise be outside the key.
		styling_list "$1" "$2" "$3" \
			"${ENGINES_DIR:-$PDFULATOR_DIR/engines}/$2" "${4:-}" 2>/dev/null | \
		while IFS="$(printf '\t')" read -r _sk_lvl _sk_f || [ -n "$_sk_lvl" ]; do
			[ -n "$_sk_f" ] || continue
			[ -f "$_sk_f" ] || continue
			printf '%s %s %s\n' "$_sk_lvl" "$_sk_f" "$(conf_hash_file "$_sk_f")"
		done

		printf '%s\n' "$1" | while IFS= read -r _sk_dir || [ -n "$_sk_dir" ]; do
			[ -n "$_sk_dir" ] || continue
			printf '%s\n' "$_sk_dir"
			# Every file that could contribute, in a fixed order, each with its
			# content hash. A theme that changes any of them gets a new key.
			# theme-engine.conf and theme-styler.conf are here because they may
			# select a template; a theme changing which one it uses must get a
			# new key even though none of its own files changed.
			for _sk_name in $STAGE_FILES $STAGE_CASCADE fonts.conf theme.conf \
				theme-engine.conf theme-styler.conf; do
				for _sk_where in "$_sk_dir/engines/$2" "$_sk_dir/stylers/$3" "$_sk_dir"; do
					if [ -f "$_sk_where/$_sk_name" ]; then
						printf '%s %s\n' "$_sk_where/$_sk_name" \
							"$(conf_hash_file "$_sk_where/$_sk_name")"
					fi
				done
			done
		done
	} | conf_hash_string
}


# Build the staged directory. Assumes it does not exist yet.
#
#   stage_build <chain> <engine> <styler> <out> <font-base>
#
# <font-base> is where the fonts will be *when the engine runs*, which for a
# container is a mount point rather than this path. Only the caller knows it.
stage_build() {  # stage_build <chain> <engine> <styler> <out> <font-base> [css]
	_sb_chain=$1
	_sb_engine=$2
	_sb_styler=$3
	_sb_out=$4
	_sb_fontbase=${5:-fonts}
	_sb_css=${6:-}

	mkdir -p -- "$_sb_out/fonts" || return 1

	# The manifest describes the staged directory to whatever reads it. Written
	# here rather than by each stager so the order of rows follows the order
	# things are staged in, and so it exists even if nothing adds a row.
	{
		printf '# pdfulator staged directory. kind\tlevel\tlevel-name\tpath\n'
	} > "$_sb_out/manifest" || return 1

	# --- Cascaded files: concatenated root-first --------------------------------
	#
	# theme_file lists most-specific-first, so it is reversed here: the child's
	# rules must come last to win. Each is announced with a comment, because a
	# 500-line concatenation with no indication of where the parts came from is
	# unpleasant to debug.
	for _sb_name in $STAGE_CASCADE; do
		_sb_any=0
		for _sb_src in $(theme_file "$_sb_chain" "$_sb_engine" "$_sb_styler" \
			"$_sb_name" | sed '1!G;h;$!d'); do
			[ -f "$_sb_src" ] || continue
			if [ "$_sb_any" = 0 ]; then
				: > "$_sb_out/$_sb_name" || return 1
				_sb_any=1
			fi
			printf '/* --- %s --- */\n' "$_sb_src" >> "$_sb_out/$_sb_name"
			cat -- "$_sb_src" >> "$_sb_out/$_sb_name" || return 1
			printf '\n' >> "$_sb_out/$_sb_name"
		done
	done

	# --- The payload's own reader --------------------------------------------
	stage_lib "$_sb_out" || return 1

	# --- The selected objects, mirrored --------------------------------------
	#
	# Every object that took part in this build, copied whole to its position
	# in the source tree, so the payload describes itself: an engine can read
	# engine.conf, follow `extends` from theme to theme and find `markup` in a
	# template.conf, rather than being told what to read by a manifest.
	#
	# First, so that the stagers below overwrite rather than are overwritten --
	# stage_styling in particular resolves a stylesheet's real path and must
	# win over a copy that arrived here by being in the same directory.
	stage_mirror_all "$_sb_chain" "$_sb_engine" "$_sb_styler" "$_sb_out" \
		|| return 1

	# --- The styling cascade -------------------------------------------------
	#
	# print.css and its manifest. --css arrives here as the highest level
	# rather than as a special case appended afterwards.
	stage_styling "$_sb_chain" "$_sb_engine" "$_sb_styler" "$_sb_out" \
		"$_sb_css" || return 1

	# --- Single files: most specific wins ---------------------------------------
	for _sb_name in $STAGE_FILES; do
		_sb_src=$(theme_file_one "$_sb_chain" "$_sb_engine" "$_sb_styler" "$_sb_name")
		if [ -n "$_sb_src" ] && [ -f "$_sb_src" ]; then
			cp -- "$_sb_src" "$_sb_out/$_sb_name" || return 1
		fi
	done

	# --- The template ------------------------------------------------------------
	stage_template "$_sb_chain" "$_sb_engine" "$_sb_styler" "$_sb_out" || return 1

	# --- Fonts -------------------------------------------------------------------
	#
	# The whole chain's fonts.conf files are merged per role, then every face
	# of every role is acquired into fonts/. A failure here stops the build
	# unless --font-fallback was given, in which case the role simply has no
	# file and falls back to a base-14 name in the generated CSS and params.
	_sb_confs=""
	for _sb_dir in $(printf '%s\n' "$_sb_chain"); do
		[ -n "$_sb_dir" ] || continue
		for _sb_where in "$_sb_dir" "$_sb_dir/stylers/$_sb_styler" \
			"$_sb_dir/engines/$_sb_engine"; do
			if [ -f "$_sb_where/fonts.conf" ]; then
				_sb_confs="$_sb_confs $_sb_where/fonts.conf"
			fi
		done
	done

	_sb_merged="$_sb_out/.fonts.merged"
	# shellcheck disable=SC2086
	fonts_merge "$_sb_merged" $_sb_confs || return 1

	for _sb_role in $(fonts_merged_roles "$_sb_merged"); do
		fonts_merged_faces "$_sb_merged" "$_sb_role" | \
		while read -r _sb_w _sb_s; do
			[ -n "$_sb_w" ] || continue
			fonts_acquire "$_sb_merged" "$_sb_role" "$_sb_w" "$_sb_s" \
				"$_sb_out/fonts" >/dev/null || exit 1
		done || return 1
	done

	# --- Generated ----------------------------------------------------------------
	fonts_css "$_sb_merged" "$_sb_out/fonts" "$_sb_out/fonts.css" || return 1
	fonts_fo_params "$_sb_merged" "$_sb_out/fonts" "$_sb_out/fo-params" || return 1

	# The logo, if the theme has one. Declared in theme.conf or simply present
	# as logo.svg; either way the rule that places it is generated here, so a
	# theme wanting a logo on every page is a theme.conf and an image rather
	# than a stylesheet someone had to write.
	stage_logo "$_sb_chain" "$_sb_out" || return 1

	# FOP config only where it means something. A vivlio theme with a stray
	# fop-fonts.xconf in it is harmless but misleading.
	if [ "$_sb_styler" = "xsl-fo" ]; then
		fonts_fop_xconf "$_sb_merged" "$_sb_out/fonts" "$_sb_fontbase" \
			"$_sb_out/fop-fonts.xconf" || return 1
	fi

	# Scratch state, not part of the payload: the map exists so that two
	# stagers agree on where a source directory was mirrored, and once both
	# have run there is nothing left to agree about. An engine that found it
	# might reasonably think it meant something.
	rm -f "$_sb_out/.mirror.map"

	return 0
}


# The staged directory for a theme and engine, building it if absent.
#
#   stage_dir <theme-dir> <engine> <styler> [font-base]
#
# Prints the absolute path on stdout. Built into a temporary directory and
# moved into place, so a build interrupted halfway cannot leave a partial
# staging directory that the next run would mistake for a finished one --
# the same reason install.sh unpacks to staging before it moves.
stage_dir() {  # stage_dir <theme-dir> <engine> <styler> [font-base] [css]
	_sd_theme=$1
	_sd_engine=$2
	_sd_styler=$3
	_sd_fontbase=${4:-fonts}
	_sd_css=${5:-}

	_sd_chain=$(theme_chain "$_sd_theme") || return 1
	_sd_key=$(stage_key "$_sd_chain" "$_sd_engine" "$_sd_styler" "$_sd_css") \
		|| return 1
	_sd_target="$(stage_root)/$_sd_key"

	if [ -f "$_sd_target/.staged" ]; then
		printf '%s\n' "$_sd_target"
		return 0
	fi

	mkdir -p -- "$(stage_root)" || return 1
	_sd_tmp="$_sd_target.building.$$"
	rm -rf -- "$_sd_tmp"

	if ! stage_build "$_sd_chain" "$_sd_engine" "$_sd_styler" "$_sd_tmp" \
		"$_sd_fontbase" "$_sd_css"; then
		rm -rf -- "$_sd_tmp"
		return 1
	fi

	# The marker is written last and is what stage_dir tests for, so an
	# interrupted build is never mistaken for a complete one.
	printf '%s\n' "$_sd_key" > "$_sd_tmp/.staged" || return 1

	# Another process may have finished the same build first; its copy is as
	# good as ours, so lose gracefully rather than clobbering a directory
	# something may already be reading.
	if [ -d "$_sd_target" ]; then
		rm -rf -- "$_sd_tmp"
	else
		mv -- "$_sd_tmp" "$_sd_target" 2>/dev/null || {
			rm -rf -- "$_sd_tmp"
			[ -d "$_sd_target" ] || return 1
		}
	fi

	printf '%s\n' "$_sd_target"
	return 0
}


# Stage the structural template.
#
#   stage_template <chain> <engine> <styler> <staged-dir>
#
# The template is selected by ecosystem rather than copied by name, which is
# the whole point of the object: engines/pandoc-* and engines/vivlio* want a
# file called article.tmpl, but they want *different* article.tmpls, and the
# old by-name staging could not tell them apart.
#
# It is staged under the template's own basename, so the engine side is
# unchanged -- pandoc's render still reads `article.tmpl` out of the theme
# directory, and the XSLT one still reads `global.tmpl`. What changed is which
# file arrives under that name.
#
# An engine that names no template stages nothing and falls back to its own
# built-in, which is what the null engine does and what any future engine with
# no template concept (remote, typst) will do.
stage_template() {  # stage_template <chain> <engine> <styler> <staged-dir>
	_stt_chain=$1
	_stt_engine=$2
	_stt_styler=$3
	_stt_out=$4

	_stt_enginedir="${ENGINES_DIR:-$PDFULATOR_DIR/engines}/$_stt_engine"

	_stt_tmpl=$(template_select "$_stt_chain" "$_stt_engine" "$_stt_styler" \
		"$_stt_enginedir") || return 1
	[ -n "$_stt_tmpl" ] || return 0

	_stt_src=$(template_structure "$_stt_tmpl") || return 1
	[ -n "$_stt_src" ] || return 0

	# Mirrored, like the stylesheets, so a template that pulls in a partial or
	# an asset by relative path finds it -- the same reason and the same
	# mechanism. See stage_styling.
	_stt_rel=$(stage_mirror_path "$(dirname -- "$_stt_src")")
	mkdir -p -- "$_stt_out/input/$_stt_rel" || return 1
	_stt_name=$(basename -- "$_stt_src")
	cp -- "$_stt_src" "$_stt_out/input/$_stt_rel/$_stt_name" || return 1

	# Whatever the structure needs beside it. The DocBook template pulls in
	# global.ent through a SYSTEM entity, which resolves relative to the
	# template's own location -- so staging the template alone gives pandoc a
	# DTD subset pointing at a file that is not there.
	template_support "$_stt_tmpl" | while IFS= read -r _stt_sup || [ -n "$_stt_sup" ]; do
		[ -n "$_stt_sup" ] || continue
		cp -- "$_stt_sup" "$_stt_out/input/$_stt_rel/" || exit 1
	done || return 1

	# The engine is TOLD what to read. Engines used to hardcode `article.tmpl`
	# or `global.tmpl` and look for it at the staged root -- a leftover from
	# when the staged directory was the theme itself. That by-name coupling is
	# what let a Mustache template reach pandoc in the first place; staging the
	# right file under the expected name fixed the symptom but kept the
	# coupling, and with it the requirement that every ecosystem agree on a
	# filename. Naming the file here removes it.
	stage_manifest_add "$_stt_out" structure "" "" \
		"input/$_stt_rel/$_stt_name" || return 1

	# NO LEGACY COPY AT THE ROOT ANY MORE. Every engine now asks the payload
	# what its structural file is called -- main.js through payload.js, both
	# pandoc renders through _lib/payload.sh -- so nothing looks for
	# `article.tmpl` or `global.tmpl` at the root, and putting one there would
	# only invite something to start depending on the name again.
	#
	# That also retires the trap the copy carried with it: a structural file at
	# the root whose SYSTEM entity resolved to nothing was worse than no file
	# at all, because pandoc failed while parsing the DTD subset before any
	# conversion began. The mirrored copy has its template.support files beside
	# it by construction, which is where they have to be.

	return 0
}


# Append one row to the staged directory's manifest.
#
#   stage_manifest_add <staged-dir> <kind> <level> <level-name> <path>
#
# One file describing everything an engine might need to find, rather than a
# convention per file type. <kind> says what the row is -- `styling` for a
# stylesheet, `structure` for the template's structural file -- and <path> is
# always relative to the staged directory, so it stays correct through a mount
# or a transfer.
stage_manifest_add() {  # stage_manifest_add <dir> <kind> <level> <name> <path>
	printf '%s\t%s\t%s\t%s\n' "$2" "${3:-}" "${4:-}" "$5" \
		>> "$1/manifest"
}


# Stage the styling cascade.
#
#   stage_styling <chain> <engine> <styler> <staged-dir> [css]
#
# Writes:
#
#   input/<kind>/<name>/...   every stylesheet, under a mirror of where it
#                             came from, with the assets beside it
#   manifest                  a row per file, appended to by every stager
#   print.css                 the same files concatenated, for engines that
#                             just want one stylesheet
#
# THE MIRROR IS WHY THIS IS NOT A FLAT COPY. Two reasons, and the second is a
# bug that a flat copy causes rather than merely a tidiness argument:
#
#   1. Basenames collide by design. themes/classic ships two files called
#      print.css, one per styler, and an inheritance chain has more. Renaming
#      them to make them fit in one directory throws away the provenance that
#      makes a staged directory readable when something looks wrong.
#
#   2. CSS resolves url() relative to the stylesheet. A theme writing
#      `background-image: url(./bg.png)` -- entirely ordinary CSS -- gets a
#      dangling reference the moment its stylesheet is moved away from its
#      assets, and a missing background image is not an error anywhere in the
#      pipeline. It just renders wrong. Keeping each stylesheet inside a mirror
#      of its own directory keeps every relative reference in it true.
#
# The mirror is keyed on <kind>/<name> -- themes/classic, templates/mustache --
# rather than on the absolute source path, because a theme may live in the
# working directory, in PDFULATOR_HOME, in the install tree or at an absolute
# path the user typed, and the staged layout should not vary with which. Where
# two directories would collide on <kind>/<name>, a counter disambiguates: it
# is the source path that is ambiguous at that point, not the mirror.
#
# Everything is COPIED in, never referenced. A staged directory has to be
# self-contained -- a container sees it through a mount and a remote engine
# receives it over a wire, and neither can open a path into the user's home.
stage_styling() {  # stage_styling <chain> <engine> <styler> <staged-dir> [css]
	_sy_chain=$1
	_sy_engine=$2
	_sy_styler=$3
	_sy_out=$4
	_sy_css=${5:-}

	_sy_enginedir="${ENGINES_DIR:-$PDFULATOR_DIR/engines}/$_sy_engine"

	_sy_list="$_sy_out/.styling.list"
	styling_list "$_sy_chain" "$_sy_engine" "$_sy_styler" "$_sy_enginedir" \
		"$_sy_css" > "$_sy_list" || { rm -f "$_sy_list"; return 1; }

	mkdir -p -- "$_sy_out/input" || return 1
	: > "$_sy_out/print.css" || return 1

	_sy_n=0

	while IFS="$(printf '\t')" read -r _sy_level _sy_file || [ -n "$_sy_level" ]; do
		[ -n "$_sy_file" ] || continue
		[ -f "$_sy_file" ] || continue

		_sy_src=$(dirname -- "$_sy_file")

		# Where this stylesheet's directory is mirrored. Shared with
		# stage_mirror_object rather than worked out again here: a selected
		# object has usually been mirrored whole already, and the stylesheet
		# must land inside that copy rather than in a second one beside it.
		_sy_rel=$(stage_mirror_alloc "$_sy_src" "$_sy_out") || return 1
		mkdir -p -- "$_sy_out/input/$_sy_rel" || return 1

		# NO SIBLING COPY HERE. An earlier version copied every file beside a
		# stylesheet so that relative url() kept working. Mirroring whole
		# objects made that redundant for anything a theme, engine or template
		# declares -- their directories arrive complete -- and left it actively
		# harmful for the one case it did not cover: --css names a file
		# ANYWHERE on the disk, so "copy its siblings" meant copying the
		# user's whole directory into the payload. Pointing --css at a file in
		# a working directory shipped two dozen unrelated PDFs and shell
		# scripts into a bundle that gets mounted into containers.
		#
		# So a stylesheet from outside a selected object arrives alone, below.
		# Relative url() from such a file does not resolve, which is the
		# honest behaviour: pdfulator has no way to know what else that
		# directory holds or whether the user meant to hand it over.

		_sy_dest="input/$_sy_rel/$(basename -- "$_sy_file")"
		# The object mirror will usually have placed it already; this covers a
		# stylesheet named from outside the directory it sits in, and --css,
		# which is any file the user pointed at.
		if [ ! -f "$_sy_out/$_sy_dest" ]; then
			cp -- "$_sy_file" "$_sy_out/$_sy_dest" || return 1
		fi

		_sy_n=$((_sy_n + 1))
		stage_manifest_add "$_sy_out" styling "$_sy_level" \
			"$(styling_level_name "$_sy_level")" "$_sy_dest" || return 1

		# The concatenation names the ORIGINAL path in its provenance comment:
		# the mirror says where a file sits in the cascade, but the comment has
		# to say which file in the user's tree to go and edit.
		#
		# Note that url() inside this concatenation resolves against print.css
		# at the root, NOT against the mirror -- which is the other half of why
		# an engine reading the manifest is better off than one reading this.
		printf '/* --- %s --- */\n' "$_sy_file" >> "$_sy_out/print.css"
		cat -- "$_sy_file" >> "$_sy_out/print.css" || return 1
		printf '\n' >> "$_sy_out/print.css"
	done < "$_sy_list"

	rm -f "$_sy_list"
	return 0
}


# Where a source directory is mirrored inside the staged directory.
#
#   stage_mirror_path <source-dir>
#
# <kind>/<name>, e.g. themes/classic, templates/html-mustache-vivlio, and with
# the sub-axis kept where there is one: themes/classic/stylers/vivliostyle.
# That last part matters -- it is exactly the case where one theme contributes
# two files of the same name.
#
# Anything that matches none of the known kinds is mirrored under external/,
# keyed by name alone: --css can point at any file on the disk, and a path from
# the user's home has no place in a directory that gets mounted or shipped.
stage_mirror_path() {  # stage_mirror_path <source-dir>
	_smp=$1

	# Walk all the way up, remembering the LAST (outermost) recognised kind
	# rather than stopping at the first. Stopping at the first is wrong for a
	# theme's own engine axis: themes/leaf/engines/E has `engines` as its
	# immediate parent, so the innermost match mirrors it to engines/E and
	# every theme in the chain lands on the same path, silently overwriting
	# the others. The outermost match keeps it under themes/leaf/engines/E.
	_smp_kind=""
	_smp_name=""
	_smp_tail=""
	_smp_seen=""
	_smp_cur=$_smp
	while [ -n "$_smp_cur" ] && [ "$_smp_cur" != "/" ] && [ "$_smp_cur" != "." ]; do
		_smp_base=$(basename -- "$_smp_cur")
		_smp_parent=$(dirname -- "$_smp_cur")
		case $(basename -- "$_smp_parent") in
			themes|templates|engines)
				_smp_kind=$(basename -- "$_smp_parent")
				_smp_name=$_smp_base
				_smp_tail=$_smp_seen
				;;
		esac
		if [ -n "$_smp_seen" ]; then
			_smp_seen="$_smp_base/$_smp_seen"
		else
			_smp_seen=$_smp_base
		fi
		_smp_cur=$_smp_parent
	done

	if [ -n "$_smp_kind" ]; then
		if [ -n "$_smp_tail" ]; then
			printf '%s/%s/%s\n' "$_smp_kind" "$_smp_name" "$_smp_tail"
		else
			printf '%s/%s\n' "$_smp_kind" "$_smp_name"
		fi
		return 0
	fi

	printf 'external/%s\n' "$(basename -- "$_smp")"
	return 0
}


# What never travels into the payload.
#
# The payload is what the engine READS; `_nopayload/` is everything else in the
# object that stays where it is. In engines/vivlio that is main.js, convert,
# node_modules and package.json -- the program itself, already installed where
# the engine runs, and pointless-to-harmful to copy into a directory that gets
# mounted into a container or sent to a remote host.
#
# The name states the rule rather than the usual contents, so a hand-written
# file that simply should not ship has an obvious home. The `_` prefix is the
# same one _payload.css uses: this directory is pdfulator's convention rather
# than the author's content, so it sorts apart and cannot collide with a theme
# that happens to have a directory of its own by that name.
#
# `_nopayload` is the convention, and it is only a default: an object states
# its exclusions in its own conf file, under the same `+` rule as every other
# list key --
#
#     do.not.payload = +convert          add to the default
#     do.not.payload = build             replace it; _nopayload now travels
#
# so the decision sits with the object that owns the files, exactly as `markup`
# and `stylesheet` do, and an object with an unusual layout has a way to say so
# rather than needing a change here.
#
# `convert` is why the exception matters. It is the engine's contract with the
# wrapper, which finds it by name at the object root (lib/engines.sh), so it
# cannot be moved in beside the rest of the program -- yet it is the program,
# and an executable in a directory that gets mounted into a container or sent
# to a remote host is at best noise and at worst something that runs. Each
# engine.conf therefore adds it.
#
# engine.conf itself always travels, and must: it is what an engine walking the
# payload reads to learn what the engine declared. Excluding an object's own
# conf file would make the payload undescribable, so it is not offered.
STAGE_NOPAYLOAD_DEFAULT="_nopayload"

# The conf file each kind of object keeps its declarations in. `do.not.payload`
# is read from whichever of these the object has; a directory with none simply
# gets the default.
STAGE_CONF_NAMES="engine.conf template.conf theme.conf theme-engine.conf \
                  theme-styler.conf theme-template.conf"


# What one object excludes from the payload.
#
#   stage_nopayload_list <source-dir>
#
# The default, plus or replaced by whatever the object's conf file declares.
# Names, not paths: a `do.not.payload` entry matches an entry in the object's
# own directory, and nested exclusions are the nested object's business.
stage_nopayload_list() {  # stage_nopayload_list <source-dir>
	_snl_dir=$1

	# Collected from every conf file the object has, then folded in one pass.
	# A `while read` at the end of a pipe runs in a subshell in POSIX sh, so
	# accumulating there and printing here would print the default every time;
	# command substitution keeps the fold in this shell.
	_snl_vals=""
	for _snl_name in $STAGE_CONF_NAMES; do
		[ -f "$_snl_dir/$_snl_name" ] || continue
		_snl_vals="$_snl_vals$(conf_get_all "$_snl_dir/$_snl_name" \
			do.not.payload 2>/dev/null)
"
	done

	_snl_out=$STAGE_NOPAYLOAD_DEFAULT
	_snl_replaced=0
	_snl_saved=$IFS
	IFS='
'
	for _snl_v in $_snl_vals; do
		[ -n "$_snl_v" ] || continue
		if styling_is_add "$_snl_v"; then
			_snl_v=${_snl_v#+}
			_snl_v=${_snl_v#"${_snl_v%%[! 	]*}"}
			_snl_out="$_snl_out $_snl_v"
		elif [ "$_snl_replaced" = 0 ]; then
			# A bare value replaces, the same reading `stylesheet = x.css`
			# has: this object's list, not the default with something added.
			# Only the first one replaces; the rest accumulate, or a second
			# bare line would silently discard the first.
			_snl_out=$_snl_v
			_snl_replaced=1
		else
			_snl_out="$_snl_out $_snl_v"
		fi
	done
	IFS=$_snl_saved

	printf '%s\n' "$_snl_out"
	return 0
}


# Where one source directory is mirrored, allocated once and remembered.
#
#   stage_mirror_alloc <source-dir> <staged-dir>
#
# stage_mirror_path says where a directory *would* go; this says where it
# actually went, which is not the same question once two stagers mirror into
# the same tree. Two different source directories can share a <kind>/<name> --
# `--theme ./classic` next to a shipped `themes/classic` -- and the second must
# land somewhere else or silently overwrite the first.
#
# The record is the authority, not the filesystem. Testing "does this directory
# exist yet" was enough while stage_styling was the only mirrorer, but a
# directory now usually exists because stage_mirror_object put it there for the
# very source being asked about -- so the existence test reads its own work as
# a clash and allocates `themes/default-2` beside `themes/default`. One record,
# consulted by everything that mirrors, cannot make that mistake.
stage_mirror_alloc() {  # stage_mirror_alloc <source-dir> <staged-dir>
	_smc_src=$1
	_smc_out=$2
	_smc_rec="$_smc_out/.mirror.map"

	# Already allocated? Then it keeps the path it was given.
	if [ -f "$_smc_rec" ]; then
		_smc_hit=$(while IFS="$(printf '\t')" read -r _s _m || [ -n "$_s" ]; do
			if [ "$_s" = "$_smc_src" ]; then printf '%s' "$_m"; break; fi
		done < "$_smc_rec")
		if [ -n "$_smc_hit" ]; then
			printf '%s\n' "$_smc_hit"
			return 0
		fi
	else
		: > "$_smc_rec" || return 1
	fi

	_smc_want=$(stage_mirror_path "$_smc_src") || return 1

	# A genuine clash: some *other* source already holds this path.
	_smc_try=$_smc_want
	_smc_i=1
	while grep -q "	$_smc_try\$" "$_smc_rec" 2>/dev/null; do
		_smc_i=$((_smc_i + 1))
		_smc_try="$_smc_want-$_smc_i"
	done

	printf '%s\t%s\n' "$_smc_src" "$_smc_try" >> "$_smc_rec" || return 1
	printf '%s\n' "$_smc_try"
	return 0
}


# Copy one selected object into the payload, minus what does not travel.
#
#   stage_mirror_object <source-dir> <staged-dir>
#
# Everything in <source-dir> is copied to its mirrored position under
# input/, EXCEPT:
#
#   - _nopayload/ at any depth, which is the object's own machinery;
#   - the {engines,templates,stylers} sub-axes, which are selections in their
#     own right: a theme has one directory per engine it knows about and only
#     the chosen one belongs in the payload.
#
# One object per call, deliberately -- the axes are mirrored by separate calls
# from stage_mirror_all rather than by recursing from here. POSIX sh has no
# locals, so a recursive call runs in this shell and overwrites every _smo_
# variable, a loop's own iteration state included: the first sub-axis was
# mirrored and the rest were silently skipped. Flat calls from one driver have
# no such state to lose.
#
# Copy-everything rather than copy-what-is-declared, because an object's files
# refer to each other in ways only the object's own ecosystem understands -- a
# Mustache partial, an @import, a SYSTEM entity, an image behind a url(). The
# alternative is a dependency scanner per ecosystem, which is what
# template.support exists to avoid needing.
#
# The conf files come too, and that is the point of this function rather than
# a side effect: with every selected object's conf file present, the payload
# describes itself and an engine can walk it -- follow `extends` from theme to
# theme, read `markup` from a template.conf -- instead of being told what to
# read by a manifest that staging had to remember to write.
stage_mirror_object() {  # stage_mirror_object <src> <out>
	_smo_src=$1
	_smo_out=$2

	[ -d "$_smo_src" ] || return 0

	_smo_rel=$(stage_mirror_alloc "$_smo_src" "$_smo_out") || return 1
	_smo_dest="$_smo_out/input/$_smo_rel"
	mkdir -p -- "$_smo_dest" || return 1

	_smo_excl=$(stage_nopayload_list "$_smo_src") || return 1

	for _smo_e in "$_smo_src"/* "$_smo_src"/.[!.]*; do
		[ -e "$_smo_e" ] || continue
		_smo_base=$(basename -- "$_smo_e")

		# Declared not to travel. `if`, not `[ ... ] && ...`: under set -e a
		# bare test that fails is a failing command, and not-excluded is the
		# common case.
		_smo_skip=0
		for _smo_x in $_smo_excl; do
			if [ "$_smo_base" = "$_smo_x" ]; then _smo_skip=1; break; fi
		done
		if [ "$_smo_skip" = 1 ]; then continue; fi

		if [ -d "$_smo_e" ]; then
			case $_smo_base in
				# A sub-axis is a selection, not content: copying the whole of
				# themes/classic/stylers would put every styler's CSS in the
				# payload, and an engine walking the tree would have no way to
				# tell which one was chosen. The caller names the selected ones
				# and they are mirrored separately.
				engines|templates|stylers) continue ;;

				# fonts/ is staged by the font mechanism, which knows about
				# roles, weights and acquisition and copies only the faces the
				# merged fonts.conf actually asks for -- under a single name
				# per face at the payload root, which is what fonts.css and
				# fop-fonts.xconf are generated to point at. Mirroring the
				# directory as well would ship every face a theme happens to
				# carry, twice over, referenced by nothing.
				fonts) continue ;;
			esac
			# `cp -R` of a directory that is content: a theme's assets/ or
			# partials/ arrive by this rule.
			cp -R -- "$_smo_e" "$_smo_dest/" || return 1
			# An exclusion nested inside a copied subtree still does not
			# travel: `assets/_nopayload/` is as much not-payload as the
			# object's own. Pruned after the copy rather than filtered during
			# it, because cp -R has no exclude and reimplementing the recursion
			# in sh to get one would be worse than deleting afterwards.
			for _smo_x in $_smo_excl; do
				find "$_smo_dest/$_smo_base" -name "$_smo_x" \
					-exec rm -rf -- {} + 2>/dev/null || :
			done
		elif [ -f "$_smo_e" ]; then
			cp -- "$_smo_e" "$_smo_dest/" || return 1
		fi
	done

	return 0
}


# Mirror every object this build selected.
#
#   stage_mirror_all <chain> <engine> <styler> <staged-dir>
#
# The engine, the template it names, every theme in the chain, and within each
# theme the engine/styler/template axes that were chosen. This is what makes
# the payload self-describing: after it, every conf file that took part in the
# build is present, at the position it occupies in the source tree.
#
# Order does not matter here -- the payload records position, not sequence, and
# the order of the cascade is recovered by the walk (a theme's `extends` names
# its parent) rather than by anything written down.
stage_mirror_all() {  # stage_mirror_all <chain> <engine> <styler> <out>
	_sma_chain=$1
	_sma_engine=$2
	_sma_styler=$3
	_sma_out=$4

	_sma_enginedir="${ENGINES_DIR:-$PDFULATOR_DIR/engines}/$_sma_engine"
	stage_mirror_object "$_sma_enginedir" "$_sma_out" || return 1

	# The template the engine or theme selected. template_select resolves the
	# same value stage_template uses, so the two cannot disagree about which
	# template the payload is for.
	_sma_tmpl=$(template_select "$_sma_chain" "$_sma_engine" "$_sma_styler" \
		"$_sma_enginedir") || return 1
	if [ -n "$_sma_tmpl" ]; then
		stage_mirror_object "$_sma_tmpl" "$_sma_out" || return 1
	fi

	# Every theme in the chain, with its selected axes. A theme that
	# contributes no stylesheet is mirrored too -- it still carries the
	# `extends` an engine follows, and leaving it out puts a hole in the walk.
	# Each theme, then each axis that theme selected -- flat calls rather than
	# a recursion, for the scope reason given on stage_mirror_object. The axis
	# directories are named here because "which engine, which styler" is this
	# function's argument list, not something an object can work out about
	# itself.
	printf '%s\n' "$_sma_chain" | while IFS= read -r _sma_dir || [ -n "$_sma_dir" ]; do
		[ -n "$_sma_dir" ] || continue
		stage_mirror_object "$_sma_dir" "$_sma_out" || exit 1
		for _sma_axis in "engines/$_sma_engine" "stylers/$_sma_styler"; do
			[ -d "$_sma_dir/$_sma_axis" ] || continue
			stage_mirror_object "$_sma_dir/$_sma_axis" "$_sma_out" || exit 1
		done
	done || return 1

	return 0
}


# Ship the payload reader inside the payload.
#
#   stage_lib <staged-dir>
#
# `_lib/payload.sh` answers "what is the structural file" and "which
# stylesheets, in what order" for the payload it sits in. It travels WITH the
# payload rather than being COPYed into an image or mounted from the host,
# because those two both produce version skew: a moving `:<engine>` tag run
# against a differently-versioned wrapper would carry two implementations of
# the §5 cascade order, differing by however many commits separate them, and
# the symptom is a wrongly-ordered stylesheet rather than an error. Travelling
# in the payload gives an engine the rules the payload was actually assembled
# under. See PAYLOAD-PLAN §14.
#
# The `_` prefix marks what the wrapper generated rather than what an author
# wrote, as _payload.css does, so it cannot collide with a mirrored object.
#
# NOT part of the staging key, and nothing has to be done to keep it that way:
# stage_key hashes the SOURCE files a build selects, never the payload it
# produces. Worth stating because §14 called for the exclusion explicitly --
# hashing these would invalidate every cached payload on every wrapper release
# for no behavioural reason. If stage_key ever grows a "hash the output"
# branch, this directory has to be skipped by it.
stage_lib() {  # stage_lib <staged-dir>
	_sli_src="${PDFULATOR_LIB:-$PDFULATOR_DIR/lib}"
	[ -d "$_sli_src/payload" ] || return 0

	_sli_out="$1/_lib"
	mkdir -p -- "$_sli_out" || return 1

	for _sli_f in "$_sli_src"/payload/*; do
		[ -f "$_sli_f" ] || continue
		cp -- "$_sli_f" "$_sli_out/" || return 1
	done

	# conf.sh is the reader payload.sh sources, and is the wrapper's own -- one
	# implementation of the conf grammar, not a copy that can drift from it.
	[ -f "$_sli_src/conf.sh" ] && { cp -- "$_sli_src/conf.sh" "$_sli_out/" || return 1; }

	chmod +x "$_sli_out/payload.sh" 2>/dev/null || :
	return 0
}


# Place the theme's logo, if it has one.
#
#   stage_logo <chain> <staged-dir>
#
# Writes logo.css into the staged directory, and records the file and position
# in `logo-params` for the engines that cannot read CSS.
#
# The generated rule is deliberately modest: it puts the image in a margin box
# at a sensible size and leaves everything else alone. A theme wanting more
# control writes its own @page rule as before -- this exists so that the common
# case, "our documents have our logo in the corner", needs no CSS at all.
stage_logo() {  # stage_logo <chain> <staged-dir>
	_sl_chain=$1
	_sl_out=$2

	# theme.conf is read from the most specific theme in the chain that sets
	# each key, so a child can add a logo to a parent that has none, or move
	# one the parent placed.
	_sl_decl=""
	_sl_pos=""
	_sl_h=""
	_sl_m=""
	printf '%s\n' "$_sl_chain" | sed '1!G;h;$!d' > "$_sl_out/.chain"
	while IFS= read -r _sl_dir || [ -n "$_sl_dir" ]; do
		[ -n "$_sl_dir" ] || continue
		[ -f "$_sl_dir/theme.conf" ] || continue
		if [ -z "$_sl_decl" ]; then
			_sl_decl=$(conf_get "$_sl_dir/theme.conf" logo.file)
		fi
		if [ -z "$_sl_pos" ]; then
			_sl_pos=$(conf_get "$_sl_dir/theme.conf" logo.position)
		fi
		if [ -z "$_sl_h" ]; then
			_sl_h=$(conf_get "$_sl_dir/theme.conf" logo.height)
		fi
		if [ -z "$_sl_m" ]; then
			_sl_m=$(conf_get "$_sl_dir/theme.conf" logo.margin)
		fi
	done < "$_sl_out/.chain"
	rm -f "$_sl_out/.chain"

	_sl_file=$(theme_logo_file "$_sl_out" "$_sl_decl") || return 1
	if [ -z "$_sl_file" ]; then
		# No logo is the ordinary case, and not an error. An empty stylesheet
		# is still written, so the template can link it unconditionally.
		printf '/* No logo in this theme. */\n' > "$_sl_out/logo.css"
		: > "$_sl_out/logo-params"
		return 0
	fi

	_sl_box=$(theme_logo_position "$_sl_pos") || return 1

	# Defaults chosen to look right rather than to be round numbers: 18pt is
	# about the height of two lines of body text, which is as large as a logo
	# can be in a margin before it competes with the page.
	_sl_height=${_sl_h:-18pt}
	_sl_margin=${_sl_m:-9pt}

	{
		printf '/* Generated by pdfulator from theme.conf. Do not edit. */\n\n'
		printf '@page {\n'
		printf '  @%s {\n' "$_sl_box"
		# `content` must be set for the box to exist at all, even though the
		# image arrives via background-image -- the quirk the README has
		# warned about since v1.
		printf '    content: "";\n'
		# The box is the height of the image plus its margin, so the margin is
		# space *around* the logo rather than something that pushes it out of
		# a fixed-size box and clips it -- which is what a hand-written rule
		# with a tall box and a small image does, and why the shipped one
		# needed nudging.
		printf '    height: %s;\n' "$_sl_height"
		printf '    margin-top: %s;\n' "$_sl_margin"
		printf '    background-image: url(%s);\n' "$_sl_file"
		printf '    background-repeat: no-repeat;\n'
		printf '    background-size: contain;\n'
		printf '    background-position: %s;\n' \
			"$(printf '%s' "$_sl_box" | tr '-' ' ')"
		printf '  }\n'
		printf '}\n'
	} > "$_sl_out/logo.css"

	# For engines that cannot read CSS. pandoc-xslt already has an
	# fo:external-graphic and a header template keyed on position, so the same
	# declaration drives it through --stringparam.
	{
		printf 'file\t%s\n' "$_sl_file"
		printf 'position\t%s\n' "$_sl_box"
	} > "$_sl_out/logo-params"

	return 0
}
