import os, re, sys, markdown
from markdown.extensions.toc import slugify

ROOT = sys.argv[1]
OUT = sys.argv[2]
DOCS = ["README.md", "01-why-clarity.md", "02-goals.md", "03-architecture.md",
        "04-spec-plan.md", "05-roadmap.md", "spec/README.md", "spec/01-principles.md",
        "spec/02-core-language.md", "spec/03-primitives.md",
        "spec/04-standard-library.md", "spec/05-issue-tracker.md"]
# Source files appended verbatim after the Markdown documents.
SOURCES = ["spec/std/prelude.clar"]

def key(path):
    return re.sub(r"[^a-z0-9]+", "-", path.lower().removesuffix(".md")).strip("-")

def highlight_source(path):
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import SchemeLexer
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    code = highlight(src, SchemeLexer(), HtmlFormatter(noclasses=True, style="default"))
    return f'<h1>Appendix: <code>{path}</code></h1>{code}'

def rewrite_links(html, docdir):
    def sub(m):
        href = m.group(1)
        if re.match(r"^[a-z]+:", href) or href.startswith("#"):
            return m.group(0)
        path, _, frag = href.partition("#")
        full = os.path.normpath(os.path.join(docdir, path)) if path else None
        if full and full.endswith("/"):
            full = full.rstrip("/")
        if full and os.path.isdir(os.path.join(ROOT, full)):
            full = os.path.join(full, "README.md")
        if full in DOCS or full in SOURCES:
            k = key(full)
            return f'href="#{k}-{frag}"' if frag else f'href="#{k}"'
        return m.group(0)
    return re.sub(r'href="([^"]+)"', sub, html)

parts = []
for d in DOCS:
    src = open(os.path.join(ROOT, d), encoding="utf-8").read()
    k = key(d)
    md = markdown.Markdown(extensions=[
        "tables", "fenced_code", "codehilite", "sane_lists",
        markdown.extensions.toc.TocExtension(slugify=lambda v, s, k=k: f"{k}-" + slugify(v, s)),
    ], extension_configs={"codehilite": {"guess_lang": False, "noclasses": True, "pygments_style": "default"}})
    html = rewrite_links(md.convert(src), os.path.dirname(d))
    parts.append(f'<section class="doc" id="{k}">{html}</section>')

for path in SOURCES:
    parts.append(f'<section class="doc source" id="{key(path)}">{highlight_source(path)}</section>')

css = """
@page { size: Letter; margin: 0.8in 0.75in; }
body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
       font-size: 10.5pt; line-height: 1.45; color: #1a1a1a; }
section.doc { break-before: page; }
section.doc:first-child { break-before: auto; }
h1 { font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 4px; }
h2 { font-size: 15pt; margin-top: 1.4em; border-bottom: 1px solid #ccc; padding-bottom: 2px; }
h3 { font-size: 12pt; margin-top: 1.2em; }
h1, h2, h3, h4 { break-after: avoid; }
a { color: #0550ae; text-decoration: none; }
code { font-family: Menlo, Consolas, monospace; font-size: 9pt; background: #f3f3f3;
       padding: 0 3px; border-radius: 3px; }
pre, .codehilite pre { font-size: 8.5pt; background: #f6f8fa !important; padding: 8px 10px;
       border: 1px solid #e1e4e8; border-radius: 4px; white-space: pre-wrap; word-wrap: break-word; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 0.8em 0; font-size: 9.5pt; width: 100%; }
th, td { border: 1px solid #ccc; padding: 4px 6px; vertical-align: top; text-align: left; }
th { background: #f0f0f0; }
tr, pre { break-inside: avoid; }
section.source pre { break-inside: auto; font-size: 8pt; line-height: 1.35; }
blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 12px; color: #555; }
"""
with open(OUT, "w", encoding="utf-8") as f:
    f.write(f'<!doctype html><html><head><meta charset="utf-8"><title>Clarity Vision</title>'
            f'<style>{css}</style></head><body>{"".join(parts)}</body></html>')
