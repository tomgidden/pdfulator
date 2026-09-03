# lib/styling.sh — which stylesheets apply, in what order, and why.
#
# The cascade used to be one rule: walk the theme chain, and within each theme
# take engines/<id>/, stylers/<styler>/ and the plain file, concatenating the
# lot root-first. That is chain-outer, axis-inner, and it has a flaw that only
# shows up in a three-level chain: a *grandparent's* engines/<id>/print.css
# lands after a *child's* plain print.css, so a distant ancestor's
# engine-specific rule beats the rule the theme in front of you wrote.
#
# The settled order transposes it -- the axis is the outer grouping and the
# theme chain is the inner one:
#
#     engine's own template styling                       (lowest)
#     grandparent theme,        parent theme,        theme
#     grandparent theme-engine, parent theme-engine, theme-engine
#     grandparent theme-styler, parent theme-styler, theme-styler
#     document metadata   (stylesheet = +... in the document's YAML)
#     command line        (--css)                          (highest)
#
# Tom's reasoning, and it generalises to any axis added later: an object's X
# file is really its parent's X file with changes, so the inheritance is
# logically private to that object. Each axis is therefore its own chain,
# resolved end to end before it meets the next one. Interleaving three chains
# breaks that privacy, which is what the old order did.
#
# WHAT THIS FILE DOES NOT DO: decide the result. It returns (level, file)
# tuples and lets the engine reconcile them. A CSS engine sorts by level and
# concatenates -- that is what stage_styling does below -- but XSL-FO is not
# additive at all and may need the same set flattened in a different order.
# Baking concatenation in here would make the shared layer assume every engine
# styles like a browser, which is exactly the assumption that put a Mustache
# template into pandoc.
#
# --- A SECOND IMPLEMENTATION EXISTS. READ THIS BEFORE EDITING ----------------
#
# engines/vivlio/_nopayload/payload.js resolves this same cascade a second
# time. Not a translation of this file -- the two work from different inputs,
# and that is the point rather than an accident:
#
#     styling_list (here)   resolves from the SOURCE tree, BEFORE staging, and
#                           emits (level, path) pairs that the stager turns
#                           into print.css.
#     stylesheets() (JS)    resolves from the PAYLOAD, AFTER staging, by
#                           walking the mirror the stager built, so it can emit
#                           a <link> per sheet instead of one for print.css.
#
# Same rule, two vantage points; neither derivable from the other, which is why
# both exist. tests/payloadmatrix.sh runs both over one fixture and asserts
# they produce the same list. **A divergence raises no error** -- it renders a
# document whose stylesheets apply in the wrong order, which only an eye
# catches. That test is the whole safety net.
#
# Its fixture must stay three themes deep, with two sheets per object, and with
# the fixture engine declaring a stylesheet. Each of those three is
# load-bearing and each was added because a mutation survived without it: with
# two themes the settled and rejected orders agree; with one sheet per object
# `+`-adds and bare-replaces agree; and without an engine sheet the level-5
# band is untested -- which is exactly how this file came to omit it while the
# JS side emitted it.
#
# ADDING OR REORDERING A LEVEL MEANS EDITING BOTH, plus STYLING_LEVELS below.
# The JS side carries the level-by-level correspondence table.
#
# (lib/payload/payload.sh, staged into every payload, deliberately does NOT
# resolve the cascade: both pandoc engines link the print.css this file's
# output produced. It answers `markup` and `engine` only. A third
# implementation existed there briefly, had no consumer, and had already
# drifted before it was removed.)
#
# Requires lib/conf.sh, lib/paths.sh, lib/theme.sh and lib/template.sh.


