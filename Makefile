.PHONY: manual

# Build the operator manual PDF from docs/manual/*.md.
# See scripts/build-manual.sh for the tool requirements (pandoc + typst).
manual:
	bash scripts/build-manual.sh
