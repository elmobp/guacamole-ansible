#!/usr/bin/env bash
# Build docs/manual/*.md into a single PDF operator manual.
#
#   scripts/build-manual.sh
#
# Requires:
#   - pandoc            (document conversion)         https://pandoc.org
#   - typst              (the chosen PDF engine)        https://typst.app
#
# Install (pick your platform):
#   macOS (Homebrew):     brew install pandoc typst
#   Debian / Ubuntu:      sudo apt-get install -y pandoc && \
#                           (sudo snap install typst || \
#                            cargo install --locked typst-cli)
#   RHEL / Fedora family: sudo dnf install -y pandoc && cargo install --locked typst-cli
#   Any platform (Rust):  cargo install --locked typst-cli
#
# Why typst and not (xe/pdf/lua)latex or weasyprint/wkhtmltopdf: it is a single
# statically-linked binary with no TeX distribution (~GB) or system font-stack
# (Pango/Cairo/GTK) to install, it has a first-class `--pdf-engine=typst`
# integration in pandoc >= 3.x, and it produces a correctly paginated PDF with
# a title page, table of contents, and page numbers with zero extra template
# work. Any other single engine would also satisfy this script's contract
# (concatenate docs/manual/*.md -> one PDF) if your environment prefers it —
# swap PDF_ENGINE below and adjust the "is it installed" check accordingly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANUAL_DIR="${REPO_ROOT}/docs/manual"
OUT_PDF="${MANUAL_DIR}/guacamole-operations-manual.pdf"
PDF_ENGINE="typst"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Preflight: pandoc ------------------------------------------------------
if ! command -v pandoc >/dev/null 2>&1; then
  fail "pandoc is not installed. Install it, then re-run this script.
    macOS:            brew install pandoc
    Debian / Ubuntu:  sudo apt-get install -y pandoc
    RHEL / Fedora:    sudo dnf install -y pandoc
    Docs:             https://pandoc.org/installing.html"
fi

# --- Preflight: the chosen PDF engine ---------------------------------------
if ! command -v "${PDF_ENGINE}" >/dev/null 2>&1; then
  fail "${PDF_ENGINE} (the PDF engine this script uses) is not installed.
    macOS:            brew install typst
    Any platform:     cargo install --locked typst-cli
    Debian / Ubuntu:  sudo snap install typst   (or the cargo command above)
    Docs:             https://github.com/typst/typst#installation"
fi

# --- Preflight: chapters exist ----------------------------------------------
[[ -d "${MANUAL_DIR}" ]] || fail "manual source directory not found: ${MANUAL_DIR}"

# Portable array-fill (avoids `mapfile`, which macOS's stock bash 3.2 lacks).
CHAPTERS=()
while IFS= read -r -d '' f; do
  CHAPTERS+=("$(basename "${f}")")
done < <(find "${MANUAL_DIR}" -maxdepth 1 -name '*.md' -print0 | sort -z)

[[ ${#CHAPTERS[@]} -gt 0 ]] || fail "no chapter files (*.md) found in ${MANUAL_DIR}"

echo "[build-manual] chapters (in build order):"
printf '  - %s\n' "${CHAPTERS[@]}"

CHAPTER_PATHS=()
for c in "${CHAPTERS[@]}"; do
  CHAPTER_PATHS+=("${MANUAL_DIR}/${c}")
done

# --- Build -------------------------------------------------------------------
# Chapter files are concatenated in numeric-prefix order (pandoc treats
# multiple input files as one document); 00-frontmatter.md's YAML metadata
# block at the top supplies the title/subtitle/author/date used for the title
# page. --toc adds a table of contents; --number-sections numbers headings;
# typst's default pandoc template adds page numbers automatically.
echo "[build-manual] running pandoc (engine: ${PDF_ENGINE}) -> ${OUT_PDF}"
pandoc "${CHAPTER_PATHS[@]}" \
  --from=markdown \
  --pdf-engine="${PDF_ENGINE}" \
  --toc \
  --toc-depth=2 \
  --number-sections \
  --metadata=lang:en \
  -o "${OUT_PDF}"

echo "[build-manual] OK -> ${OUT_PDF} ($(du -h "${OUT_PDF}" | cut -f1))"
