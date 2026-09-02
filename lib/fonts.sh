# lib/fonts.sh — the font specification, and what engines get made out of it.
#
# A theme declares fonts by *role* -- body, heading, mono -- rather than by
# name, so that a theme wanting Palatino instead of Garamond is a change to one
# file and not a rewrite of every stylesheet and stylesheet-equivalent. The
# role is what the CSS and the XSL refer to; the family behind it is the
# theme's business.
#
# That indirection is also what makes this work across engines that have
# nothing in common. CSS wants a *file it can fetch by URL* and treats the
# family name as a label; FOP and (later) Typst want a *family name they can
# match*, and are handed files separately. Neither can be expressed in the
# other's terms -- but both can be generated from the same declaration, which
# is what fonts_css, fonts_fop_xconf and fonts_fo_params do.
#
# Requires lib/conf.sh. Sourced, never executed.
#
#
# THE FORMAT
#
#   body.family                    = TeX Gyre Pagella
#   body.source                    = local
#   body.face.400.normal.file      = fonts/texgyrepagella-regular.otf
#   body.face.400.italic.file      = fonts/texgyrepagella-italic.otf
#   body.face.700.normal.file      = fonts/texgyrepagella-bold.otf
#
#   heading.family                 = Open Sans
#   heading.source                 = url
#   heading.face.400.normal.url    = https://example.org/OpenSans-Regular.ttf
#   heading.face.400.normal.sha256 = a1b2c3...
#
# Flat key=value for the reason lib/conf.sh gives: a theme is data, and a theme
# that could run code by being read is a theme nobody should install. Themes
# are the thing this tool will eventually let people share, so that matters
# here more than it does for engine.conf.
#
# A face is identified by weight and style, because that pair is exactly what
# every target needs and no more: CSS wants font-weight/font-style, FOP wants a
# font-triplet's weight and style. Naming faces this way rather than listing
# files in order means a theme can supply only the faces it has -- regular and
# bold, no italic -- without placeholders.
#
#
# SOURCES
#
#   local   a file inside the theme, relative to the conf that declared it
#   url     an explicit URL per face, with an optional sha256
#   none    the base-14 PDF fonts; no file, no download  (see fonts_base14)
#
# Deliberately not `google` or `npm` yet. Both are wanted -- a theme saying
# `source = google` and nothing else is the nicest thing to write -- but
# `npm` needs a JS runtime, and pandoc-xslt and pandoc-pagedjs are
# needs_runtime=none by design: acquiring a font must not be the thing that
# drags bun onto the host. They arrive in 3.0.2 alongside theme import.


# The roles the core knows how to wire into every engine.
#
# A theme may declare others, and they are carried into CSS as custom
# properties -- but only these three can be given to FOP or Typst, which have
# a fixed idea of what a document's fonts are for. An invented `pullquote`
# role has no generic meaning to a typesetter, so CSS stylers honour it and
# the rest ignore it.
FONT_ROLES_KNOWN="body heading mono"

# What a role falls back to with no font of its own: the base-14 fonts every
# PDF reader has, which need no file and no network.
#
# This is what makes the whole download-on-first-use design acceptable. The
# unthemed case must render offline, immediately, with nothing fetched; if the
# floor needed a download, first run would be a cliff.
# EMPTY for a role the core does not know. An invented role has no base-14
# equivalent -- there is no "the standard pullquote font" -- and returning Times
# for it was a bug: a theme declaring `pullquote` with a real font got
# `--pdfulator-pullquote: Times, serif` whatever it asked for, because this fell
# through its `*)` arm. Callers must handle empty rather than assume a name.
fonts_base14() {  # fonts_base14 <role>
	case $1 in
		body)    printf 'Times\n' ;;
		mono)    printf 'Courier\n' ;;
		heading) printf 'Helvetica\n' ;;
		*)       printf '\n' ;;
	esac
}


