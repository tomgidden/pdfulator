#!/bin/sh
# lib/payload/payload.sh — what a payload says it contains.
#
#   payload.sh markup <payload>            the structural file
#   payload.sh engine <payload>            "<id> <styler>"
#
# Paths are printed relative to the payload, one per line, so a caller that
# sees the payload through a container mount at a different path can use them
# unchanged. Absent means empty output and exit 0: a payload naming no template
# is an engine falling back to its built-in, not an error.
#
# A PROCESS, NOT A SOURCED LIBRARY. Deliberate (PAYLOAD-PLAN §14): the
# interface is a command line and some lines of output, so it can be
# reimplemented in another language without touching an engine, and an engine
# written in anything at all can ask.
#
# --- THERE IS NO `stylesheets` COMMAND, AND THAT IS ON PURPOSE ---------------
#
# It existed briefly and was removed unused. Both pandoc engines link
# `print.css` -- the concatenation the WRAPPER already produced from its own
# resolution -- so nothing here ever called it, and the XSLT engine is not
# additive at all and never will (§10). What it left behind was a third
# implementation of §5's cascade order, exercised by nothing but its own test.
#
# Three implementations of a subtle rule, one of them with no consumer, is
# worse than two: dead code that a green test protects is exactly the code that
# rots unnoticed until the day something calls it. It had in fact already
# drifted -- it omitted the engine band that payload.js emitted -- and the
# comparison test could not see it, because no fixture engine declared a
# stylesheet.
#
# **If an engine ever needs to reconcile the cascade itself, bring it back
# WITH that consumer**, and write it against the two implementations named
# below rather than from the prose. Do not add it speculatively.
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

# --- THE DUPLICATED PART, AND HOW TO KEEP IT HONEST --------------------------
#
# Everything below is a line-for-line translation of the correspondingly named
# function in engines/vivlio/_nopayload/payload.js. Two implementations exist
# because the two live on opposite sides of a language boundary: this one runs
# inside a container where no JS runtime is present, that one runs in the
# engine that IS a JS runtime. Neither can call the other.
#
#     payload.sh          payload.js         what it answers
#     ----------------    ---------------    ----------------------------------
#     p_template          templateDir()      which template dir
#     p_engine            engineOf()         which engine, and its styler
#     p_rel               (inline in href)   a path relative to the payload
#     cmd_markup          markup()           the structural file
#
# EACH OPERATION IS COMMENTED with a `JS:` line naming the statement it
# corresponds to. That is not decoration: it is what lets a reader confirm the
# two are equivalent without holding both files in their head, and what tells
# an editor which other file they have just obliged themselves to change. **A
# change here that has no matching change there is a bug even when both files
# are individually correct** -- and the failure mode is not an error but a
# document that renders differently depending on which engine drew it.
#
# tests/payloadmatrix.sh checks both sides against the SAME fixture payload and
# asserts each gets the expected answer -- so a divergence in what `markup` or
# `engine` returns is caught. Be aware of what that does NOT cover: the two are
# compared against a literal, not against each other, so a change made
# identically-wrongly in both would pass. These comments are the defence
# against the likelier case, a change made in one and forgotten in the other.


