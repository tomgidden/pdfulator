# lib/jobs.sh — job planning.
#
# Turns positional arguments into a list of "input<TAB>output" pairs, or fails
# with a message explaining why it won't. This is the layer that used to be
# implemented three times over -- in pdfulator.js main(), in v1's zsh
# entrypoint, and in v0's GNUmakefile -- each with different answers. Engines
# no longer see any of it: they are handed one input and one output.
#
# Requires lib/paths.sh.
#
# Two symmetric shapes, each taking an optional destination. Which one applies
# is decided by the *source*, so no argument's meaning depends on guesswork:
#
#   pdfulator in.md              -- write in.pdf beside it
#   pdfulator in.md out.pdf      -- write out.pdf
#   pdfulator dir/               -- write each PDF beside its source
#   pdfulator dir/ outdir/       -- write them into outdir/
#
# An earlier version accepted any number of inputs and guessed per-argument
# whether each was a source or a destination, which made `pdfulator *.md`
# change meaning with the number of files the glob matched. A directory is how
# you convert many files at once.

# Jobs are accumulated here, one "input<TAB>output" per line.
JOBS=""

jobs_reset() { JOBS=""; }

jobs_add() {  # jobs_add <input> <output>
	JOBS="${JOBS}${1}	${2}
"
}

jobs_count() {
	[ -n "$JOBS" ] || { printf '0\n'; return 0; }
	printf '%s' "$JOBS" | grep -c ''
}

# Iterate: `jobs_each` prints the list for a `while IFS=<tab> read` loop.
jobs_each() { printf '%s' "$JOBS"; }


# Every markdown file directly inside a directory. Not recursive -- matching
# the v2 behaviour, where a directory is a flat batch rather than a tree.
jobs_list_markdown() {  # jobs_list_markdown <dir>
	for _jm in "$1"/*; do
		[ -f "$_jm" ] || continue
		if looks_like_markdown "$_jm"; then
			printf '%s\n' "$_jm"
		fi
	done
}


# Plan a directory source. $1 = source dir, $2 = destination dir or empty.
jobs_plan_dir() {  # jobs_plan_dir <srcdir> [outdir]
	_jd_src=$(abspath "$1")
	_jd_out=""
	if [ -n "${2:-}" ]; then _jd_out=$(abspath "$2"); fi

	_jd_any=0
	for _jd_f in $(jobs_list_markdown "$_jd_src"); do
		_jd_any=1
		_jd_f=$(abspath "$_jd_f")
		_jd_leaf=$(basename -- "$_jd_f")
		_jd_pdf=$(pdf_name_for "$_jd_leaf")
		if [ -n "$_jd_out" ]; then
			jobs_add "$_jd_f" "$_jd_out/$_jd_pdf"
		else
			jobs_add "$_jd_f" "$_jd_src/$_jd_pdf"
		fi
	done

	# An empty directory is not an error: converting nothing is a valid outcome
	# for `pdfulator .` in a directory you haven't written anything in yet.
	[ "$_jd_any" = 1 ] || return 0
	return 0
}


# Plan a single file source with an explicit destination.
#
# The destination must be a PDF we may replace, or a name not yet taken --
# judged by content, not extension.
jobs_plan_file_to() {  # jobs_plan_file_to <src> <dest>
	_jf_src=$1
	_jf_dest=$2
	_jf_destkind=$(classify_path "$_jf_dest")

	if [ "$_jf_destkind" != missing ] && [ "$_jf_destkind" != pdf ]; then
		if [ "$_jf_destkind" = dir ]; then
			jobs_error "refusing to overwrite $_jf_dest.

The second argument is the output file, so it must be a PDF or a new name.
$_jf_dest is a directory -- to convert into one, the source must be a directory too."
		else
			jobs_error "refusing to overwrite $_jf_dest.

The second argument is the output file, so it must be a PDF or a new name.
$_jf_dest exists and is not a PDF."
		fi
		return 1
	fi

	# The source must not itself be a PDF -- almost always a swapped pair.
	if [ "$(classify_path "$_jf_src")" = pdf ] || looks_like_pdf "$_jf_src"; then
		jobs_error "$_jf_src is a PDF, not something to convert."
		return 1
	fi

	# ...and it must exist. Checked after the PDF rule so that
	# `pdfulator out.pdf in.md` reports the swapped pair, which is the more
	# useful diagnosis, rather than "no such file".
	if [ ! -e "$_jf_src" ]; then
		jobs_error "no such file: $_jf_src"
		return 1
	fi

	jobs_add "$(abspath "$_jf_src")" "$(abspath "$_jf_dest")"
	return 0
}


# How planning reports refusal. Overridable by the caller for testing.
jobs_error() {  # jobs_error <message>
	printf 'Error: %s\n' "$1" >&2
}


# The entry point. Takes the positional arguments, fills $JOBS.
#
# Returns 0 with $JOBS populated (possibly empty, for an empty directory), or
# non-zero having already explained the refusal.
jobs_plan() {  # jobs_plan [args...]
	jobs_reset

	if [ $# -gt 2 ]; then
		jobs_error "too many arguments.

  pdfulator in.md [out.pdf]    convert one file
  pdfulator dir/ [outdir/]     convert every .md in a directory

To convert several named files, put them in a directory and convert that,
or run pdfulator once per file."
		return 1
	fi

	# No inputs: the current directory.
	if [ $# -eq 0 ]; then
		jobs_plan_dir "$PWD"
		return $?
	fi

	_jp_src=$1
	_jp_dest=${2:-}
	_jp_srckind=$(classify_path "$_jp_src")

	# --- directory source ---
	if [ "$_jp_srckind" = dir ]; then
		if [ -n "$_jp_dest" ]; then
			_jp_destkind=$(classify_path "$_jp_dest")
			# The destination may not exist yet; we create it later. But it
			# must not be an existing non-directory.
			if [ "$_jp_destkind" != dir ] && [ "$_jp_destkind" != missing ]; then
				jobs_error "$_jp_src is a directory, so $_jp_dest must be one too.

  pdfulator $_jp_src outdir/"
				return 1
			fi
		fi
		jobs_plan_dir "$_jp_src" "$_jp_dest"
		return $?
	fi

	# --- file source, explicit destination ---
	if [ -n "$_jp_dest" ]; then
		jobs_plan_file_to "$_jp_src" "$_jp_dest"
		return $?
	fi

	# --- file source, implicit destination ---

	# A PDF as an input is always a mistake -- most likely a glob that caught
	# the output of a previous run. The name alone is enough to refuse: a
	# zero-length or truncated .pdf is still not source material, and
	# converting it would overwrite it with itself.
	if [ "$_jp_srckind" = pdf ] || looks_like_pdf "$_jp_src"; then
		jobs_error "$_jp_src is a PDF, not something to convert."
		return 1
	fi

	if [ "$_jp_srckind" = missing ] && [ ! -e "$_jp_src" ]; then
		jobs_error "no such file: $_jp_src"
		return 1
	fi

	jobs_add "$(abspath "$_jp_src")" "$(abspath "$(pdf_name_for "$_jp_src")")"
	return 0
}