fonts_error() {  # fonts_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# Every font id defined in a conf file, deduplicated, in first-appearance order.
#
# An id is the segment after `font.`, so `font.pagella.name` and
# `font.pagella.face.400.normal.file` both name `pagella`. Anything not under
# `font.` is skipped -- `style.body.font` is a BINDING, not a definition, and
# is read separately by fonts_bindings.
#
# A font is defined as a unit and merges wholesale per id (§7): the face keys
# and the role binding are different keys, so a partial override that pairs one
# family's name with another's glyph files is not representable.
fonts_ids() {  # fonts_ids <conf>
	[ -f "$1" ] || return 0

	_fr_seen=""
	conf_keys "$1" | while IFS= read -r _fr_key; do
		case $_fr_key in
			font.*.*) ;;
			*)        continue ;;
		esac
		_fr_rest=${_fr_key#font.}
		_fr_role=${_fr_rest%%.*}
		[ -n "$_fr_role" ] || continue

		# Space-delimited membership test, with the haystack padded so that
		# `body` does not match inside `bodytext`.
		case " $_fr_seen " in
			*" $_fr_role "*) continue ;;
		esac
		_fr_seen="$_fr_seen $_fr_role"
		printf '%s\n' "$_fr_role"
	done
}


# Every face a role declares, as `<weight> <style>` lines.
#
# Read off the keys rather than from a list the theme has to maintain in two
# places: `body.face.400.italic.file` *is* the declaration that body has a 400
# italic. A theme cannot then name a face it has no file for, which is the
# Sabon shape of mistake -- a font named in one place and absent from another.
fonts_faces() {  # fonts_faces <conf> <font-id>
	[ -f "$1" ] || return 0

	_ff_seen=""
	conf_keys "$1" | while IFS= read -r _ff_key; do
		case $_ff_key in
			font."$2".face.*.*.*) ;;
			*) continue ;;
		esac
		_ff_key=${_ff_key#font.}

		# $2.face.<weight>.<style>.<attr> -- strip the known head, then take
		# the first two remaining components.
		_ff_rest=${_ff_key#"$2".face.}
		_ff_weight=${_ff_rest%%.*}
		_ff_rest=${_ff_rest#*.}
		_ff_style=${_ff_rest%%.*}
		[ -n "$_ff_weight" ] && [ -n "$_ff_style" ] || continue

		case " $_ff_seen " in
			*" $_ff_weight/$_ff_style "*) continue ;;
		esac
		_ff_seen="$_ff_seen $_ff_weight/$_ff_style"
		printf '%s %s\n' "$_ff_weight" "$_ff_style"
	done
}


# Which font each role uses, as `<role> <font-id>` lines.
#
#   fonts_bindings <conf>
#
# Read from `style.<role>.font` keys. The binding is a reference by ID, not by
# family name (§7): ids are unique because they are key prefixes in one
# namespace, a correction to a font's `name` must not unresolve every reference
# to it, and ids are bare words so conf_get's split-on-first-`=` needs no
# quoting rules.
#
# Only `.font` -- every other `style.<x>.<prop>` is an ordinary portable
# variable (§12) and means nothing here.
fonts_bindings() {  # fonts_bindings <conf>
	[ -f "$1" ] || return 0

	conf_keys "$1" | while IFS= read -r _fb_key; do
		case $_fb_key in
			style.*.font) ;;
			*) continue ;;
		esac
		_fb_role=${_fb_key#style.}
		_fb_role=${_fb_role%.font}
		[ -n "$_fb_role" ] || continue
		_fb_id=$(conf_get "$1" "$_fb_key")
		[ -n "$_fb_id" ] || continue
		printf '%s %s\n' "$_fb_role" "$_fb_id"
	done
}


