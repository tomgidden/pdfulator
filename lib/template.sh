# lib/template.sh — the template object.
#
# A template is the third object type, alongside engines and themes, and it
# exists because "the template" is not one thing. What fills it, what syntax it
# is written in and what DOM it targets vary together:
#
#   vivlio, vivlio-docker    HTML + Mustache + vivliostyle DOM
#   pagedjs, pagedjs-docker  HTML + Mustache + pagedjs DOM
#   pandoc-pagedjs           HTML + pandoc $var$
#   pandoc-xslt              DocBook 5 + pandoc $var$
#   typst, typst-docker      their own
#
# Those groupings follow neither `parser` nor `styler`. In vivlio the parser
# (markdown-it) never sees the template at all -- main.js parses the Markdown,
# then calls Mustache separately -- while in pandoc-pagedjs pandoc does both
# jobs in one pass. And pandoc-xslt uses the same parser as pandoc-pagedjs
# against an entirely different format. So neither existing key names the thing
# a template belongs to, which is why this is its own object rather than
# another key on an existing one.
#
# The bug this exists to fix: `article.tmpl` was staged by *name*, flat, most
# specific winning. themes/default's copy is Mustache, and engines/pandoc-*
# preferred the theme's copy over their own -- so every shipped theme handed a
# Mustache template to pandoc, which does not know that syntax and passed it
# through as literal text into the PDF.
#
# A template is a directory, because the structural file and the CSS that knows
# its DOM belong together:
#
#   templates/<id>/template.conf
#   templates/<id>/<markup>          e.g. article.tmpl
#   templates/<id>/<styling>         e.g. template.css
#
# with template.conf naming them:
#
#   markup = ./article.tmpl
#   stylesheet   = ./template.css
#
# Sourced, never executed. Requires lib/conf.sh and lib/paths.sh.


# Where templates live, mirroring ENGINES_DIR. Set by the caller; falls back to
# this file's parent so a checkout works when the tests source lib/ directly.
: "${PDFULATOR_DIR:=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)}"
: "${TEMPLATES_DIR:=$PDFULATOR_DIR/templates}"


