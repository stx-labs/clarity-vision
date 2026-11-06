import os, re, sys, markdown
from markdown.extensions import codehilite
from pygments.lexer import RegexLexer
from pygments.lexers import EbnfLexer
from pygments.token import (Keyword, Name, Number, Operator, Punctuation,
                            String, Text)
from markdown.extensions.toc import slugify

# Pygments' EBNF lexer does not know ISO 14977's repetition factor (`n * [x]`).
# Teach it before any block is highlighted (the appendix and the ```ebnf blocks
# both use it), so `127 *` renders as a number and an operator. The rules go in
# front of the punctuation rule, found by its pattern; fail loudly if it moves.
_rules = EbnfLexer.tokens["production"]
_punct = next((i for i, r in enumerate(_rules) if isinstance(r, tuple) and r[0] == r"[\[\]{}(),|]"), None)
if _punct is None:
    sys.exit("build-pdf: pygments EbnfLexer changed; update the repetition-factor patch")
_rules[_punct:_punct] = [(r"\d+", Number), (r"\*", Operator)]

# The ```grammar blocks of chapters 2 and 3 use the reading notation of
# spec/05-grammar.md 5.1 (`a ::= b c?`). Highlight them with the same token
# kinds as the EBNF appendix: rule names as keywords, terminals as strings,
# special sequences as entities.
class GrammarLexer(RegexLexer):
    name = "Grammar reading notation"
    aliases = ["grammar"]
    tokens = {"root": [
        (r"\s+", Text),
        (r"::=", Operator),
        (r'"[^"]*"', String.Double),
        (r"'[^']*'", String.Single),
        (r"<[^<>\n]*>", Name.Entity),
        (r"\{\d+(,\d+)?\}", Number),
        (r"[a-z_][a-z0-9_]*", Keyword),
        (r"[?*+-]", Operator),
        (r"[()|]", Punctuation),
    ]}

_get_lexer = codehilite.get_lexer_by_name
codehilite.get_lexer_by_name = lambda name, **options: (
    GrammarLexer(**options) if name == "grammar" else _get_lexer(name, **options))

ROOT = sys.argv[1]
OUT = sys.argv[2]
DOCS = ["README.md", "01-why-clarity.md", "02-goals.md", "03-architecture.md",
        "04-spec-plan.md", "05-roadmap.md", "06-issue-tracker.md", "07-chain-abi.md",
        "08-value-interpretation.md",
        "spec/README.md", "spec/01-principles.md",
        "spec/02-core-language.md", "spec/03-primitives.md",
        "spec/04-standard-library.md", "spec/05-grammar.md"]
# Source files appended verbatim after the Markdown documents.
SOURCES = ["spec/std/prelude.clar", "spec/grammar/clarity.ebnf"]

def key(path):
    return re.sub(r"[^a-z0-9]+", "-", path.lower().removesuffix(".md")).strip("-")

def highlight_source(path):
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import SchemeLexer
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    lexer = EbnfLexer() if path.endswith(".ebnf") else SchemeLexer()
    code = highlight(src, lexer, HtmlFormatter(cssclass="codehilite"))
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

def nav_item(k, toc):
    # toc is the document's toc_tokens: a single h1 whose children are the h2s.
    h1 = toc[0] if toc else {"name": k, "children": []}
    subs = "".join(f'<li><a href="#{h2["id"]}">{h2["name"]}</a></li>' for h2 in h1["children"])
    subs = f"<ul>{subs}</ul>" if subs else ""
    return f'<li class="nav-doc" data-doc="{k}"><a href="#{k}">{h1["name"]}</a>{subs}</li>'

parts = []
nav = {"Vision": [], "Specification": [], "Appendix": []}
for d in DOCS:
    src = open(os.path.join(ROOT, d), encoding="utf-8").read()
    k = key(d)
    md = markdown.Markdown(extensions=[
        "tables", "fenced_code", "codehilite", "sane_lists",
        markdown.extensions.toc.TocExtension(
            slugify=lambda v, s, k=k: f"{k}-" + slugify(v, s), permalink="#"),
    ], extension_configs={"codehilite": {"guess_lang": False}})
    html = rewrite_links(md.convert(src), os.path.dirname(d))
    # Keep "->" in signatures from breaking across lines between "-" and ">".
    html = re.sub(r"<code>.*?</code>", lambda m: m.group(0).replace("-&gt;", '<span class="arrow">-&gt;</span>'), html)
    html = html.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    parts.append(f'<section class="doc" id="{k}">{html}</section>')
    nav["Specification" if d.startswith("spec/") else "Vision"].append(nav_item(k, md.toc_tokens))

for path in SOURCES:
    k = key(path)
    parts.append(f'<section class="doc source" id="{k}">{highlight_source(path)}</section>')
    nav["Appendix"].append(f'<li class="nav-doc" data-doc="{k}"><a href="#{k}"><code>{os.path.basename(path)}</code></a></li>')