# Merge a cascade of conf files into one role-keyed table.
#
#   fonts_merge <out> <conf>...
#
# Two different things are merged here, by two different rules, because they
# are two different kinds of declaration (§7):
#
#   font.<id>.*        a font DEFINITION -- merged wholesale per id. A font is
#                      one indivisible thing: its name and its face files
#                      describe the same typeface, and a later conf mentioning
#                      an id at all replaces the whole definition.
#
#   style.<x>.font     a role BINDING -- single-valued, later wins, exactly
#                      like `extends` or `template`.
#
# Keeping them apart is what makes a partial override unrepresentable. The
# earlier design had face keys and the family name under one `<role>.` prefix,
# so per-key merging could pair one family's NAME with another's GLYPH FILES --
# roman in Baskerville, every italic and bold in Pagella, under an @font-face
# asserting all of it was Baskerville. Nothing reported a problem: the faces
# have different weight/style descriptors, so the CSS rule that a later
# @font-face replaces an identical earlier one never fires.
#
# THE OUTPUT IS STILL ROLE-KEYED. Bindings are resolved here, so every reader
# downstream (fonts_css, fonts_fo_params, fonts_acquire, fonts_fop_xconf) sees
# `<role>.name`, `<role>.face.400.normal.file` and so on, exactly as before.
# The definition/binding split is a fact about the SOURCE conf files, not about
# this table.
#
# Each output line is prefixed with the directory of the file it came from, so
# that a `local` path stays relative to the conf that declared it after the
# merge has moved it. That prefix is stripped by the readers below.
fonts_merge() {  # fonts_merge <out> <conf>...
	_fm_out=$1
	shift

	: > "$_fm_out" || return 1

	# Reverse the file list once: walking backwards and skipping what is
	# already taken gives later-wins without a second pass, for both the
	# bindings and the definitions.
	_fm_files=""
	for _fm_f in "$@"; do
		[ -f "$_fm_f" ] || continue
		_fm_files="$_fm_f${_fm_files:+
}$_fm_files"
	done

	# --- Bindings: role -> font id, most specific conf wins ------------------
	#
	# Collected to a temp file rather than a variable: the dedupe needs state
	# across lines, and a `while read` fed by a pipe runs in a subshell where
	# any variable it sets is discarded. A file is the state.
	_fm_pairs="$_fm_out.pairs"
	: > "$_fm_pairs" || return 1

	printf '%s\n' "$_fm_files" | while IFS= read -r _fm_file; do
		[ -n "$_fm_file" ] || continue
		[ -f "$_fm_file" ] || continue
		fonts_bindings "$_fm_file"
	done > "$_fm_pairs.all"

	_fm_bound=""
	while IFS=' ' read -r _fm_role _fm_id; do
		[ -n "$_fm_role" ] && [ -n "$_fm_id" ] || continue
		case " $_fm_bound " in
			*" $_fm_role "*) continue ;;
		esac
		_fm_bound="$_fm_bound $_fm_role"
		printf '%s %s\n' "$_fm_role" "$_fm_id" >> "$_fm_pairs"
	done < "$_fm_pairs.all"
	rm -f "$_fm_pairs.all"

	# --- Definitions: the most specific conf defining each bound id ----------
	while IFS=' ' read -r _fm_role _fm_id; do
		[ -n "$_fm_role" ] && [ -n "$_fm_id" ] || continue

		printf '%s\n' "$_fm_files" | while IFS= read -r _fm_file; do
			[ -n "$_fm_file" ] || continue
			[ -f "$_fm_file" ] || continue

			fonts_defines "$_fm_file" "$_fm_id" || continue

			_fm_dir=$(dirname -- "$_fm_file")
			conf_keys "$_fm_file" | while IFS= read -r _fm_key; do
				case $_fm_key in
					font."$_fm_id".*) ;;
					*) continue ;;
				esac
				# Re-keyed from font.<id>.X to <role>.X, so every reader
				# downstream of here is unchanged.
				printf '%s\t%s\t%s\n' "$_fm_dir" \
					"$_fm_role.${_fm_key#font."$_fm_id".}" \
					"$(conf_get "$_fm_file" "$_fm_key")"
			done
			break
		done
	done < "$_fm_pairs" >> "$_fm_out"

	rm -f "$_fm_pairs"
	return 0
}


# Does this conf define this font id? Status only, for use as a test.
fonts_defines() {  # fonts_defines <conf> <font-id>
	[ -f "$1" ] || return 1
	conf_keys "$1" | while IFS= read -r _fdf_key; do
		case $_fdf_key in
			font."$2".*) printf 'y\n'; break ;;
		esac
	done | grep -q y
}


# Read one key back out of a merged file. Empty when absent.
fonts_merged_get() {  # fonts_merged_get <merged> <key>
	[ -f "$1" ] || return 1
	while IFS="$(printf '\t')" read -r _fg_dir _fg_key _fg_val; do
		if [ "$_fg_key" = "$2" ]; then
			printf '%s\n' "$_fg_val"
			return 0
		fi
	done < "$1"
	printf '\n'
	return 0
}


# The directory the key was declared in -- what a `local` path is relative to.
fonts_merged_dir() {  # fonts_merged_dir <merged> <key>
	[ -f "$1" ] || return 1
	while IFS="$(printf '\t')" read -r _fd_dir _fd_key _fd_val; do
		if [ "$_fd_key" = "$2" ]; then
			printf '%s\n' "$_fd_dir"
			return 0
		fi
	done < "$1"
	printf '\n'
	return 0
}


