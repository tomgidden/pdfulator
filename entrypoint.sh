#!/bin/zsh

DEFAULTS=/defaults
THEME=/theme
WORKDIR=/work
INDIR=/in
  
mkdir -p $WORKDIR $INDIR

# Fail on error
set -e
setopt extendedglob

# Parse options
zmodload zsh/zutil
zparseopts -D -E -F - {d,-debug}=OPT_D {w,-watch}=OPT_W {h,-help}=OPT_H {v,-verbose}=OPT_V

OPT_W=${OPT_W:+true}
OPT_H=${OPT_H:+true}
OPT_D=${OPT_D:+true}
OPT_V=${OPT_V:+true}



# The actual conversion process
function convert_to_pdf {
  SUBWORKDIR=$1
  LEAF=$2
  OUT=$3

  FORMAT=commonmark_x-raw_html+task_lists+definition_lists
    #+blank_before_header+space_in_atx_header
  
  LUAFILTER_DEFAULTS=""
  LUAFILTER_THEME=""
  [[ -f $DEFAULTS/metadata.lua ]] && LUAFILTER_DEFAULTS=--lua-filter=$DEFAULTS/metadata.lua
  [[ -f $THEME/metadata.lua ]] && LUAFILTER_THEME=--lua-filter=$THEME/metadata.lua

  TEMPLATE=$DEFAULTS/article.tmpl
  [[ -f $THEME/article.tmpl ]] && TEMPLATE=$THEME/article.tmpl


  # Convert to HTML5
  pandoc \
    $SUBWORKDIR/* \
    -f $FORMAT \
    $LUAFILTER_DEFAULTS \
    $LUAFILTER_THEME \
    --template=$TEMPLATE \
    --no-highlight \
    -t html5 \
    -o $SUBWORKDIR/$LEAF.html
    #    --shift-heading-level-by=-1 \

  # Convert HTML to PDF
  pagedjs-cli \
    -i "$SUBWORKDIR/$LEAF.html" \
    -o "$OUT" \
    --browserArgs "--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage"

  return 0
}

# The main function to process a file
function process_file {
  IN=$1
  LEAF=${IN:t:r}
  MAINEXT=${IN:e}
  OUT=$2

  # Block PDF file changes from triggering
  if [[ $MAINEXT == pdf ]]; then
    return 0
  fi

  if [[ -s "$OUT" && $IN -ot $OUT ]]; then
    [ $OPT_V ] && echo "Skipping $IN (unchanged)"
    return 0
  fi

  [ $OPT_V ] && echo "Processing $IN..."

  # Create a subdir in $WORKDIR with a random suffix using tempfile
  SUBWORKDIR=$(mktemp -d $WORKDIR/pdfulator.$LEAF.`date +%Y%m%d%H%M%S`.XXXX)
  
  # Copy input files that are either the IN file or any that match 
  for f in ${IN:r}{,.md,.yaml,.yml}(.N); do
    if [ -f $f ]; then
      [ $OPT_V ] && echo "Copying $f to $SUBWORKDIR"
      cp --preserve=timestamps "$f" "$SUBWORKDIR/"
    fi
  done

  # Do the conversion
  convert_to_pdf $SUBWORKDIR $LEAF $OUT

  # If not debugging, clear up the work folder.
  set +e
  [ $OPT_D ] || rm -rf $SUBWORKDIR
  set -e

  return 0
}


# Do an immediate run-through (not watched)
function process_files_and_dirs {
  [ $OPT_V ] && echo "Processing files and directories..."

  # Loop through specified files
  if [ ${#FILES[@]} -gt 0 ]; then
    for IN in ${FILES[@]}; do
      process_file $IN $INDIR/${IN:t:r}.pdf
    done

  # Loop through specified directories
  elif [ ${#DIRS[@]} -gt 0 ]; then
    for IN in ${DIRS[@]}/*.[Mm][Dd]; do
      process_file $IN $INDIR/${IN:t:r}.pdf
    done
  fi

  return 0
}

# Watch for file changes and do conversions when detected
function watch_files_and_dirs {
  [ $OPT_V ] && echo "Watching for file changes..."

  while true; do

    # Watch for changes to specified files
    if [ ${#FILES[@]} -gt 0 ]; then
      inotifywait -q -e create,modify,close_write --format '%w%f%0' ${FILES[@]} |\
        while IFS= read -r -d '' IN; do
          [ $OPT_V ] && echo "Processing specified file... $IN"
          process_file $IN $INDIR/${IN:t:r}.pdf
        done
            
    # Watch for changes to files in directories
    elif [ ${#DIRS[@]} -gt 0 ]; then
      inotifywait -q -e create,modify,close_write,moved_to --includei '\.(md|yml|yaml)$' --no-newline --format '%w%f%0' ${DIRS[@]} |\
        while IFS= read -r -d '' IN; do
          [ $OPT_V ] && echo "Processing file... $IN"
          process_file $IN $INDIR/${IN:t:r}.pdf
        done
    fi
  done

  return 0
}



# Check for - in args, in which case forget everything else and just do STDIN > STDOUT conversion
for IN in "$@"; do

  if [[ "-" == $IN ]]; then
    # Immediate mode!
    SUBWORKDIR=$(mktemp -d $WORKDIR/pdfulator.`date +%Y%m%d%H%M%S`.XXXX)

    # Save the incoming file
    cat - > $SUBWORKDIR/file.md

    if [[ ! -s $SUBWORKDIR/file.md ]]; then
      echo "Empty input. (Use -i in docker run?)" >&2
      exit 1
    fi

    # Process it
    convert_to_pdf $SUBWORKDIR file $SUBWORKDIR/file.pdf

    # Output the incoming file
    cat $SUBWORKDIR/file.pdf

    # Clean up
    set +e
    [ $OPT_D ] || rm -rf $SUBWORKDIR
    exit 0
  fi
done


INVALID=(pdf yml yaml htm html)

# Process arguments
for IN in "$@"; do

  # If that arg is a valid filename in /in, add it
  if [[ -f "$INDIR/$IN" ]]; then

    # Skip PDFs, HTML, and YAML files. YAMLs are sidecars to MDs so get done by MD steps.
    if [[ 0 == $INVALID[(Ie)${IN:e}] ]] ; then
      FILES+=("$INDIR/$IN")
    else
      echo "Bad argument: $IN" >&2
      exit 1
    fi

  # If that arg is a valid directory in /in, add it and all its files
  elif [[ -d "$INDIR/$IN" ]]; then
      DIRS+=("$INDIR/$IN")

  # Otherwise, complain
  else
    echo "Not found: $IN" >&2
    exit 1
  fi
done

# If we have both files and directories, complain
if [ ${#FILES[@]} -gt 0 ] && [ ${#DIRS[@]} -gt 0 ]; then
  echo "Cannot specify both files and directories" >&2
  exit 1
fi

# If we have neither, default to /in
if [ ${#FILES[@]} -eq 0 ] && [ ${#DIRS[@]} -eq 0 ]; then
  DIRS=("$INDIR")
fi

if [ $OPT_W ]; then
  process_files_and_dirs
  watch_files_and_dirs
else
  process_files_and_dirs
fi