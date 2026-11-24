#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Build the ztk docs site from the Markdown files.

Usage: python3 tools/build-docs.py [output folder]

The landing page is docs/site/index.html. The docs pages come from the
Markdown files, and all pages use docs/site/site.css. The build copies the
screenshots in docs/site/shots to assets/shots. An image on a page must be
one of these files. The build needs markdown-it-py
(tools/docs-requirements.txt). It stops with an error for a link to a
missing page or a missing anchor, and for a missing image, also on the
landing page.
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
    ("README.md", "overview/", "Start", "Overview"),
    ("docs/plan.md", "plan/", "Plan", "The plan"),
    ("docs/tk-size.md", "tk-size/", "Plan", "The size of Tk"),
    ("docs/review.md", "review/", "Plan", "Review checklist"),
    ("docs/tasks/README.md", "tasks/", "Stage 1 tasks", "Task index"),
]
for task in sorted((ROOT / "docs/tasks").glob("[0-9]*.md")):
    title = task.read_text(encoding="utf-8").splitlines()[0].lstrip("# ").replace("Task ", "", 1)
    PAGES.append((f"docs/tasks/{task.name}", f"tasks/{task.stem}/", "Stage 1 tasks", title))
PAGES.append(("docs/stage2-tasks/README.md", "stage2-tasks/", "Widget stage tasks", "Task index"))
for task in sorted((ROOT / "docs/stage2-tasks").glob("[0-9]*.md")):
    title = task.read_text(encoding="utf-8").splitlines()[0].lstrip("# ").replace("Task ", "", 1)
    PAGES.append((f"docs/stage2-tasks/{task.name}", f"stage2-tasks/{task.stem}/", "Widget stage tasks", title))
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
FOLDED = {"Stage 1 tasks", "Widget stage tasks", "References"}
PAGE_OF = {src: page for src, page, _, _ in PAGES}

SITE_DIR = ROOT / "docs" / "site"


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
                    if child.type == "image":
                        child.attrSet("src", self.image(src, page, child.attrGet("src")))
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
    def image(src, page, href):
        """Gives the URL of an image of a Markdown page. The build copies
        docs/site/shots to assets/shots, so the URL goes into assets/."""
        if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("//"):
            return href
        target = posixpath.normpath(posixpath.join(posixpath.dirname(src), href))
        if not target.startswith("docs/site/shots/") or not (ROOT / target).is_file():
            raise SystemExit(f"{src}: the image is not a file in docs/site/shots: {href}")
        return rel(page, "") + "assets/" + target[len("docs/site/"):]

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

    @staticmethod
    def pager(page):
        pages = [(other, label) for _, other, _, label in PAGES]
        i = next(n for n, (other, _) in enumerate(pages) if other == page)
        out = []
        if i > 0:
            other, label = pages[i - 1]
            out.append(f'<a class="prev" href="{rel(page, other)}"><span>Previous</span>{html.escape(label)}</a>')
        if i + 1 < len(pages):
            other, label = pages[i + 1]
            out.append(f'<a class="next" href="{rel(page, other)}"><span>Next</span>{html.escape(label)}</a>')
        return f'<nav class="pager" aria-label="Pages">{"".join(out)}</nav>'

    def document(self, page, title, body):
        root = rel(page, "")
        name = f"{html.escape(title)} · ztk"
        desc = "A Tk replacement in Zig, on the ztcl interpreter, with a GPU renderer and CSS styles."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/site.css"></head>
<body><a class="skip" href="#content">Skip to the content</a>
<header class="top"><div class="wrap"><a class="logo" href="{root}"><span class="glyph" aria-hidden="true">tk</span>ztk</a>
<nav class="toplinks" aria-label="Site"><a href="{root}overview/" aria-current="page">Docs</a><a class="sib" href="https://beetlebug.org/ztcl/">ztcl</a><a href="{REPO}">GitHub</a></nav></div></header>
<div class="docs"><input class="toc-toggle" type="checkbox" id="toc"><label class="toc-button" for="toc">Contents</label>
<aside class="sidebar"><nav aria-label="Documentation">{self.nav(page)}</nav></aside>
<main class="prose" id="content">{body}{self.pager(page)}</main></div>
<footer class="foot docs-foot"><div class="wrap"><span>ztk · BSD-2-Clause</span><span class="right"><a href="{root}">Home</a><a href="https://beetlebug.org/ztcl/">ztcl</a><a href="{REPO}">Source on GitHub</a></span></div></footer>
</body></html>
"""

    def check_landing(self, text):
        for src in re.findall(r'(?:src|srcset)="([^"]+)"', text):
            if not src.startswith("assets/shots/") or not (SITE_DIR / src[len("assets/"):]).is_file():
                raise SystemExit(f"docs/site/index.html: the image is not a file in docs/site/shots: {src}")
        for href in re.findall(r'href="([^"]+)"', text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith("//"):
                continue
            path, _, frag = href.partition("#")
            if path.startswith("assets/"):
                if not (SITE_DIR / path[len("assets/"):]).exists():
                    raise SystemExit(f"docs/site/index.html: link to a missing file: {href}")
                continue
            page = posixpath.normpath(path or ".").lstrip("./")
            page = "" if page in ("", ".") else page.rstrip("/") + "/"
            if page != "" and page not in self.anchors:
                raise SystemExit(f"docs/site/index.html: link to a missing page: {href}")
            ids = set(re.findall(r'id="([^"]+)"', text)) if page == "" else self.anchors[page]
            if frag and frag not in ids:
                raise SystemExit(f"docs/site/index.html: link to a missing anchor: {href}")

    def run(self, out):
        rendered = [(page, *self.render(src, page)) for src, page, _, _ in PAGES]
        for src, page, anchor in self.links:
            if anchor not in self.anchors.get(page, set()):
                raise SystemExit(f"{src}: link to a missing anchor: {page}#{anchor}")
        landing = (SITE_DIR / "index.html").read_text(encoding="utf-8")
        self.check_landing(landing)
        if out.exists():
            shutil.rmtree(out)
        for page, title, body in rendered:
            folder = out / page
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "index.html").write_text(self.document(page, title, body), encoding="utf-8")
        (out / "index.html").write_text(landing, encoding="utf-8")
        (out / "assets").mkdir()
        for name in ("site.css", "favicon.svg"):
            shutil.copy(SITE_DIR / name, out / "assets" / name)
        # The screenshots of the examples (tools/shots.sh).
        shutil.copytree(SITE_DIR / "shots", out / "assets" / "shots")
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered) + 1} pages to {out}")


if __name__ == "__main__":
    Build().run(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out" / "docs-site")