# The roles present in a merged file, in order.
fonts_merged_roles() {  # fonts_merged_roles <merged>
	[ -f "$1" ] || return 0
	_fmr_seen=""
	while IFS="$(printf '\t')" read -r _fmr_dir _fmr_key _fmr_val; do
		case $_fmr_key in
			*.*) ;;
			*)   continue ;;
		esac
		_fmr_role=${_fmr_key%%.*}
		case " $_fmr_seen " in
			*" $_fmr_role "*) continue ;;
		esac
		_fmr_seen="$_fmr_seen $_fmr_role"
		printf '%s\n' "$_fmr_role"
	done < "$1"
}


# The faces of a role in a merged file, as `<weight> <style>` lines.
fonts_merged_faces() {  # fonts_merged_faces <merged> <role>
	[ -f "$1" ] || return 0
	_fmf_seen=""
	while IFS="$(printf '\t')" read -r _fmf_dir _fmf_key _fmf_val; do
		case $_fmf_key in
			"$2".face.*.*.*) ;;
			*) continue ;;
		esac
		_fmf_rest=${_fmf_key#"$2".face.}
		_fmf_weight=${_fmf_rest%%.*}
		_fmf_rest=${_fmf_rest#*.}
		_fmf_style=${_fmf_rest%%.*}
		[ -n "$_fmf_weight" ] && [ -n "$_fmf_style" ] || continue
		case " $_fmf_seen " in
			*" $_fmf_weight/$_fmf_style "*) continue ;;
		esac
		_fmf_seen="$_fmf_seen $_fmf_weight/$_fmf_style"
		printf '%s %s\n' "$_fmf_weight" "$_fmf_style"
	done < "$1"
}


# --- Acquisition -------------------------------------------------------------
#
# Turning a declaration into files on disk. Downloads land in a shared store
# under $PDFULATOR_HOME, keyed by family and face, so two themes wanting Open
# Sans fetch it once between them and an --update does not throw it away.
#
# Announced, never prompted, for the reason lib/container.sh gives about
# images: this runs in CI and in scripts, where a prompt is a hang.


# Where a face is cached. Family names contain spaces and the odd comma, so
# they are flattened to a filesystem-safe form -- lowercased, non-alphanumerics
# collapsed to a dash.
fonts_slug() {  # fonts_slug <string>
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | \
		sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}


fonts_store() {  # fonts_store <family> <weight> <style> <ext>
	printf '%s/fonts/%s/%s-%s.%s\n' \
		"${PDFULATOR_HOME:-$HOME/.local/share/pdfulator}" \
		"$(fonts_slug "$1")" "$2" "$3" "$4"
}


# Download a URL to a path. curl or wget, whichever is present -- the same
# choice install.sh makes, and for the same reason: neither is universal.
fonts_fetch() {  # fonts_fetch <url> <dest>
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$2" "$1"
	else
		fonts_error "need curl or wget to download fonts."
		return 1
	fi
}