template_error() {  # template_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# Resolve a template reference to an absolute directory.
#
#   template_resolve <ref> <base-dir>
#
# <base-dir> is the directory of the file the reference was written in, because
# a relative path in a config file means relative to that file -- an engine
# saying `template = ../../templates/html-pandoc-pagedjs` is describing where
# the template is from where *it* stands, and the same string written in a
# theme three directories away would mean somewhere else entirely.
#
# A reference with no `/` in it is a bare *name* and is looked up in
# TEMPLATES_DIR, so `template = html-mustache-vivlio` works from anywhere. This
# is the same name-versus-path split theme_resolve makes, and for the same
# reason: a name is the useful reading, and a path is what you write when you
# mean somewhere specific.
template_resolve() {  # template_resolve <ref> <base-dir>
	[ -n "${1:-}" ] || return 1

	case $1 in
		*/*) _tr_cand="$2/$1" ;;
		*)   _tr_cand="$TEMPLATES_DIR/$1" ;;
	esac
	# An absolute reference is already where it says it is.
	case $1 in
		/*) _tr_cand=$1 ;;
	esac

	if [ ! -d "$_tr_cand" ]; then
		template_error "no template at: $1"
		return 1
	fi

	printf '%s\n' "$(abspath "$_tr_cand")"
	return 0
}


# Which template an engine and theme chain select, as an absolute directory.
#
#   template_select <chain> <engine> <styler> <engine-dir>
#
# Resolution order, most specific first. A theme may override the template, but
# it is expected to be rare -- the template belongs to the engine's ecosystem,
# and a theme that changes it is claiming to know that ecosystem better than
# the engine does. It is allowed because a genuinely unusual theme may need it.
#
#   <theme>/engines/<engine>/theme-engine.conf   template =
#   <theme>/stylers/<styler>/theme-styler.conf   template =
#   <theme>/theme.conf                           template =
#   <engine-dir>/engine.conf                     template =
#   (nothing -- the engine falls back to its own built-in)
#
# `<theme>/templates/<id>/theme-template.conf` is DELIBERATELY NOT IN THIS
# LIST, and cannot be: that axis is keyed on the template this function
# selects, so letting it select one would be circular -- the answer would
# decide which directory was consulted to produce it. A theme-template.conf
# says "when this markup is in play, style it thus"; choosing the markup is a
# different question, asked at one of the hooks above.
#
# The theme chain is walked child-first, so the most derived theme that names a
# template wins, which is how every other theme key already behaves.
#
# Prints nothing and returns 0 when no template is named anywhere: that is the
# ordinary case for an engine with a built-in fallback, not an error.
template_select() {  # template_select <chain> <engine> <styler> <engine-dir>
	_ts_chain=$1
	_ts_engine=$2
	_ts_styler=$3
	_ts_enginedir=$4

	# Child-first: `sed '1!G;h;$!d'` is the portable tac, as theme_file uses.
	_ts_ref=""
	_ts_base=""
	for _ts_dir in $(printf '%s\n' "$_ts_chain" | sed '1!G;h;$!d'); do
		[ -n "$_ts_dir" ] || continue
		for _ts_where in \
			"$_ts_dir/engines/$_ts_engine/theme-engine.conf" \
			"$_ts_dir/stylers/$_ts_styler/theme-styler.conf" \
			"$_ts_dir/theme.conf"; do
			[ -f "$_ts_where" ] || continue
			_ts_v=$(conf_get "$_ts_where" template)
			if [ -n "$_ts_v" ]; then
				_ts_ref=$_ts_v
				_ts_base=$(dirname -- "$_ts_where")
				break
			fi
		done
		[ -z "$_ts_ref" ] || break
	done

	# The engine's own declaration is the floor.
	if [ -z "$_ts_ref" ] && [ -f "$_ts_enginedir/engine.conf" ]; then
		_ts_ref=$(conf_get "$_ts_enginedir/engine.conf" template)
		_ts_base=$_ts_enginedir
	fi

	[ -n "$_ts_ref" ] || return 0

	template_resolve "$_ts_ref" "$_ts_base"
}


# The structural file a template declares, as an absolute path.
#
#   template_markup <template-dir>
#
# Empty when the template declares none, which is legitimate: a template may
# exist to carry styling alone.
template_markup() {  # template_markup <template-dir>
	[ -n "${1:-}" ] || return 0
	[ -f "$1/template.conf" ] || return 0

	_tmk=$(conf_get "$1/template.conf" markup)
	[ -n "$_tmk" ] || return 0

	# Relative to the template.conf that named it, as everywhere else here.
	case $_tmk in
		/*) _tmk_p=$_tmk ;;
		*)  _tmk_p="$1/$_tmk" ;;
	esac

	if [ ! -f "$_tmk_p" ]; then
		template_error "template names a markup file it does not have: $_tmk"
		return 1
	fi

	printf '%s\n' "$(abspath "$_tmk_p")"
	return 0
}


# Files the markup needs beside it, one absolute path per line.
#
#   template_support <template-dir>
#
# A structural file is not always self-contained. The DocBook template opens
# with
#
#   <!ENTITY % entities SYSTEM "global.ent"> %entities;
#
# and a SYSTEM identifier resolves relative to the file that names it -- so
# staging template.xml.pandoc on its own gives pandoc a template whose DTD subset
# points at a file that is not there, and the parse fails before any of this
# engine's actual work begins.
#
# Declared rather than inferred. Scanning a template for its dependencies means
# understanding its syntax, and the whole point of this object is that there
# are several syntaxes; a list in template.conf is a line of config against a
# parser per ecosystem.
#
#   template.support = ./global.ent
#   template.support = ./partials/head.tmpl
#
# Every occurrence counts, hence conf_get_all: a template may need more than
# one, and there is no sensible reading in which a second declaration replaces
# the first.
template_support() {  # template_support <template-dir>
	[ -n "${1:-}" ] || return 0
	[ -f "$1/template.conf" ] || return 0

	conf_get_all "$1/template.conf" template.support | \
	while IFS= read -r _tsu || [ -n "$_tsu" ]; do
		[ -n "$_tsu" ] || continue
		case $_tsu in
			/*) _tsu_p=$_tsu ;;
			*)  _tsu_p="$1/$_tsu" ;;
		esac
		if [ ! -f "$_tsu_p" ]; then
			template_error "template names a support file it does not have: $_tsu"
			exit 1
		fi
		printf '%s\n' "$(abspath "$_tsu_p")"
	done
}


# What a structural file should be called in the staged directory.
#
#   template_markup_name <template-dir>
#
# Engines look for a fixed filename -- pandoc's render wants `article.tmpl`,
# the XSLT one wants `global.tmpl` -- so the staged name is the template's own
# basename rather than something invented here. That keeps the engine's side
# unchanged: it still reads one known name out of one directory, and the
# template object decides which file ends up under it.
template_markup_name() {  # template_markup_name <template-dir>
	_tmn=$(template_markup "$1") || return 1
	[ -n "$_tmn" ] || return 0
	basename -- "$_tmn"
}
