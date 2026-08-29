#!/bin/sh
# lib/payload/payload.sh — what a payload says it contains.
#
#   payload.sh markup      <payload>            the structural file
#   payload.sh stylesheets <payload>            every stylesheet, cascade order
#   payload.sh engine      <payload>            "<id> <styler>"
#
# Paths are printed relative to the payload, one per line, so a caller that
# sees the payload through a container mount at a different path can use them
# unchanged. Absent means empty output and exit 0: a payload naming no template
# is an engine falling back to its built-in, not an error.
#
# A PROCESS, NOT A SOURCED LIBRARY. That is deliberate (PAYLOAD-PLAN §14): the
# hard part -- §5's cascade order -- sits behind an interface that is a command
# line and some lines of output, so it can be reimplemented in another language
# without touching a single engine. It also means an engine written in anything
# at all can ask the question.
#
# WHY IT TRAVELS IN THE PAYLOAD. A containerised engine cannot see the
# wrapper's lib/, and the alternatives are worse: COPYing lib/ at image build
# freezes it at that revision, so a moving `:<engine>` tag run against a
# different wrapper gets two implementations of the cascade differing by
# however many commits separate them -- silent skew, which is the exact drift
# this file exists to prevent. Mounting the host's lib/ couples every published
# image to one host layout. Shipping it in the payload gives the engine the
# rules the payload was ACTUALLY ASSEMBLED UNDER, which is the right coupling:
# it arrives with the thing it describes, at the same revision.
#
# It lives at _lib/ inside the payload -- the leading underscore marking what
# the wrapper generated rather than what an author wrote, as _payload.css does
# -- and is excluded from the staging hash, or every wrapper update would
# invalidate every cached payload for no behavioural reason.
set -eu

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

# The same readers the wrapper used, travelling beside this script.
. "$SELF_DIR/conf.sh"


die() { printf '%s\n' "$*" >&2; exit 1; }

# Every object kind's conf file, in the order they are tried. One object has
# exactly one of these; which one says what kind of object it is.
PAYLOAD_CONFS="template.conf theme.conf theme-engine.conf theme-styler.conf \
               theme-template.conf engine.conf"


# The conf file an object directory holds, or empty.
#
# IFS is set explicitly rather than inherited. The callers walk newline-
# separated lists and set IFS to do it, and an unguarded `for _pc in
# $PAYLOAD_CONFS` then does not word-split at all -- the whole list becomes one
# filename, every object looks conf-less, and every stylesheet silently
# disappears. Any function here that relies on word splitting has to say so.
p_conf() {  # p_conf <dir>
	_pc_ifs=$IFS
	IFS=' 	
'
	for _pc in $PAYLOAD_CONFS; do
		if [ -f "$1/$_pc" ]; then
			IFS=$_pc_ifs
			printf '%s\n' "$1/$_pc"
			return 0
		fi
	done
	IFS=$_pc_ifs
	printf '\n'
}