# Acquire one face into the staging directory.
#
#   fonts_acquire <merged> <role> <weight> <style> <stage-fonts-dir>
#
# Prints the basename of the file it placed, so the generators can refer to it
# without repeating the naming rule.
#
# A face that cannot be acquired is a failure, not a silent fallback. That is
# the whole point of declaring fonts: a declaration that is never checked is
# how a font gets named in one place, omitted from another, and quietly
# replaced by Times for years. $PDFULATOR_FONT_FALLBACK downgrades it to a
# warning for the case where rendering *something* matters more -- CI smoke
# tests, an offline machine -- and it is opt-in because the default should be
# to notice.
fonts_acquire() {  # fonts_acquire <merged> <role> <weight> <style> <dest-dir>
	_fa_merged=$1
	_fa_role=$2
	_fa_weight=$3
	_fa_style=$4
	_fa_dest=$5

	_fa_family=$(fonts_merged_get "$_fa_merged" "$_fa_role.name")
	_fa_source=$(fonts_merged_get "$_fa_merged" "$_fa_role.source")
	_fa_key="$_fa_role.face.$_fa_weight.$_fa_style"

	case $_fa_source in
		local)
			_fa_rel=$(fonts_merged_get "$_fa_merged" "$_fa_key.file")
			_fa_base=$(fonts_merged_dir "$_fa_merged" "$_fa_key.file")
			[ -n "$_fa_rel" ] || {
				fonts_font_missing "$_fa_role" "$_fa_family" "local" \
					"no file given for $_fa_weight/$_fa_style" || return 1
				printf '\n'
				return 0
			}
			# An absolute path in a theme is taken as given; a relative one is
			# relative to the conf that declared it, which is why the merge
			# carries that directory along.
			case $_fa_rel in
				/*) _fa_src=$_fa_rel ;;
				*)  _fa_src="$_fa_base/$_fa_rel" ;;
			esac
			[ -f "$_fa_src" ] || {
				fonts_font_missing "$_fa_role" "$_fa_family" "local" \
					"no such file: $_fa_src" || return 1
				printf '\n'
				return 0
			}
			_fa_ext=${_fa_src##*.}
			_fa_out="$_fa_dest/$(fonts_slug "$_fa_family")-$_fa_weight-$_fa_style.$_fa_ext"
			cp -- "$_fa_src" "$_fa_out" || return 1
			printf '%s\n' "$(basename -- "$_fa_out")"
			return 0
			;;

		url)
			_fa_url=$(fonts_merged_get "$_fa_merged" "$_fa_key.url")
			[ -n "$_fa_url" ] || {
				fonts_font_missing "$_fa_role" "$_fa_family" "url" \
					"no url given for $_fa_weight/$_fa_style" || return 1
				printf '\n'
				return 0
			}
			# The extension comes from the URL, since that is what decides
			# whether FOP can read it at all: it has no WOFF2 support, so a
			# theme that wants to work with pandoc-xslt must name .ttf or .otf.
			_fa_ext=${_fa_url##*.}
			case $_fa_ext in
				ttf|otf|woff|woff2) ;;
				*) _fa_ext=ttf ;;
			esac

			_fa_cached=$(fonts_store "$_fa_family" "$_fa_weight" "$_fa_style" "$_fa_ext")
			if [ ! -f "$_fa_cached" ]; then
				mkdir -p -- "$(dirname -- "$_fa_cached")" || return 1
				printf 'Fetching %s (%s %s)...\n' \
					"$_fa_family" "$_fa_weight" "$_fa_style" >&2
				fonts_fetch "$_fa_url" "$_fa_cached.part" || {
					rm -f -- "$_fa_cached.part"
					fonts_font_missing "$_fa_role" "$_fa_family" "$_fa_url" \
						"download failed" || return 1
					printf '\n'
					return 0
				}

				# Verified before it is moved into place, so a bad download is
				# never cached as a good one.
				_fa_want=$(fonts_merged_get "$_fa_merged" "$_fa_key.sha256")
				if [ -n "$_fa_want" ]; then
					_fa_got=$(conf_hash_file "$_fa_cached.part")
					if [ "$_fa_want" != "$_fa_got" ]; then
						rm -f -- "$_fa_cached.part"
						fonts_error "checksum mismatch for $_fa_family ($_fa_weight $_fa_style)."
						printf '  expected %s\n' "$_fa_want" >&2
						printf '  actual   %s\n' "$_fa_got" >&2
						printf '  from     %s\n' "$_fa_url" >&2
						return 1
					fi
				fi
				mv -- "$_fa_cached.part" "$_fa_cached" || return 1
			fi

			_fa_out="$_fa_dest/$(fonts_slug "$_fa_family")-$_fa_weight-$_fa_style.$_fa_ext"
			# Hardlinked rather than copied: the store and the staging
			# directory are both under $PDFULATOR_HOME, so this is nearly
			# always the same filesystem, and a 1.7MB variable font copied per
			# theme adds up. Falls back to a copy when it is not.
			cp -l -- "$_fa_cached" "$_fa_out" 2>/dev/null || \
				cp -- "$_fa_cached" "$_fa_out" || return 1
			printf '%s\n' "$(basename -- "$_fa_out")"
			return 0
			;;

		none|'')
			# No file to acquire: the role renders in a base-14 font.
			printf '\n'
			return 0
			;;

		*)
			fonts_font_missing "$_fa_role" "$_fa_family" "$_fa_source" \
				"unknown source (expected local, url or none)" || return 1
			printf '\n'
			return 0
			;;
	esac
}


# How a font that cannot be had is reported.
#
# Names the role, the font and the source, because those are the three things
# that tell a theme author which line to look at.
#
# The return status *is* the decision: 0 under $PDFULATOR_FONT_FALLBACK, so the
# caller carries on with a base-14 font, and 1 otherwise, so it stops. Callers
# simply propagate it. Reporting and deciding are one thing here because they
# have one input -- whether the user asked to be lenient -- and splitting them
# only invites a caller to report and then decide differently.
fonts_font_missing() {  # fonts_font_missing <role> <family> <source> <reason>
	if [ -n "${PDFULATOR_FONT_FALLBACK:-}" ]; then
		printf 'Warning: falling back to a standard font for "%s".\n' "$1" >&2
		printf '  wanted %s (%s): %s\n' "$2" "$3" "$4" >&2
		return 0
	fi

	fonts_error "this theme needs a font it cannot get."
	printf '  role:   %s\n' "$1" >&2
	printf '  font:   %s (%s)\n' "$2" "$3" >&2
	printf '  reason: %s\n' "$4" >&2
	printf '\n' >&2
	printf 'Render anyway with standard PDF fonts:\n' >&2
	printf '  pdfulator --font-fallback ...\n' >&2
	return 1
}


# --- Generators ---------------------------------------------------------------
#
# One declaration, three targets. Each generator writes a file into the staging
# directory; the engine reads the one that suits it and never sees the others.
#
# This is where the role indirection earns its keep. A theme says "body is
# Palatino"; CSS gets an @font-face plus a custom property, FOP gets a triplet
# per face, XSL gets a family name to match on. None of those three could be
# derived from either of the others.


# CSS: @font-face per acquired face, and a custom property per role.
#
#   fonts_css <merged> <fonts-dir> <out>
#
# The custom properties are the interface a theme's stylesheet writes against:
#
#   body { font-family: var(--pdfulator-body); }
#
# so a stylesheet never names a font, and swapping the font is a theme.conf
# change with no CSS edit. The fallback in each property is the base-14 name
# for that role, which means a role that failed to acquire under
# --font-fallback still renders in something sensible rather than in the
# browser's default.
#
# Paths are relative (fonts/<file>) because the staging directory is served or
# mounted as a unit, and an absolute host path would be meaningless inside a
# container.
fonts_css() {  # fonts_css <merged> <fonts-dir> <out>
	_fc_merged=$1
	_fc_fontsdir=$2
	_fc_out=$3

	{
		printf '/* Generated by pdfulator from the font declarations. Do not edit. */\n\n'

		for _fc_role in $(fonts_merged_roles "$_fc_merged"); do
			_fc_family=$(fonts_merged_get "$_fc_merged" "$_fc_role.name")
			[ -n "$_fc_family" ] || continue

			fonts_merged_faces "$_fc_merged" "$_fc_role" | \
			while read -r _fc_weight _fc_style; do
				[ -n "$_fc_weight" ] || continue
				_fc_file=$(fonts_face_file "$_fc_fontsdir" "$_fc_family" \
					"$_fc_weight" "$_fc_style")
				[ -n "$_fc_file" ] || continue

				printf '@font-face {\n'
				printf '  font-family: %s;\n' "$(fonts_css_quote "$_fc_family")"
				printf '  font-style: %s;\n' "$_fc_style"
				printf '  font-weight: %s;\n' "$_fc_weight"
				printf '  font-display: swap;\n'
				printf '  src: url(fonts/%s) format(%s);\n' \
					"$_fc_file" "$(fonts_css_format "$_fc_file")"
				printf '}\n'
			done
		done

		printf '\n:root {\n'
		for _fc_role in $(fonts_merged_roles "$_fc_merged"); do
			_fc_family=$(fonts_merged_get "$_fc_merged" "$_fc_role.name")
			[ -n "$_fc_family" ] || continue

			# A role whose faces all failed to acquire -- which only happens
			# under --font-fallback, since otherwise the build has already
			# stopped -- must NOT name its declared family here. There is no
			# @font-face for it, so the browser would silently fall through and
			# render in something the theme never asked for. Naming the base-14
			# font instead makes the substitution the one the warning
			# announced. This is the Sabon failure exactly: a font named in one
			# place, absent from another, and quietly replaced.
			#
			# THE GENERIC TAIL GOES WITH IT. `--pdfulator-body: "Sabon", serif`
			# reads like prudence and is the opposite: when acquisition
			# succeeded the tail is unreachable, and when it failed it is a
			# silent substitution -- the very thing the branch above exists to
			# prevent. The wrapper knows every file it placed, so the family it
			# names is the family that renders. A tail is only correct where the
			# name might not resolve, and here it always does.
			if [ -z "$(fonts_role_has_file "$_fc_merged" "$_fc_fontsdir" "$_fc_role")" ]; then
				# An INVENTED role has no base-14 equivalent, so there is
				# nothing honest to substitute: emit no property at all rather
				# than one naming a font the theme never asked for. A
				# stylesheet using it falls back to whatever it already had,
				# which is the truthful outcome.
				_fc_family=$(fonts_base14 "$_fc_role")
				if [ -n "$_fc_family" ]; then
					printf '  --pdfulator-%s: %s, %s;\n' "$_fc_role" \
						"$(fonts_css_quote "$_fc_family")" \
						"$(fonts_css_generic "$_fc_role")"
				fi
			else
				printf '  --pdfulator-%s: %s;\n' "$_fc_role" \
					"$(fonts_css_quote "$_fc_family")"
			fi
		done

		# Roles the theme never mentioned still get a property, so a stylesheet
		# may use var(--pdfulator-mono) without knowing whether this particular
		# theme customised it. Without this a theme that sets only `body` would
		# leave the others resolving to nothing at all.
		for _fc_role in $FONT_ROLES_KNOWN; do
			_fc_family=$(fonts_merged_get "$_fc_merged" "$_fc_role.name")
			if [ -z "$_fc_family" ]; then
				printf '  --pdfulator-%s: %s, %s;\n' "$_fc_role" \
					"$(fonts_base14 "$_fc_role")" \
					"$(fonts_css_generic "$_fc_role")"
			fi
		done
		printf '}\n'
	} > "$_fc_out"
}