from pygments.formatters import HtmlFormatter
light_code = HtmlFormatter(style="default").get_style_defs(".codehilite")
dark_code = HtmlFormatter(style="github-dark").get_style_defs(".codehilite")

css = """
:root {
  --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --bg-subtle: #f6f8fa;
  --border: #d1d9e0; --border-strong: #1f2328; --link: #0550ae; --accent: #5546ff;
  --code-bg: #eff1f3; --nav-active-bg: #eef0ff;
}
body { margin: 0; color: var(--fg); background: var(--bg);
       font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif; }
code, pre { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
code { background: var(--code-bg); padding: 0.1em 0.3em; border-radius: 4px; font-size: 0.875em; }
pre code { background: none; padding: 0; font-size: inherit; }
.codehilite { background: var(--bg-subtle) !important; border: 1px solid var(--border); border-radius: 6px; }
.codehilite pre { margin: 0; background: none; }
pre { line-height: 1.45; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid var(--border); padding: 6px 10px; vertical-align: top; text-align: left; }
th { background: var(--bg-subtle); font-weight: 600; }
blockquote { border-left: 4px solid var(--border); margin-left: 0; padding: 0 1em; color: var(--muted); }
h1, h2, h3, h4 { line-height: 1.25; }
.headerlink { display: none; }
.arrow { white-space: nowrap; }

@media print {
  @page { size: Letter; margin: 0.8in 0.75in; }
  body { font-size: 10.5pt; line-height: 1.45; color: #1a1a1a; }
  .topbar, nav.sidebar { display: none; }
  section.doc { break-before: page; }
  section.doc:first-child { break-before: auto; }
  h1 { font-size: 20pt; border-bottom: 2px solid #333; padding-bottom: 4px; }
  h2 { font-size: 15pt; margin-top: 1.4em; border-bottom: 1px solid #ccc; padding-bottom: 2px; }
  h3 { font-size: 12pt; margin-top: 1.2em; }
  h1, h2, h3, h4 { break-after: avoid; }
  code { font-size: 9pt; background: #f3f3f3; padding: 0 3px; border-radius: 3px; }
  pre code { background: none; padding: 0; }
  .codehilite { border: 1px solid #e1e4e8; border-radius: 4px; background: #f6f8fa !important; }
  .codehilite pre { font-size: 8.5pt; padding: 8px 10px; white-space: pre-wrap; word-wrap: break-word; }
  table { margin: 0.8em 0; font-size: 9.5pt; }
  th, td { border-color: #ccc; padding: 4px 6px; }
  th { background: #f0f0f0; }
  tr, pre { break-inside: avoid; }
  section.source pre { break-inside: auto; font-size: 8pt; line-height: 1.35; }
  blockquote { border-left-width: 3px; border-color: #ccc; padding: 0 0 0 12px; color: #555; }
}

@media screen {
  html { scroll-padding-top: 4.5rem; }
  body { font-size: 16px; line-height: 1.65; }
  .topbar { position: sticky; top: 0; z-index: 10; height: 3.25rem; display: flex; align-items: center;
            gap: 1rem; padding: 0 1.25rem; background: var(--bg); border-bottom: 1px solid var(--border); }
  .topbar .title { font-weight: 650; font-size: 1.05rem; color: var(--fg); letter-spacing: -0.01em; }
  .topbar .title:hover { text-decoration: none; }
  .topbar .pdf { margin-left: auto; font-size: 0.875rem; font-weight: 500; padding: 0.3rem 0.75rem;
                 border: 1px solid var(--border); border-radius: 6px; color: var(--fg); }
  .topbar .pdf:hover { background: var(--bg-subtle); text-decoration: none; }
  .menu { display: none; background: none; border: 1px solid var(--border); border-radius: 6px;
          color: var(--fg); font-size: 1.1rem; line-height: 1; padding: 0.3rem 0.55rem; cursor: pointer; }

  nav.sidebar { position: fixed; top: 3.25rem; bottom: 0; left: 0; width: 18rem; overflow-y: auto;
                padding: 1.25rem 0.75rem 3rem; box-sizing: border-box; border-right: 1px solid var(--border);
                background: var(--bg); font-size: 0.875rem; line-height: 1.4; }
  nav.sidebar h2 { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted);
                   margin: 1.25rem 0.5rem 0.4rem; border: 0; padding: 0; }
  nav.sidebar h2:first-child { margin-top: 0; }
  nav.sidebar ul { list-style: none; margin: 0; padding: 0; }
  nav.sidebar a { display: block; padding: 0.3rem 0.5rem; border-radius: 6px; color: var(--fg); }
  nav.sidebar a:hover { background: var(--bg-subtle); text-decoration: none; }
  nav.sidebar code { background: none; padding: 0; }
  .nav-doc > ul { display: none; margin: 0.15rem 0 0.4rem 0.75rem; padding-left: 0.5rem;
                  border-left: 1px solid var(--border); }
  .nav-doc.active > ul { display: block; }
  .nav-doc.active > a { font-weight: 600; background: var(--nav-active-bg); }
  .nav-doc > ul a { color: var(--muted); padding: 0.2rem 0.5rem; font-size: 0.8125rem; }
  .nav-doc > ul a.active { color: var(--accent); font-weight: 500; }

  main { margin-left: 18rem; padding: 2rem 2.5rem 6rem; }
  section.doc { max-width: 50rem; margin: 0 auto; }
  section.doc + section.doc { margin-top: 4rem; padding-top: 3rem; border-top: 1px solid var(--border); }
  section.source { max-width: 60rem; }
  h1 { font-size: 2rem; font-weight: 700; letter-spacing: -0.02em; margin: 0 0 1.25rem; }
  h2 { font-size: 1.45rem; font-weight: 650; margin: 2.5rem 0 1rem; padding-bottom: 0.35rem;
       border-bottom: 1px solid var(--border); letter-spacing: -0.01em; }
  h3 { font-size: 1.15rem; font-weight: 600; margin: 2rem 0 0.75rem; }
  h4 { font-size: 1rem; font-weight: 600; margin: 1.5rem 0 0.5rem; }
  p, ul, ol { margin: 0 0 1rem; }
  li + li { margin-top: 0.25rem; }
  .headerlink { display: inline; margin-left: 0.4rem; color: var(--muted); opacity: 0; font-weight: 400; }
  h1:hover .headerlink, h2:hover .headerlink, h3:hover .headerlink, h4:hover .headerlink { opacity: 1; }
  .headerlink:hover { text-decoration: none; color: var(--accent); }
  .codehilite { margin: 0 0 1rem; overflow-x: auto; }
  .codehilite pre { padding: 0.85rem 1rem; font-size: 0.8125rem; }
  .table-wrap { overflow-x: auto; margin: 0 0 1.25rem; }
  table { font-size: 0.875rem; line-height: 1.5; }
  tbody tr:nth-child(even) { background: var(--bg-subtle); }
  hr { border: 0; border-top: 1px solid var(--border); margin: 2rem 0; }

  @media (max-width: 900px) {
    .menu { display: inline-block; }
    nav.sidebar { display: none; width: 100%; border-right: 0; }
    body.nav-open nav.sidebar { display: block; }
    body.nav-open { overflow: hidden; }
    main { margin-left: 0; padding: 1.5rem 16px 4rem; }
    h1 { font-size: 1.65rem; }
  }
}

@media screen and (prefers-color-scheme: dark) {
  :root {
    --fg: #e6edf3; --muted: #9198a1; --bg: #0d1117; --bg-subtle: #151b23;
    --border: #3d444d; --link: #4493f8; --accent: #a5a0ff;
    --code-bg: #262c36; --nav-active-bg: #1f2340;
  }
}
"""

