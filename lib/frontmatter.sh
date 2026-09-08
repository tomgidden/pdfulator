# lib/frontmatter.sh — separating a document's metadata from its body.
#
# The wrapper does this once, for every engine, and hands the engine a body
# file plus a sidecar. That is the point: metadata reached the engines three
# different ways before -- js-yaml in the vivlio engine, pandoc's own
# yaml_metadata_block, and a sed hack in the pandoc engines' render -- and
# three implementations of one job is how they drift. It is also the same
# reasoning that moved job planning, theme resolution and browser discovery
# into lib/: see lib/jobs.sh.
#
# What this file does NOT do is parse YAML. It finds where the metadata block
# starts and ends and copies the two halves out verbatim. The engines still
# read the YAML with a real parser -- js-yaml, or pandoc's --metadata-file --
# so nested maps, lists of authors, quoted colons and multi-line scalars are
# somebody else's problem, correctly. A YAML parser written in shell would be
# a bad idea and this is not one.
#
# THREE FORMS ARE RECOGNISED, and they were chosen for a reason each:
#
#   ---            The conventional one. Every static-site generator, and what
#   ...            pandoc's yaml_metadata_block reads. `...` closes as well as
#   ---            `---`, because YAML says so and pandoc honours it.
#
#   <!--yaml       So that a README carrying pdfulator metadata does not show
#   ...            a block of YAML at the top when GitHub renders it. Spelled
#   -->            after ```yaml rather than invented: it names the content,
#                  not the tool, so another tool could reasonably read it too.
#
# AT THE START ONLY. Frontmatter at the END was implemented, tested and then
# deliberately removed. Pandoc's native `markdown` reader does accept a
# metadata block anywhere in a document -- but commonmark_x, which is PFM's
# base, does not, and nothing else in the ecosystem does either: not Jekyll,
# Hugo, MultiMarkdown, Obsidian, 11ty, Astro or Docusaurus, all of which
# require it to be the first thing in the file. A document using a trailing
# block would render correctly here and lose its metadata everywhere else,
# silently. That is the divergence DIALECT.md exists to prevent, and the
# comment form below already solves the problem trailing metadata was wanted
# for.
#
# Nor in the middle: a `---` in the middle of a document is a horizontal rule,
# and nothing distinguishes the two without misreading somebody's rule.
#
# A sidecar that already exists is left alone -- see frontmatter_sidecar.


# Where is the metadata block, if there is one?
#
#   frontmatter_find <file>
#
# Prints "<first-line> <last-line>" of the block's CONTENT -- the fences
# themselves excluded -- or nothing. Line numbers are 1-based and inclusive.
frontmatter_find() {  # frontmatter_find <file>
	[ -f "$1" ] || return 1
	awk '
		{ line[NR] = $0 }
		END {
			# --- Leading block ------------------------------------------
			# The opener has to BE line 1. Anything else and a horizontal
			# rule three paragraphs down starts a metadata block.
			if (line[1] ~ /^---[ \t]*\r?$/)      close_re = "^(---|\\.\\.\\.)[ \t]*\r?$"
			else if (line[1] ~ /^<!--yaml[ \t]*\r?$/) close_re = "^-->[ \t]*\r?$"

			if (close_re != "") {
				for (i = 2; i <= NR; i++) {
					if (line[i] ~ close_re) { print 2, i - 1; exit }
				}
				# An unterminated block is not metadata. Falling through
				# rather than guessing keeps a document that merely opens
				# with a rule intact.
			}

		}
	' "$1"
}


# Split a document into body and metadata.
#
#   frontmatter_split <in> <body-out> <meta-out>
#
# Returns 0 when a block was found and the two files were written, 1 when
# there was none -- in which case <body-out> is a copy of the input and
# <meta-out> is empty. Callers can therefore use both files unconditionally.
frontmatter_split() {  # frontmatter_split <in> <body-out> <meta-out>
	_fs_in=$1
	_fs_body=$2
	_fs_meta=$3

	: > "$_fs_meta" || return 1

	_fs_span=$(frontmatter_find "$_fs_in") || _fs_span=""
	if [ -z "$_fs_span" ]; then
		cp -- "$_fs_in" "$_fs_body" || return 1
		return 1
	fi

	_fs_from=${_fs_span% *}
	_fs_to=${_fs_span#* }

	awk -v a="$_fs_from" -v b="$_fs_to" 'NR >= a && NR <= b' \
		"$_fs_in" > "$_fs_meta" || return 1

	# The body is everything outside the block AND its fences. Written in one
	# pass so a trailing block's preceding text and a leading block's
	# following text are handled by the same expression.
	awk -v a="$_fs_from" -v b="$_fs_to" '
		NR >= a - 1 && NR <= b + 1 { next }
		{ print }
	' "$_fs_in" > "$_fs_body" || return 1

	return 0
}