# A family name as a CSS value.
#
# Quoted unless it is a single bare word. An unquoted family name must be a
# sequence of CSS identifiers, so `Helvetica` is fine but `TeX Gyre Pagella`
# is three identifiers -- legal by the letter of the grammar, but only when
# every one of them is a valid identifier, and a name beginning with a digit
# or containing a comma is not. Quoting anything that is not one plain word
# sidesteps the whole question, and is what every real stylesheet does.
fonts_css_quote() {  # fonts_css_quote <family>
	case $1 in
		''|*[!A-Za-z0-9-]*) printf '"%s"\n' "$1" ;;
		*)                  printf '%s\n' "$1" ;;
	esac
}


# The generic family a role degrades to when nothing else matches.
# The CSS generic family for a role, or empty for one the core does not know --
# an invented role has no generic meaning, and `serif` was as wrong for it as
# Times was.
fonts_css_generic() {  # fonts_css_generic <role>
	case $1 in
		body)    printf 'serif\n' ;;
		mono)    printf 'monospace\n' ;;
		heading) printf 'sans-serif\n' ;;
		*)       printf '\n' ;;
	esac
}


# The CSS format() keyword for a file, taken from its extension. Chromium is
# forgiving about this, but a wrong keyword is exactly the kind of thing that
# works in one renderer and not the next.
fonts_css_format() {  # fonts_css_format <filename>
	case ${1##*.} in
		otf)   printf "'opentype'\n" ;;
		ttf)   printf "'truetype'\n" ;;
		woff)  printf "'woff'\n" ;;
		woff2) printf "'woff2'\n" ;;
		*)     printf "'truetype'\n" ;;
	esac
}