# Levels, as numbers because sorting is how the order is enforced, paired with
# a name because the engine reading the manifest should not have to know what
# 40 means. Spaced by tens so a level can be inserted between two of these
# without renumbering the ones either side -- and something will want to: a
# per-document sidecar and a project .pdfulator.conf are both already sketched.
# 5 rather than 0 for the engine, because 0 reads like "unset" in a numeric
# field and because something may yet want to sit below it.
# 25 for theme-template rather than renumbering: the spacing exists precisely
# so an axis can be inserted without moving the ones either side, and this is
# the first time it has been used for that.
STYLING_LEVELS="5:engine 10:template 20:theme 25:theme-template \
                30:theme-engine 40:theme-styler 50:document 60:command-line"


styling_error() {  # styling_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# The name of a level, given its number. Empty for a number nothing declares.
styling_level_name() {  # styling_level_name <number>
	for _sln in $STYLING_LEVELS; do
		if [ "${_sln%%:*}" = "$1" ]; then
			printf '%s\n' "${_sln#*:}"
			return 0
		fi
	done
	return 0
}


# Resolve one `stylesheet` value against the file that declared it.
#
#   styling_resolve <value> <base-dir>
#
# A leading `+` means ADD rather than replace, and is stripped here: by the
# time a value reaches this function the caller has already decided what the
# marker means for its list. The `+` lives on the value rather than the key
# because conf_get splits on the first `=` -- `stylesheet += x` parses as
# the key `stylesheet ` with the `+` orphaned, whereas
# `stylesheet = +x` needs no grammar change at all.
#
# Paths are relative to the file that defined them, never to the caller's
# working directory, which is why <base-dir> is required rather than assumed.
styling_resolve() {  # styling_resolve <value> <base-dir>
	_sr_v=${1:-}
	[ -n "$_sr_v" ] || return 0

	# Strip the add marker and any space after it.
	case $_sr_v in
		'+'*)
			_sr_v=${_sr_v#+}
			_sr_v=${_sr_v#"${_sr_v%%[! 	]*}"}
			;;
	esac
	[ -n "$_sr_v" ] || return 0

	case $_sr_v in
		/*) _sr_p=$_sr_v ;;
		*)  _sr_p="$2/$_sr_v" ;;
	esac

	if [ ! -f "$_sr_p" ]; then
		styling_error "styling names a file that is not there: $_sr_v"
		return 1
	fi

	printf '%s\n' "$(abspath "$_sr_p")"
	return 0
}


# Whether a value replaces the list built so far.
#
#   styling_is_add <value>
#
# Returns 0 (true) for `+foo.css`, 1 for `foo.css`. A plain value replacing its
# level is what makes `stylesheet = mine.css` mean "mine, and nothing the
# parent had" -- the same wholesale-replace reading a font definition uses.
styling_is_add() {  # styling_is_add <value>
	case ${1:-} in
		'+'*) return 0 ;;
		*)    return 1 ;;
	esac
}


# Every stylesheet a theme chain contributes at one axis, root-first.
#
#   styling_axis <chain> <subdir> <conf> <level>
#
# <subdir> is "" for the plain axis, else engines/<id> or stylers/<s>. <conf>
# is the file in that directory that may declare styling.
#
# Two ways a stylesheet joins the list, and both are wanted:
#
#   - it is simply called print.css and sits there. That is how every theme
#     written before this file existed works, and it keeps working.
#   - stylesheet names it, which is how a theme adds a second sheet, or
#     names one thing while shipping several.
#
# A declaration REPLACES what the axis had so far unless it is marked `+`, so a
# child theme can discard a parent's sheet rather than only ever adding to it.
styling_axis() {  # styling_axis <chain> <subdir> <conf> <level>
	_sa_chain=$1
	_sa_sub=$2
	_sa_conf=$3
	_sa_level=$4

	# Accumulated root-first, so a child's rules come after its parent's and so
	# win by ordinary CSS precedence rather than by replacing the file. Held in
	# one newline-separated variable because a plain (unmarked) declaration has
	# to be able to DISCARD what earlier themes contributed, which a pipeline
	# printing as it goes cannot do.
	#
	# The whole loop therefore runs in this shell, not a subshell: `while read`
	# on the far side of a pipe gets its own process in most shells, and the
	# accumulator would be lost at the end of it. That is the reason for the
	# temporary file rather than `printf ... | while read`.
	_sa_out=""
	# $$ alone is not enough: all three axes are resolved in this same process,
	# and watch mode or a directory job may have several conversions running at
	# once. The level and a counter make it unique per call.
	STYLING_TMP_N=$((${STYLING_TMP_N:-0} + 1))
	_sa_tmp=${TMPDIR:-/tmp}/pdfulator-styling.$$.$_sa_level.$STYLING_TMP_N
	printf '%s\n' "$_sa_chain" > "$_sa_tmp" || return 1

	while IFS= read -r _sa_dir || [ -n "$_sa_dir" ]; do
		[ -n "$_sa_dir" ] || continue

		if [ -n "$_sa_sub" ]; then
			_sa_where="$_sa_dir/$_sa_sub"
		else
			_sa_where=$_sa_dir
		fi
		[ -d "$_sa_where" ] || continue

		# A declaration, if there is one, decides this theme's contribution and
		# suppresses the conventional filename: a theme that says what its
		# styling is has said it, and silently appending print.css as well
		# would make `stylesheet = only-this.css` untrue.
		_sa_declared=0
		if [ -f "$_sa_where/$_sa_conf" ]; then
			_sa_vals=$(conf_get_all "$_sa_where/$_sa_conf" stylesheet)
			if [ -n "$_sa_vals" ]; then
				_sa_declared=1
				# A leading unmarked value replaces everything accumulated so
				# far -- including earlier themes in the chain. That is what
				# lets a child theme reject a parent's stylesheet outright
				# instead of only ever adding to it.
				printf '%s\n' "$_sa_vals" > "$_sa_tmp.v" || return 1
				while IFS= read -r _sa_v || [ -n "$_sa_v" ]; do
					[ -n "$_sa_v" ] || continue
					if ! _sa_f=$(styling_resolve "$_sa_v" "$_sa_where"); then
						rm -f "$_sa_tmp" "$_sa_tmp.v"
						return 1
					fi
					[ -n "$_sa_f" ] || continue
					if styling_is_add "$_sa_v"; then
						_sa_out="$_sa_out$_sa_f
"
					else
						_sa_out="$_sa_f
"
					fi
				done < "$_sa_tmp.v"
				rm -f "$_sa_tmp.v"
			fi
		fi

		# No declaration: the conventional filename, if it is there. This is
		# how every theme written before this file existed contributes, and it
		# keeps working untouched.
		if [ "$_sa_declared" = 0 ] && [ -f "$_sa_where/print.css" ]; then
			_sa_out="$_sa_out$(abspath "$_sa_where/print.css")
"
		fi
	done < "$_sa_tmp"
	rm -f "$_sa_tmp"

	printf '%s' "$_sa_out" | while IFS= read -r _sa_line || [ -n "$_sa_line" ]; do
		[ -n "$_sa_line" ] || continue
		printf '%s\t%s\n' "$_sa_level" "$_sa_line"
	done
	return 0
}


# The whole cascade, as (level, file) tuples.
#
#   styling_list <chain> <engine> <styler> <engine-dir> [css]
#
# One `<level-number><TAB><path>` per line, ordered lowest level first and
# root-first within a level. The engine decides what to do with them; nothing
# here concatenates anything.
#
# The document band (level 50) is deliberately absent, and cannot be otherwise.
# Producing it means extracting YAML front matter from Markdown, and knowing
# which block is front matter rather than a YAML example in an appendix needs a
# real Markdown parser -- this repository's own README would defeat a naive
# one. So the wrapper supplies every band except the document's, and the
# engine, which already has parsing skill, splices its own band in at 50.
# Handing over tuples rather than a finished stylesheet is what makes that an
# ordinary case instead of a special one.
styling_list() {  # styling_list <chain> <engine> <styler> <engine-dir> [css]
	_sl_chain=$1
	_sl_engine=$2
	_sl_styler=$3
	_sl_enginedir=$4
	_sl_css=${5:-}

	# --- 5: the engine's own styling ------------------------------------------
	#
	# The bottom of the cascade, below even the template: an engine's sheet is
	# the most general statement there is, and everything else refines it.
	#
	# No shipped engine declares one, which is exactly why this was missing for
	# a while and why nothing caught it -- the shell produced no engine band,
	# payload.js did, and the two agreed on every payload anyone had built. A
	# stylesheet silently absent under one engine and present under another is
	# the failure that was waiting.
	if [ -n "$_sl_enginedir" ] && [ -f "$_sl_enginedir/engine.conf" ]; then
		conf_get_all "$_sl_enginedir/engine.conf" stylesheet | \
		while IFS= read -r _sl_v || [ -n "$_sl_v" ]; do
			[ -n "$_sl_v" ] || continue
			_sl_f=$(styling_resolve "$_sl_v" "$_sl_enginedir") || exit 1
			[ -n "$_sl_f" ] && printf '5\t%s\n' "$_sl_f"
		done || return 1
	fi

	# --- 10: the template's own styling ---------------------------------------
	#
	# The template knows its own DOM, so the stylesheet that makes that DOM
	# look like anything belongs with it rather than in every theme that uses
	# it. Lowest level: it is the floor a theme is written against.
	_sl_tdir=$(template_select "$_sl_chain" "$_sl_engine" "$_sl_styler" \
		"$_sl_enginedir") || return 1
	if [ -n "$_sl_tdir" ] && [ -f "$_sl_tdir/template.conf" ]; then
		conf_get_all "$_sl_tdir/template.conf" stylesheet | \
		while IFS= read -r _sl_v || [ -n "$_sl_v" ]; do
			[ -n "$_sl_v" ] || continue
			_sl_f=$(styling_resolve "$_sl_v" "$_sl_tdir") || exit 1
			[ -n "$_sl_f" ] && printf '10\t%s\n' "$_sl_f"
		done || return 1
	fi

	# --- 20/30/40: the theme chain, one axis at a time -------------------------
	#
	# The transpose that this file exists for. Each axis is walked over the
	# whole chain before the next axis starts, so a child's plain sheet cannot
	# be beaten by an ancestor's engine-specific one.
	styling_axis "$_sl_chain" "" theme.conf 20 || return 1

	# templates/ BEFORE engines/ and stylers/ (§6). The markup is what you are
	# styling; an engine's quirks are narrower than the markup they apply to,
	# and the styler paginates and so gets the last word.
	#
	# The axis is keyed on the template that was SELECTED, which template_select
	# resolved above -- not on a name the theme picks. A theme styling
	# `templates/html-mustache-vivlio/` is saying "when this markup is in play",
	# and that is only meaningful against the template actually chosen.
	if [ -n "$_sl_tdir" ]; then
		styling_axis "$_sl_chain" "templates/$(basename -- "$_sl_tdir")" \
			theme-template.conf 25 || return 1
	fi

	styling_axis "$_sl_chain" "engines/$_sl_engine" theme-engine.conf 30 || return 1
	styling_axis "$_sl_chain" "stylers/$_sl_styler" theme-styler.conf 40 || return 1

	# --- 50: the document. Not ours to produce; see above. ---------------------

	# --- 60: the command line -------------------------------------------------
	#
	# --css was special-cased in stage_build: one file, appended to print.css
	# after everything else so that "later wins" stayed a single rule. It is now
	# simply the highest level, which is the same behaviour arrived at through
	# the general mechanism rather than beside it. The spelling is unchanged.
	if [ -n "$_sl_css" ]; then
		if [ ! -f "$_sl_css" ]; then
			styling_error "no such stylesheet: $_sl_css"
			return 1
		fi
		printf '60\t%s\n' "$(abspath "$_sl_css")"
	fi

	return 0
}
