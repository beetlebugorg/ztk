#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Build the ztk docs site from the Markdown files.

Usage: python3 tools/build-docs.py [output folder]

The build needs markdown-it-py (tools/docs-requirements.txt). It stops with
an error for a link to a missing page or a missing anchor.
"""

import html
import posixpath
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/beetlebugorg/ztk"
SITE = "https://beetlebug.org/ztk/"

# Source file, page folder, sidebar group, sidebar title.
PAGES = [
    ("README.md", "", "Start", "Overview"),
    ("docs/plan.md", "plan/", "Plan", "The plan"),
    ("docs/tk-size.md", "tk-size/", "Plan", "The size of Tk"),
    ("docs/review.md", "review/", "Plan", "Review checklist"),
    ("docs/tasks/README.md", "tasks/", "Stage 1 tasks", "Task index"),
]
for task in sorted((ROOT / "docs/tasks").glob("[0-9]*.md")):
    title = task.read_text(encoding="utf-8").splitlines()[0].lstrip("# ").replace("Task ", "", 1)
    PAGES.append((f"docs/tasks/{task.name}", f"tasks/{task.stem}/", "Stage 1 tasks", title))
PAGES.append(("docs/references/README.md", "references/", "References", "All references"))
for ref in sorted((ROOT / "docs/references").glob("*.md")):
    if ref.name != "README.md":
        title = ref.read_text(encoding="utf-8").splitlines()[0].lstrip("# ")
        PAGES.append((f"docs/references/{ref.name}", f"references/{ref.stem}/", "References", title))
PAGES += [
    ("docs/release.md", "release/", "Project", "Releases"),
    ("CHANGELOG.md", "changelog/", "Project", "Changelog"),
    ("CONTRIBUTING.md", "contributing/", "Project", "Contributing"),
    ("SECURITY.md", "security/", "Project", "Security"),
]
# The sidebar shows these groups closed, except on a page of the group.
FOLDED = {"Stage 1 tasks", "References"}
PAGE_OF = {src: page for src, page, _, _ in PAGES}

CSS = """
:root{color-scheme:light dark;--bg:#fbfbf9;--panel:#f1f1ec;--text:#20211e;--dim:#62645c;--line:#d9dad2;--link:#17616b;--code:#ecece6;--warn:#8a5a00;--note:#17616b}
@media (prefers-color-scheme:dark){:root{--bg:#171815;--panel:#20211d;--text:#e7e7e0;--dim:#a1a398;--line:#373932;--link:#79c7d1;--code:#292b26;--warn:#e0ad4f;--note:#79c7d1}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.65 system-ui,-apple-system,"Segoe UI",sans-serif}
.layout{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:100vh}
nav{background:var(--panel);border-right:1px solid var(--line);padding:24px 20px;position:sticky;top:0;height:100vh;overflow:auto}
nav .brand{display:block;font:700 22px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--text);text-decoration:none}
nav .tag{display:block;color:var(--dim);font-size:13px;margin-bottom:18px}
nav h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:20px 0 6px}
nav a.item{display:block;padding:4px 8px;margin:0 -8px;border-radius:6px;color:var(--text);text-decoration:none;font-size:15px}
nav summary{font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:20px 0 6px;cursor:pointer}
nav a.item:hover{background:var(--code)}nav a.item[aria-current]{background:var(--code);font-weight:600}
main{padding:40px 48px 72px;max-width:900px;width:100%}
h1{font-size:34px;line-height:1.2;margin:0 0 20px}h2{font-size:24px;margin:38px 0 10px;line-height:1.3}h3{font-size:19px;margin:28px 0 8px}
a{color:var(--link)}code{font:.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.12em .32em;border-radius:4px}
pre{background:var(--code);padding:14px 16px;border-radius:8px;overflow:auto;line-height:1.45}pre code{background:none;padding:0}
.table{overflow-x:auto;margin:16px 0}table{border-collapse:collapse;min-width:100%;font-size:15px}th,td{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}th{background:var(--panel)}
blockquote{margin:16px 0;padding:8px 16px;border-left:4px solid var(--line);color:var(--dim)}
.alert{margin:16px 0;padding:10px 16px;border-left:4px solid var(--note);background:var(--panel);border-radius:0 8px 8px 0}.alert.warning{border-color:var(--warn)}.alert p{margin:.3em 0}.alert .title{font-weight:700}
footer{margin-top:48px;padding-top:14px;border-top:1px solid var(--line);color:var(--dim);font-size:14px}
@media (max-width:760px){.layout{display:block}nav{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line);padding:16px}main{padding:24px 16px 48px}h1{font-size:28px}}
"""


def slug(text):
    text = re.sub(r"[^\w\- ]", "", text.lower()).strip()
    return re.sub(r" +", "-", text)


def inline_text(token):
    return "".join(c.content for c in (token.children or []) if c.type in ("text", "code_inline"))


def rel(from_page, to_page):
    path = posixpath.relpath(to_page or ".", from_page or ".")
    return "./" if path == "." else path.rstrip("/") + "/"


class Build:
    def __init__(self):
        self.md = MarkdownIt("commonmark", {"html": False}).enable("table").enable("strikethrough")
        self.anchors = {}
        self.links = []

    def render(self, src, page):
        tokens = self.md.parse((ROOT / src).read_text(encoding="utf-8"))
        ids, seen, title = set(), {}, None
        for i, token in enumerate(tokens):
            if token.type == "heading_open":
                text = inline_text(tokens[i + 1])
                title = title or text
                base = slug(text)
                n = seen.get(base, 0)
                seen[base] = n + 1
                anchor = base if n == 0 else f"{base}-{n}"
                token.attrSet("id", anchor)
                ids.add(anchor)
            if token.type == "inline":
                for child in token.children or []:
                    if child.type == "link_open":
                        child.attrSet("href", self.link(src, page, child.attrGet("href")))
        self.anchors[page] = ids
        body = self.md.renderer.render(tokens, self.md.options, {})
        body = body.replace("<table>", '<div class="table"><table>').replace("</table>", "</table></div>")
        return title or src, self.alerts(body)

    def link(self, src, page, href):
        if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("//"):
            return href
        if href.startswith("#"):
            self.links.append((src, page, href[1:]))
            return href
        path, _, frag = href.partition("#")
        target = posixpath.normpath(posixpath.join(posixpath.dirname(src), path))
        if target in PAGE_OF:
            other = PAGE_OF[target]
            if frag:
                self.links.append((src, other, frag))
            return rel(page, other) + (f"#{frag}" if frag else "")
        if not (ROOT / target).exists():
            raise SystemExit(f"{src}: link to a missing file: {href}")
        kind = "tree" if (ROOT / target).is_dir() else "blob"
        return f"{REPO}/{kind}/main/{target}" + (f"#{frag}" if frag else "")

    @staticmethod
    def alerts(body):
        def replace(match):
            kind, rest = match.group(1).lower(), match.group(2)
            css = "alert warning" if kind in ("warning", "caution", "important") else "alert"
            return f'<div class="{css}"><p>{rest.strip()}</p></div>'
        return re.sub(r"<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*?)</p>\s*</blockquote>", replace, body, flags=re.S)

    def nav(self, page):
        out, group = [], None
        active = next(section for _, other, section, _ in PAGES if other == page)
        for _, other, section, label in PAGES:
            if section != group:
                if group in FOLDED:
                    out.append("</details>")
                if section in FOLDED:
                    state = " open" if section == active else ""
                    out.append(f"<details{state}><summary>{html.escape(section)}</summary>")
                else:
                    out.append(f"<h2>{html.escape(section)}</h2>")
                group = section
            current = ' aria-current="page"' if other == page else ""
            out.append(f'<a class="item" href="{rel(page, other)}"{current}>{html.escape(label)}</a>')
        if group in FOLDED:
            out.append("</details>")
        out.append("<h2>Source</h2>")
        out.append(f'<a class="item" href="{REPO}">GitHub</a>')
        out.append(f'<a class="item" href="{REPO}/releases">Releases</a>')
        return "\n".join(out)

    def document(self, page, title, body):
        name = "ztk" if page == "" else f"{html.escape(title)} · ztk"
        desc = "Experimental Tk replacement in Zig, on the ztcl interpreter."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}"><style>{CSS}</style></head>
<body><div class="layout"><nav aria-label="Documentation"><a class="brand" href="{rel(page, '')}">ztk</a>
<span class="tag">Experimental Tk in Zig</span>{self.nav(page)}</nav>
<main>{body}<footer>BSD-2-Clause · <a href="{REPO}">Source on GitHub</a></footer></main></div></body></html>
"""

    def run(self, out):
        rendered = [(page, *self.render(src, page)) for src, page, _, _ in PAGES]
        for src, page, anchor in self.links:
            if anchor not in self.anchors.get(page, set()):
                raise SystemExit(f"{src}: link to a missing anchor: {page}#{anchor}")
        if out.exists():
            shutil.rmtree(out)
        for page, title, body in rendered:
            folder = out / page
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "index.html").write_text(self.document(page, title, body), encoding="utf-8")
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered)} pages to {out}")


if __name__ == "__main__":
    Build().run(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out" / "docs-site")
