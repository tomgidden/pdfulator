# lib/stage.sh — building what an engine actually receives.
#
# The engine contract's third argument is a theme directory. Until now that was
# the theme the user named; it is now a directory this file builds, holding
# everything that theme means for this particular engine:
#
#   print.css          the CSS cascade, concatenated root-first
#   fonts.css          generated @font-face and --pdfulator-<role> properties
#   fonts/             the font files themselves
#   fop-fonts.xconf    generated FOP font configuration    (xsl-fo stylers)
#   fo-params          role -> family, for xsltproc        (xsl-fo stylers)
#   article.tmpl       the most specific template in the chain
#   metadata.lua, logo.svg, ...
#
# Built on this side of the container boundary, deliberately. An engine then
# needs to know nothing about inheritance, about where fonts come from, or
# about the user's filesystem -- it reads files out of one directory. That is
# what makes the same theme work for a bundled engine, a containerised one
# (mount the directory) and eventually a remote one (send the directory).
#
# Requires lib/conf.sh, lib/paths.sh, lib/theme.sh and lib/fonts.sh.


# Files a theme may supply that are copied through as-is, most specific
# winning. Not a cascade: a theme overriding article.tmpl replaces its
# parent's, since half a template is not a template.
STAGE_FILES="article.tmpl metadata.lua logo.svg theme.yaml global.tmpl fo.xsl"

# Files that *are* a cascade: concatenated root-first, so a child's rules come
# after -- and therefore win -- by ordinary CSS precedence rather than by
# replacing the file.
STAGE_CASCADE="print.css html.css"


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
		printf '%s\n' "$1" | while IFS= read -r _sk_dir || [ -n "$_sk_dir" ]; do
			[ -n "$_sk_dir" ] || continue
			printf '%s\n' "$_sk_dir"
			# Every file that could contribute, in a fixed order, each with its
			# content hash. A theme that changes any of them gets a new key.
			for _sk_name in $STAGE_FILES $STAGE_CASCADE fonts.conf theme.conf; do
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

		# --css last of all, so it wins over every theme in the chain. Appended
		# to print.css rather than passed separately, so that "later wins" is
		# one rule the whole way down instead of two.
		if [ "$_sb_name" = "print.css" ] && [ -n "$_sb_css" ]; then
			if [ ! -f "$_sb_css" ]; then
				stage_error "no such stylesheet: $_sb_css"
				return 1
			fi
			printf '/* --- %s (--css) --- */\n' "$_sb_css" \
				>> "$_sb_out/$_sb_name"
			cat -- "$_sb_css" >> "$_sb_out/$_sb_name" || return 1
			printf '\n' >> "$_sb_out/$_sb_name"
		fi
	done

	# --- Single files: most specific wins ---------------------------------------
	for _sb_name in $STAGE_FILES; do
		_sb_src=$(theme_file_one "$_sb_chain" "$_sb_engine" "$_sb_styler" "$_sb_name")
		if [ -n "$_sb_src" ] && [ -f "$_sb_src" ]; then
			cp -- "$_sb_src" "$_sb_out/$_sb_name" || return 1
		fi
	done

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

	# FOP config only where it means something. A vivlio theme with a stray
	# fop-fonts.xconf in it is harmless but misleading.
	if [ "$_sb_styler" = "xsl-fo" ]; then
		fonts_fop_xconf "$_sb_merged" "$_sb_out/fonts" "$_sb_fontbase" \
			"$_sb_out/fop-fonts.xconf" || return 1
	fi

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