# One object's stylesheets, in declaration order, as absolute paths.
#
# `+foo.css` adds; a bare `foo.css` replaces everything this object had, which
# is what makes `template.styling = mine.css` mean "mine, and nothing
# inherited". Paths resolve against the file that declared them.
p_sheets() {  # p_sheets <dir>
	_ps_conf=$(p_conf "$1")
	[ -n "$_ps_conf" ] || return 0

	_ps_out=""
	# A pipeline's `while` runs in a subshell, so the accumulator would be lost;
	# a here-doc built by command substitution keeps the loop in this shell.
	_ps_vals=$(conf_get_all "$_ps_conf" template.styling 2>/dev/null || :)
	[ -n "$_ps_vals" ] || return 0

	_ps_ifs=$IFS
	IFS='
'
	for _ps_v in $_ps_vals; do
		[ -n "$_ps_v" ] || continue
		case $_ps_v in
			'+'*)
				_ps_r=${_ps_v#+}
				_ps_r=${_ps_r#"${_ps_r%%[! 	]*}"}
				_ps_add=1
				;;
			*)  _ps_r=$_ps_v; _ps_add=0 ;;
		esac
		[ -n "$_ps_r" ] || continue

		case $_ps_r in
			/*) _ps_f=$_ps_r ;;
			*)  _ps_f="$1/$_ps_r" ;;
		esac
		[ -f "$_ps_f" ] || continue

		if [ "$_ps_add" = 1 ]; then
			_ps_out="$_ps_out$_ps_f
"
		else
			_ps_out="$_ps_f
"
		fi
	done
	IFS=$_ps_ifs

	printf '%s' "$_ps_out"
}


# The theme chain, root first.
#
# Recovered by following `extends`, which is the same walk the wrapper did over
# the same conf files -- present in the payload because every selected object
# was mirrored whole, INCLUDING a theme that contributes no stylesheet. Such a
# theme is invisible in a list of stylesheets and indispensable here: it
# carries the `extends` that reaches its parent.
#
# The leaf is the theme no other theme in the payload extends. Well defined,
# because the payload holds exactly the chain that was selected.
p_chain() {  # p_chain <payload>
	_pch_dir="$1/input/themes"
	[ -d "$_pch_dir" ] || return 0

	# name<TAB>parent, one per line.
	_pch_map=""
	for _pch_t in "$_pch_dir"/*; do
		[ -d "$_pch_t" ] || continue
		_pch_n=$(basename -- "$_pch_t")
		_pch_p=$(conf_get "$_pch_t/theme.conf" extends 2>/dev/null || printf '')
		# `extends` may be a bare name or a path; only the basename identifies
		# the directory the mirror created.
		[ -n "$_pch_p" ] && _pch_p=$(basename -- "$_pch_p")
		_pch_map="$_pch_map$_pch_n	$_pch_p
"
	done
	[ -n "$_pch_map" ] || return 0

	# The leaf: named by nobody as a parent.
	_pch_leaf=""
	_pch_ifs=$IFS
	IFS='
'
	for _pch_line in $_pch_map; do
		_pch_n=${_pch_line%%	*}
		_pch_is_parent=0
		for _pch_other in $_pch_map; do
			[ "${_pch_other#*	}" = "$_pch_n" ] && _pch_is_parent=1 && break
		done
		[ "$_pch_is_parent" = 0 ] && _pch_leaf=$_pch_n && break
	done
	IFS=$_pch_ifs
	[ -n "$_pch_leaf" ] || return 0      # a cycle: nothing beats hanging

	# Walk up, emitting root-first.
	_pch_out=""
	_pch_cur=$_pch_leaf
	_pch_guard=0
	while [ -n "$_pch_cur" ] && [ "$_pch_guard" -lt 64 ]; do
		_pch_out="$_pch_dir/$_pch_cur
$_pch_out"
		_pch_next=""
		_pch_ifs=$IFS
		IFS='
'
		for _pch_line in $_pch_map; do
			if [ "${_pch_line%%	*}" = "$_pch_cur" ]; then
				_pch_next=${_pch_line#*	}
				break
			fi
		done
		IFS=$_pch_ifs
		_pch_cur=$_pch_next
		_pch_guard=$((_pch_guard + 1))
	done

	printf '%s' "$_pch_out"
}


# The one template the payload was built for, or empty.
p_template() {  # p_template <payload>
	_pt_dir="$1/input/templates"
	[ -d "$_pt_dir" ] || return 0
	for _pt in "$_pt_dir"/*; do
		[ -d "$_pt" ] || continue
		printf '%s\n' "$_pt"
		return 0
	done
}


# The engine the payload was built for, and its styler.
p_engine() {  # p_engine <payload>
	_pe_dir="$1/input/engines"
	[ -d "$_pe_dir" ] || return 0
	for _pe in "$_pe_dir"/*; do
		[ -d "$_pe" ] || continue
		_pe_id=$(basename -- "$_pe")
		printf '%s %s\n' "$_pe_id" \
			"$(conf_get "$_pe/engine.conf" styler 2>/dev/null || printf '')"
		return 0
	done
}


# Print a path relative to the payload, so a caller seeing the payload at a
# different mount point can still use it.
#
# `./` is stripped on the way through. Conf files idiomatically write
# `./theme.css`, and joining that to a directory leaves it embedded --
# `themes/default/./theme.css` works everywhere but appears in error messages
# and in whatever the caller builds from it, where it reads like a bug in the
# tool rather than a path from a config file.
p_rel() {  # p_rel <payload> <path>
	case $2 in
		"$1"/*) _pr=${2#"$1"/} ;;
		*)      _pr=$2 ;;
	esac
	# Only the /./ form: a leading ./ would be meaningful in a relative result.
	while :; do
		case $_pr in
			*/./*) _pr="${_pr%%/./*}/${_pr#*/./}" ;;
			*)     break ;;
		esac
	done
	printf '%s\n' "$_pr"
}