# Find the staged file for a face, whatever extension it ended up with.
# Acquisition names files <family-slug>-<weight>-<style>.<ext>, so this is a
# glob rather than a lookup -- the extension depends on what the theme
# supplied, and no caller should have to track it.
fonts_face_file() {  # fonts_face_file <fonts-dir> <family> <weight> <style>
	_fff_slug=$(fonts_slug "$2")
	for _fff_c in "$1/$_fff_slug-$3-$4."*; do
		[ -f "$_fff_c" ] || continue
		basename -- "$_fff_c"
		return 0
	done
	printf '\n'
	return 0
}


# FOP: an explicit <font>/<font-triplet> per face.
#
#   fonts_fop_xconf <merged> <fonts-dir> <font-base> <out>
#
# Explicit rather than the <directory> scan the engine ships today. A scan
# makes FOP derive triplets from each file's internal metadata, so the weight
# a face registers under is whatever the foundry wrote in it -- which is how a
# document asking for 600 silently gets 400. Naming the triplet here means the
# weight the theme declared is the weight FOP matches.
#
# <font-base> is the path the fonts will be at *when FOP runs*, which is not
# where they are now: for a container engine the staging directory arrives at a
# mount point. The caller knows that path; this function does not guess it.
fonts_fop_xconf() {  # fonts_fop_xconf <merged> <fonts-dir> <font-base> <out>
	_fx_merged=$1
	_fx_fontsdir=$2
	_fx_base=$3
	_fx_out=$4

	{
		printf '<?xml version="1.0"?>\n'
		printf '<!-- Generated by pdfulator from the font declarations. Do not edit. -->\n'
		printf '<fop version="1.0">\n'
		printf '  <renderers>\n'
		printf '    <renderer mime="application/pdf">\n'
		printf '      <filterList>\n'
		printf '        <value>flate</value>\n'
		printf '      </filterList>\n'
		printf '      <fonts>\n'

		for _fx_role in $(fonts_merged_roles "$_fx_merged"); do
			_fx_family=$(fonts_merged_get "$_fx_merged" "$_fx_role.name")
			[ -n "$_fx_family" ] || continue

			fonts_merged_faces "$_fx_merged" "$_fx_role" | \
			while read -r _fx_weight _fx_style; do
				[ -n "$_fx_weight" ] || continue
				_fx_file=$(fonts_face_file "$_fx_fontsdir" "$_fx_family" \
					"$_fx_weight" "$_fx_style")
				[ -n "$_fx_file" ] || continue

				# FOP cannot read WOFF or WOFF2 at all. Silently omitting the
				# face would give a PDF in the wrong typeface -- the exact
				# failure this design exists to prevent -- so it is named.
				case ${_fx_file##*.} in
					woff|woff2)
						printf 'Warning: FOP cannot use %s for %s (%s); skipping.\n' \
							"${_fx_file##*.}" "$_fx_family" "$_fx_role" >&2
						continue
						;;
				esac

				printf '        <font embed-url="%s/%s">\n' "$_fx_base" "$_fx_file"
				printf '          <font-triplet name="%s" style="%s" weight="%s"/>\n' \
					"$(fonts_xml_escape "$_fx_family")" "$_fx_style" "$_fx_weight"
				printf '        </font>\n'
			done
		done

		printf '      </fonts>\n'
		printf '    </renderer>\n'
		printf '  </renderers>\n'
		printf '</fop>\n'
	} > "$_fx_out"
}


