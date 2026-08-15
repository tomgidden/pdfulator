# lib/paths.sh — path classification and resolution.
#
# The lowest layer: everything else (jobs, theme, engines) builds on these.
# Sourced, never executed.
#
# The rule this file exists to enforce: an extension is a hint, not proof. What
# decides "may I write here?" is what the file actually *is*. A file called
# .pdf holding markdown is somebody's data, and a markdown file called .pdf is
# not something to convert. Both are in the test fixture for exactly this
# reason (tests/argmatrix.sh: real.pdf vs liar.pdf).


# Resolve a path to an absolute one, without requiring it to exist.
#
# Neither `realpath` nor `readlink -f` is on stock macOS, so this is the
# `cd && pwd` idiom instead. The directory must exist; the leaf need not, which
# is what lets us resolve an output file that hasn't been created yet.
abspath() {  # abspath <path>
	_ap_dir=$(dirname -- "$1")
	_ap_base=$(basename -- "$1")

	# A trailing slash makes dirname/basename report the same directory twice;
	# resolving the whole thing is right in that case.
	case $1 in
		*/) _ap_dir=$1; _ap_base="" ;;
	esac

	if [ -d "$_ap_dir" ]; then
		_ap_dir=$(cd -- "$_ap_dir" 2>/dev/null && pwd) || _ap_dir=$1
	fi

	if [ -z "$_ap_base" ] || [ "$_ap_base" = "/" ]; then
		printf '%s\n' "$_ap_dir"
	else
		# Avoid the doubled slash when resolving something at the root.
		case $_ap_dir in
			*/) printf '%s%s\n' "$_ap_dir" "$_ap_base" ;;
			*)  printf '%s/%s\n' "$_ap_dir" "$_ap_base" ;;
		esac
	fi
}


# Is this file a real PDF? Judged by the first five bytes, not the name.
is_pdf_file() {  # is_pdf_file <path>
	[ -f "$1" ] || return 1
	# dd rather than head -c: head -c is not POSIX, though it is widespread.
	_pf_magic=$(dd if="$1" bs=1 count=5 2>/dev/null | tr -d '\0')
	[ "$_pf_magic" = "%PDF-" ]
}


# Classify a path: missing | pdf | dir | other
#
# Mirrors classifyPath() in the v2 pdfulator.js. Note the deliberate quirk it
# carries over: a zero-length file counts as 'missing', because a touched
# placeholder is fair game to write over, and treating it as existing-but-not-
# a-PDF would make `pdfulator a.md empty.pdf` refuse for no good reason.
classify_path() {  # classify_path <path>
	if [ -d "$1" ]; then
		printf 'dir\n'
		return 0
	fi

	if [ ! -e "$1" ]; then
		printf 'missing\n'
		return 0
	fi

	if [ ! -f "$1" ]; then
		printf 'other\n'
		return 0
	fi

	if [ ! -s "$1" ]; then
		printf 'missing\n'
		return 0
	fi

	if is_pdf_file "$1"; then
		printf 'pdf\n'
	else
		printf 'other\n'
	fi
}


# Does this name look like markdown? Used only when the file is absent, so that
# a missing `foo.md` reports "no such file" rather than "unrecognised".
looks_like_markdown() {  # looks_like_markdown <path>
	case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
		*.md|*.markdown) return 0 ;;
		*)               return 1 ;;
	esac
}


# Does this name look like a PDF? Name only -- callers pair it with
# classify_path when the file exists.
looks_like_pdf() {  # looks_like_pdf <path>
	case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
		*.pdf) return 0 ;;
		*)     return 1 ;;
	esac
}


# Swap a markdown extension for .pdf, or append .pdf when there isn't one.
pdf_name_for() {  # pdf_name_for <path>
	case $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') in
		*.md)       printf '%s.pdf\n' "${1%.*}" ;;
		*.markdown) printf '%s.pdf\n' "${1%.*}" ;;
		*)          printf '%s.pdf\n' "$1" ;;
	esac
}