cmd_markup() {  # cmd_markup <payload>
	_cm_t=$(p_template "$1")
	[ -n "$_cm_t" ] || return 0
	_cm_ref=$(conf_get "$_cm_t/template.conf" template.structure 2>/dev/null || printf '')
	[ -n "$_cm_ref" ] || return 0
	case $_cm_ref in
		/*) _cm_f=$_cm_ref ;;
		*)  _cm_f="$_cm_t/$_cm_ref" ;;
	esac
	[ -f "$_cm_f" ] || return 0
	p_rel "$1" "$_cm_f"
}


# Every stylesheet that applies, lowest priority first.
#
# THE ORDER IS AXIS-OUTER, CHAIN-INNER (PAYLOAD-PLAN §5):
#
#     template
#     grandparent theme,        parent theme,        theme
#     grandparent theme-engine, parent theme-engine, theme-engine
#     grandparent theme-styler, parent theme-styler, theme-styler
#     --css
#
# NOT chain-outer. An object's stylesheet is really its parent's with changes,
# so the inheritance is logically private to that object: each axis is its own
# chain, resolved end to end before it meets the next. The rejected order
# interleaves them and lets a GRANDPARENT's styler-specific rule beat the rule
# the theme in front of you wrote. The difference is invisible with a two-level
# chain, which is how the old implementation survived a year.
cmd_stylesheets() {  # cmd_stylesheets <payload>
	_cs_p=$1
	_cs_chain=$(p_chain "$_cs_p")
	_cs_eng=$(p_engine "$_cs_p")
	_cs_id=${_cs_eng%% *}
	_cs_sty=${_cs_eng#* }
	[ "$_cs_sty" = "$_cs_eng" ] && _cs_sty=""

	# 10: the template's own styling -- the floor a theme is written against.
	_cs_t=$(p_template "$_cs_p")
	[ -n "$_cs_t" ] && p_sheets "$_cs_t"

	# 20/30/40: one pass per axis, each walking the whole chain root-first.
	for _cs_sub in "" "engines/$_cs_id" "stylers/$_cs_sty"; do
		_cs_ifs=$IFS
		IFS='
'
		for _cs_theme in $_cs_chain; do
			[ -n "$_cs_theme" ] || continue
			if [ -n "$_cs_sub" ]; then _cs_d="$_cs_theme/$_cs_sub"; else _cs_d=$_cs_theme; fi
			[ -d "$_cs_d" ] && p_sheets "$_cs_d"
		done
		IFS=$_cs_ifs
	done

	# 60: --css, staged under external/ because the user may point it anywhere
	# and a path from their home has no place in a mounted directory. It has no
	# conf file to declare it -- it is not an object -- so it is found by
	# position, which is the same "the tree says it" rule as everything above.
	if [ -d "$_cs_p/input/external" ]; then
		for _cs_d in "$_cs_p"/input/external/*; do
			[ -d "$_cs_d" ] || continue
			for _cs_f in "$_cs_d"/*.css; do
				[ -f "$_cs_f" ] && printf '%s\n' "$_cs_f"
			done
		done
	fi
}


main() {
	[ $# -ge 2 ] || die "usage: payload.sh <markup|stylesheets|engine> <payload>"
	_m_cmd=$1
	_m_p=${2%/}
	[ -d "$_m_p" ] || die "payload.sh: no such payload: $_m_p"

	case $_m_cmd in
		markup)      cmd_markup "$_m_p" ;;
		engine)      p_engine "$_m_p" ;;
		stylesheets)
			cmd_stylesheets "$_m_p" | while IFS= read -r _m_f || [ -n "$_m_f" ]; do
				[ -n "$_m_f" ] || continue
				p_rel "$_m_p" "$_m_f"
			done
			;;
		*) die "payload.sh: unknown command: $_m_cmd" ;;
	esac
}

main "$@"