# Did any face of this role actually get staged?
#
# The declaration says what a theme wants; this says what it got. They differ
# only under --font-fallback, and every generator has to prefer the second.
fonts_role_has_file() {  # fonts_role_has_file <merged> <fonts-dir> <role>
	_frh_family=$(fonts_merged_get "$1" "$3.name")
	[ -n "$_frh_family" ] || return 0

	# `source = none` is the base-14 case: no file is WANTED, so "no file
	# found" is success rather than a missing font. Without this a role bound
	# to a base-14 font looks like an acquisition failure and is dropped.
	if [ "$(fonts_merged_get "$1" "$3.source")" = none ]; then
		printf 'yes\n'
		return 0
	fi

	fonts_merged_faces "$1" "$3" | while read -r _frh_w _frh_s; do
		[ -n "$_frh_w" ] || continue
		if [ -n "$(fonts_face_file "$2" "$_frh_family" "$_frh_w" "$_frh_s")" ]; then
			printf 'yes\n'
			return 0
		fi
	done | head -1
}


# XSL: role -> family, one per line, for --stringparam.
#
#   fonts_fo_params <merged> <out>
#
# Read by the pandoc-xslt engine and passed to xsltproc, which is the missing
# link that lets a theme change fonts without replacing fo.xsl wholesale.
# fo.xsl already parameterises its families; nothing passed them until now.
#
# A role with no font declared gets its base-14 name, so the file always covers
# every known role and the engine never has to decide what a gap means.
fonts_fo_params() {  # fonts_fo_params <merged> <fonts-dir> <out>
	{
		for _fp_role in $FONT_ROLES_KNOWN; do
			_fp_family=$(fonts_merged_get "$1" "$_fp_role.name")
			# Declared but not staged means FOP has no such font registered,
			# and naming it would leave FOP to substitute silently -- so the
			# base-14 name goes in instead. Same reasoning as fonts_css.
			if [ -n "$_fp_family" ] &&
			   [ -z "$(fonts_role_has_file "$1" "$2" "$_fp_role")" ]; then
				_fp_family=""
			fi
			[ -n "$_fp_family" ] || _fp_family=$(fonts_base14 "$_fp_role")
			printf '%s\t%s\n' "$_fp_role" "$_fp_family"
		done
	} > "$3"
}


# XML text escaping, for family names going into an attribute. Ampersand
# first, or the escapes escape each other.
fonts_xml_escape() {  # fonts_xml_escape <string>
	printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}