def scoped(rules, media):
    return f"@media {media} {{ {rules} }}"

css += "\n" + light_code + "\n" + scoped(dark_code, "screen and (prefers-color-scheme: dark)")

js = """
const links = new Map([...document.querySelectorAll('nav.sidebar a')].map(a => [a.hash.slice(1), a]));
const docs = document.querySelectorAll('section.doc');
const heads = document.querySelectorAll('section.doc h2[id]');
let current;
function update() {
  const y = window.scrollY + 120;
  let doc = docs[0], head;
  for (const d of docs) if (d.offsetTop <= y) doc = d;
  for (const h of heads) if (h.offsetTop <= y && doc.contains(h)) head = h;
  const key = doc.id + '|' + (head ? head.id : '');
  if (key === current) return;
  current = key;
  document.querySelectorAll('.nav-doc').forEach(li => li.classList.toggle('active', li.dataset.doc === doc.id));
  document.querySelectorAll('.nav-doc ul a.active').forEach(a => a.classList.remove('active'));
  const a = head && links.get(head.id);
  if (a) a.classList.add('active');
  const active = a || links.get(doc.id);
  if (active) active.scrollIntoView({ block: 'nearest' });
}
window.addEventListener('scroll', update, { passive: true });
update();
document.querySelector('.menu').addEventListener('click', () => document.body.classList.toggle('nav-open'));
document.querySelector('nav.sidebar').addEventListener('click', e => {
  if (e.target.closest('a')) document.body.classList.remove('nav-open');
});
"""

sidebar = "".join(f"<h2>{group}</h2><ul>{''.join(items)}</ul>" for group, items in nav.items() if items)
topbar = ('<header class="topbar"><button class="menu" aria-label="Toggle navigation">&#9776;</button>'
          '<a class="title" href="#readme">Clarity Vision</a>'
          '<a class="pdf" href="clarity-vision.pdf">Download PDF</a></header>')
with open(OUT, "w", encoding="utf-8") as f:
    f.write(f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<meta name="color-scheme" content="light dark">'
            f'<title>Clarity Vision</title><style>{css}</style></head><body>'
            f'{topbar}<nav class="sidebar">{sidebar}</nav><main>{"".join(parts)}</main>'
            f'<script>{js}</script></body></html>')
