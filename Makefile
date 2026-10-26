# Build clarity-vision.pdf from the Markdown sources. CI publishes it to GitHub
# Pages on every push to main (.github/workflows/pages.yml).
#
#   make pdf     build the PDF (default)
#   make clean   remove build outputs and the Python venv

CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
BUILD  := .build
VENV   := $(BUILD)/venv
HTML   := $(BUILD)/clarity-vision.html
PDF    := clarity-vision.pdf
SRCS   := $(wildcard *.md spec/*.md spec/std/*.clar)

.PHONY: pdf clean
pdf: $(PDF)

$(VENV)/.installed:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q markdown pygments
	touch $@

$(HTML): $(SRCS) scripts/build-pdf.py $(VENV)/.installed
	$(VENV)/bin/python scripts/build-pdf.py . $@

$(PDF): $(HTML)
	"$(CHROME)" --headless --disable-gpu --no-pdf-header-footer \
		--print-to-pdf="$(CURDIR)/$@" "file://$(CURDIR)/$(HTML)" 2>/dev/null

clean:
	rm -rf $(BUILD) $(PDF)