# The one template the payload was built for, or empty.
#
# JS: templateDir(payload)
p_template() {  # p_template <payload>
	# JS: const dir = path.join(payload, INPUT, 'templates')
	_pt_dir="$1/input/templates"

	# JS: the try/catch around readdirSync -- an absent directory is empty,
	# not an error. A payload for an engine with no template concept has none.
	[ -d "$_pt_dir" ] || return 0

	# JS: names.filter(n => isDir(...)) then names.length ? names[0] : ''
	#
	# The FIRST directory, not a search: staging copies the chosen template and
	# no other, so there is exactly one. Both sides rely on that same fact
	# rather than on agreeing about how to pick among several.
	for _pt in "$_pt_dir"/*; do
		[ -d "$_pt" ] || continue
		printf '%s\n' "$_pt"
		return 0
	done
}


# The engine the payload was built for, and its styler.
#
# JS: engineOf(payload) -- which returns { id, styler }; here the two are one
# space-separated line, because that is what a shell caller can split.
p_engine() {  # p_engine <payload>
	# JS: const dir = path.join(payload, INPUT, 'engines')
	_pe_dir="$1/input/engines"

	# JS: the catch returning { id: '', styler: '' }
	[ -d "$_pe_dir" ] || return 0

	for _pe in "$_pe_dir"/*; do
		[ -d "$_pe" ] || continue

		# JS: const id = names[0]
		# Same single-entry reliance as p_template: staging copies the CHOSEN
		# engine and no other.
		_pe_id=$(basename -- "$_pe")

		# JS: confGet(path.join(dir, id, 'engine.conf'), 'styler')
		# Read rather than assumed, because vivlio and vivlio-docker share a
		# styler while having different ids -- neither can be a constant.
		printf '%s %s\n' "$_pe_id" \
			"$(conf_get "$_pe/engine.conf" styler 2>/dev/null || printf '')"
		return 0
	done
}


# Print a path relative to the payload, so a caller seeing the payload at a
# different mount point can still use it.
#
# JS: NOT a separate function there. payload.js returns ABSOLUTE paths, because
# its caller is in the same process and can use them directly; main.js makes
# them relative at the point of use, in linkTags's `href`
# (path.relative(payload, p)). This side must return relative paths, because
# its caller is inside a container where the payload's absolute host path names
# nothing. **That is a deliberate difference in the interface, not a drift in
# the logic** -- the question answered is the same, the frame of reference is
# not. A test asserts this side never emits a leading `/`.
#
# `./` is stripped on the way through. Conf files idiomatically write
# `./theme.css`, and joining that to a directory leaves it embedded --
# `themes/default/./theme.css` works everywhere but appears in error messages
# and in whatever the caller builds from it, where it reads like a bug in the
# tool rather than a path from a config file. (JS: the same normalisation is
# unnecessary there because path.relative() already collapses it.)
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


# The structural file: the template's markup, named by its own template.conf
# rather than found under an agreed filename.
#
# JS: markup(payload)
cmd_markup() {  # cmd_markup <payload>
	# JS: const tdir = templateDir(payload); if (!tdir) return ''
	_cm_t=$(p_template "$1")
	[ -n "$_cm_t" ] || return 0

	# JS: confGet(path.join(tdir, 'template.conf'), 'template.structure')
	#     if (!ref) return ''
	_cm_ref=$(conf_get "$_cm_t/template.conf" template.structure 2>/dev/null || printf '')
	[ -n "$_cm_ref" ] || return 0

	# JS: resolveRef(ref, tdir) -- absolute stays, relative joins to the
	# declaring file's own directory. resolveRef also strips a leading `+`;
	# here it cannot appear, because `template.structure` is a single value
	# rather than a list and `+` has no meaning on one. If that ever changes,
	# both sides change together.
	case $_cm_ref in
		/*) _cm_f=$_cm_ref ;;
		*)  _cm_f="$_cm_t/$_cm_ref" ;;
	esac

	# JS: return fs.existsSync(file) ? file : ''
	#
	# A declared-but-missing structural file is empty, not an error: the caller
	# falls back to its own built-in, which is what a bare `docker run` with
	# nothing mounted gets. Erroring here would turn a supported way of using
	# the images into a failure.
	[ -f "$_cm_f" ] || return 0

	# JS: no counterpart -- see p_rel.
	p_rel "$1" "$_cm_f"
}


main() {
	[ $# -ge 2 ] || die "usage: payload.sh <markup|engine> <payload>"
	_m_cmd=$1
	_m_p=${2%/}
	[ -d "$_m_p" ] || die "payload.sh: no such payload: $_m_p"

	case $_m_cmd in
		markup) cmd_markup "$_m_p" ;;
		engine) p_engine "$_m_p" ;;
		# `stylesheets` is named rather than falling through to the generic
		# error, because it existed and was removed: a caller written against
		# an older payload should be told what happened, not told the command
		# is unknown. See the header.
		stylesheets)
			die "payload.sh: no stylesheets command; the wrapper resolves the cascade (see print.css)"
			;;
		*) die "payload.sh: unknown command: $_m_cmd" ;;
	esac
}

main "$@"
