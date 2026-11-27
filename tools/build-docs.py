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

A line `<!-- live -->`, `<!-- showcase: WxH; narrow: WxH -->` (an app in
the page itself, wide and with no toolbar, see assets/showcase.js), or `<!-- widget: NAME; shot: SCRIPT -->` before a
`tcl` block makes the block a live snippet (docs/dev/interactive-docs.md).
The build writes a figure with the code and the shot widget-NAME-light.png
and widget-NAME-dark.png, and the page loads assets/live.js. An image
paragraph of the same shot just before the marker goes into the figure.
A marker can have `title: TEXT;` before `shot:`, for the overview grid.
The line `<!-- widget-grid -->` in docs/widgets/README.md becomes a grid
with a card for each widget snippet of the widget pages.
"""

import html
import json
import posixpath
import re
import shutil
import sys
from pathlib import Path

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/beetlebugorg/ztk"
SITE = "https://beetlebug.org/ztk/"

# Source file, page folder, sidebar group, sidebar title. Plans, task
# lists, and reports are in docs/dev/ and are not part of the site.
PAGES = [
    ("README.md", "overview/", "Start", "Overview"),
    ("docs/install.md", "install/", "Start", "Install"),
    ("docs/quickstart.md", "quickstart/", "Start", "Quick start"),
    ("docs/agents.md", "agents/", "Start", "For agents"),
    ("docs/replay.md", "replay/", "Start", "Watch it get built"),
    ("docs/widgets/README.md", "widgets/", "Widgets", "All widgets"),
    ("docs/toys.md", "toys/", "Widgets", "Toys"),
    ("docs/build/backspin.md", "toys/backspin/", "Widgets", "Backspin, part by part"),
    ("docs/build/tinmoon.md", "toys/tinmoon/", "Widgets", "Tin Moon, part by part"),
    ("docs/widgets/basic.md", "widgets/basic/", "Widgets", "Frames, labels, and buttons"),
    ("docs/widgets/toggles.md", "widgets/toggles/", "Widgets", "Check and radio buttons"),
    ("docs/widgets/entry.md", "widgets/entry/", "Widgets", "Entry and spinbox"),
    ("docs/widgets/range.md", "widgets/range/", "Widgets", "Scale and scrollbar"),
    ("docs/widgets/listbox.md", "widgets/listbox/", "Widgets", "Listbox"),
    ("docs/widgets/canvas.md", "widgets/canvas/", "Widgets", "Canvas"),
    ("docs/widgets/text.md", "widgets/text/", "Widgets", "Text"),
    ("docs/widgets/tree.md", "widgets/tree/", "Widgets", "Tree"),
    ("docs/widgets/panes.md", "widgets/panes/", "Widgets", "Panes and tabs"),
    ("docs/widgets/dialogs.md", "widgets/dialogs/", "Widgets", "Dialogs"),
    ("docs/widgets/menus.md", "widgets/menus/", "Widgets", "Menus"),
    ("docs/widgets/terminal.md", "widgets/terminal/", "Widgets", "Terminal"),
    ("docs/widgets/ttk.md", "widgets/ttk/", "Widgets", "Themed widgets (ttk)"),
    ("docs/widgets/geometry.md", "widgets/geometry/", "Widgets", "pack, grid, and place"),
    ("docs/styling.md", "styling/", "Guide", "Styling and themes"),
    ("docs/animation.md", "animation/", "Guide", "Animation"),
    ("docs/web.md", "web/", "Guide", "On the web"),
    ("docs/windows.md", "windows/", "Guide", "On Windows"),
    ("docs/macos.md", "macos/", "Guide", "On macOS"),
    ("docs/embedding.md", "embedding/", "Guide", "Embed in Zig"),
    ("docs/performance.md", "performance/", "Project", "Performance"),
    ("docs/differences.md", "differences/", "Project", "Differences from Tk"),
    ("docs/faq.md", "faq/", "Project", "FAQ"),
    ("CHANGELOG.md", "changelog/", "Project", "Changelog"),
    ("CONTRIBUTING.md", "contributing/", "Project", "Contributing"),
    ("SECURITY.md", "security/", "Project", "Security"),
]
PAGES.append(("docs/references/README.md", "references/", "References", "All references"))
for ref in sorted((ROOT / "docs/references").glob("*.md")):
    if ref.name != "README.md":
        title = ref.read_text(encoding="utf-8").splitlines()[0].lstrip("# ")
        PAGES.append((f"docs/references/{ref.name}", f"references/{ref.stem}/", "References", title))
# Old page folders and their new place.
REDIRECTS = {
    "npm/": "web/#install-from-npm",
    "release/": "changelog/",
    "plan/": f"{REPO}/blob/main/docs/dev/plan.md",
    "tk-size/": f"{REPO}/blob/main/docs/dev/tk-size.md",
    "review/": f"{REPO}/blob/main/docs/dev/review.md",
    "tasks/": f"{REPO}/blob/main/docs/dev/tasks/README.md",
    "stage2-tasks/": f"{REPO}/blob/main/docs/dev/stage2-tasks/README.md",
}
for folder in ("tasks", "stage2-tasks"):
    for task in sorted((ROOT / "docs/dev" / folder).glob("[0-9]*.md")):
        REDIRECTS[f"{folder}/{task.stem}/"] = f"{REPO}/blob/main/docs/dev/{folder}/{task.name}"
# The sidebar shows these groups closed, except on a page of the group.
FOLDED = {"References"}
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


MARK = re.compile(r"^<!-- (live|showcase: \d+x\d+; narrow: \d+x\d+|widget: ([a-z0-9-]+);.*) -->$")


class Build:
    live = None

    def __init__(self):
        self.md = MarkdownIt("commonmark", {"html": False}).enable("table").enable("strikethrough")
        plain = self.md.renderer.rules.get("fence")
        def fence(tokens, idx, options, env):
            t = tokens[idx]
            return self.live_figure(t.meta, t.content, env["root"]) if t.meta.get("live") else plain(tokens, idx, options, env)
        self.md.renderer.rules["fence"] = fence
        self.anchors = {}
        self.links = []

    def widgets(self):
        """The widget snippets of the widget pages, for the overview grid:
        (name, title, kind, page, anchor) in the order of PAGES."""
        found = []
        for src, page, _, _ in PAGES:
            if not src.startswith("docs/widgets/") or src.endswith("README.md"):
                continue
            for t in self.live_blocks(src, self.md.parse((ROOT / src).read_text(encoding="utf-8"))):
                if t.type == "fence" and t.meta.get("live") and t.meta["name"] and t.meta.get("shot") \
                        and not t.meta["name"].startswith("toy-"):
                    words = [line.split()[0] for line in t.content.splitlines() if line.strip() and not line.startswith("#")]
                    words = [w for w in words if w not in ("set", "proc", "bind", "after", "foreach", "wm")]
                    kind = "ztk" if any(w in ("ztk::terminal", "ztk::tooltip") for w in words) else "ttk" if words and words[0].startswith("ttk::") else "Tk"
                    found.append((t.meta["name"], t.meta["title"], kind, page, t.meta["id"]))
        return found

    def grid(self, page):
        """The overview grid: one card for each widget snippet."""
        root = rel(page, "")
        cards = []
        for name, title, kind, other, anchor in self.widgets():
            self.links.append(("docs/widgets/README.md", other, anchor))
            cards.append(
                f'<a class="wcard" href="{rel(page, other)}#{anchor}">'
                f'<picture><source srcset="{root}assets/shots/widget-{name}-dark.png" media="(prefers-color-scheme: dark)">'
                f'<img src="{root}assets/shots/widget-{name}-light.png" width="360" height="240" alt="" loading="lazy"></picture>'
                f'<span class="wname">{html.escape(title)}</span><span class="wkind">{kind}</span></a>')
        return f'<div class="wgrid">{"".join(cards)}</div>\n'

    def render(self, src, page):
        tokens = self.live_blocks(src, self.md.parse((ROOT / src).read_text(encoding="utf-8")))
        for i, t in enumerate(tokens):
            m = re.match(r"^<!-- replay: ([a-z0-9-]+) -->$", t.content.strip()) if t.type == "inline" else None
            if m:
                # A replay (docs/site/replays/NAME.json, assets/replay.js) and the live snippet that it drives.
                rec = json.loads((SITE_DIR / "replays" / f"{m.group(1)}.json").read_text(encoding="utf-8"))
                first = next(s["script"] for s in rec["steps"] if "script" in s)
                root = rel(page, "")
                tokens[i - 1].type = tokens[i + 1].type = "html_block"
                tokens[i - 1].content, tokens[i + 1].content = "", ""
                t.type, t.children = "html_block", None
                t.content = (f'<div class="replay" data-src="{root}assets/replays/{m.group(1)}.json"><h2 class="rp-title">{html.escape(rec["title"])}</h2></div>'
                             + self.live_figure({"live": True, "name": None, "id": f"live-replay-{m.group(1)}"}, first, root)
                             + f'<script type="module" src="{root}assets/replay.js"></script>\n')
                continue
            m = re.match(r"^<!-- stage: (toy-[a-z0-9-]+) -->$", t.content.strip()) if t.type == "inline" else None
            if m:
                # A build replay of a toy on a stage of fixed size (assets/stage.js):
                # the steps, the code of the step, and the handheld of the toy.
                name = m.group(1)
                rec = json.loads((SITE_DIR / "replays" / f"{name}.json").read_text(encoding="utf-8"))
                first = next(s["script"] for s in rec["steps"] if "script" in s)
                root = rel(page, "")
                tokens[i - 1].type = tokens[i + 1].type = "html_block"
                tokens[i - 1].content, tokens[i + 1].content = "", ""
                t.type, t.children = "html_block", None
                fig = self.live_figure({"live": True, "name": name, "id": f"live-stage-{name}"}, first, root)
                t.content = (f'<section class="stage" data-src="{root}assets/replays/{name}.json" tabindex="0" '
                             f'aria-label="{html.escape(rec["title"])}. Left and Right step, Space plays.">'
                             '<div class="st-bar"><button type="button" class="st-prev" aria-label="Previous step">&#9664;</button>'
                             '<button type="button" class="st-play">Play</button>'
                             '<button type="button" class="st-next" aria-label="Next step">&#9654;</button>'
                             '<input type="range" class="st-range" min="0" max="0" value="0" aria-label="Step">'
                             '<span class="st-label" aria-live="polite"></span></div>'
                             '<ol class="st-steps" aria-label="The prompts and the answers"></ol>'
                             '<div class="st-code" aria-label="The code of the step"><pre><code></code></pre></div>'
                             f'<div class="st-view">{fig}<div class="st-mark" aria-hidden="true"><span></span></div></div>'
                             f'</section><script type="module" src="{root}assets/stage.js"></script>'
                             f'<script type="module" src="{root}assets/showcase.js"></script>\n')
                continue
            if t.type == "inline" and t.content.strip() == "<!-- widget-grid -->":
                tokens[i - 1].type = tokens[i + 1].type = "html_block"
                tokens[i - 1].content, tokens[i + 1].content = "", ""
                t.type, t.content, t.children = "html_block", self.grid(page), None
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
        for token in tokens:
            if token.type == "fence" and token.meta.get("live"):
                anchor = token.meta["id"]
                if anchor in ids:
                    raise SystemExit(f"{src}: two live snippets have the id {anchor}")
                ids.add(anchor)
        self.anchors[page] = ids
        body = self.md.renderer.render(tokens, self.md.options, {"root": rel(page, "")})
        body = body.replace("<table>", '<div class="table"><table>').replace("</table>", "</table></div>")
        body = self.more(src, body)
        return title or src, self.alerts(body)

    @staticmethod
    def more(src, body):
        """`<!-- more: TITLE -->` and `<!-- end more -->` lines make a folded
        section: the reader opens it with its title."""
        body, opened = re.subn(r"<p>&lt;!-- more: (.+?) --&gt;</p>", r'<details class="more"><summary>\1</summary>', body)
        body, closed = re.subn(r"<p>&lt;!-- end more --&gt;</p>", "</details>", body)
        if opened != closed:
            raise SystemExit(f"{src}: {opened} lines of <!-- more: --> and {closed} of <!-- end more -->")
        return body

    def live_blocks(self, src, tokens):
        """Marks each `tcl` block after a live marker, and drops the marker
        and an image paragraph of the same shot just before it."""
        out, i, count = [], 0, 0
        while i < len(tokens):
            t = tokens[i]
            m = MARK.match(tokens[i + 1].content.strip()) if t.type == "paragraph_open" and i + 1 < len(tokens) else None
            if not m:
                out.append(t)
                i += 1
                continue
            fence = tokens[i + 3] if i + 3 < len(tokens) else None
            if fence is None or fence.type != "fence" or fence.info.strip() != "tcl":
                raise SystemExit(f"{src}: a live marker is not just before a tcl block")
            name = m.group(2)
            title = re.search(r"; title: ([^;]+);", m.group(1))
            count += 1
            meta = {"live": True, "name": name, "id": f"live-{name}" if name else f"live-{count}", "alt": "",
                    "still": m.group(1).endswith("shot: update"), "title": title.group(1).strip() if title else None,
                    "showcase": re.findall(r"\d+x\d+", m.group(1)) if m.group(1).startswith("showcase: ") else None}
            if meta["title"] is None:
                heads = [k for k in range(len(out) - 1) if out[k].type == "heading_open"]
                meta["title"] = inline_text(out[heads[-1] + 1]) if heads else name
            if name:
                shot = f"widget-{name}-light.png"
                if len(out) >= 3 and out[-3].type == "paragraph_open" and out[-2].children and len(out[-2].children) == 1 \
                        and out[-2].children[0].type == "image" and out[-2].children[0].attrGet("src").endswith(shot):
                    meta["alt"] = inline_text(out[-2].children[0]) or out[-2].children[0].content
                    del out[-3:]
                meta["shot"] = (SITE_DIR / "shots" / shot).is_file()
            fence.meta = meta
            out.append(fence)
            i += 4
        return out

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

    @staticmethod
    def toy_games(root):
        """The code of each toy of the widget pages, with its name, its
        page, and its shot, in hidden pre elements."""
        games = []
        for f in sorted((ROOT / "docs" / "widgets").glob("*.md")):
            text = f.read_text(encoding="utf-8")
            page = PAGE_OF[f"docs/widgets/{f.name}"]
            # The game of a marker is the last "### Play: NAME" heading before it.
            for m in re.finditer(r"<!-- widget: (toy-[a-z]+);[^\n]*-->\n```tcl\n(.*?)```\n", text, re.S):
                heads = re.findall(r"^### Play: (.+)$", text[:m.start()], re.M)
                if not heads:
                    raise SystemExit(f"{f}: the toy {m.group(1)} has no heading \"### Play: NAME\"")
                title, name, code = heads[-1].strip(), m.group(1), m.group(2)
                stage = PAGE_OF.get(f"docs/build/{name.removeprefix('toy-')}.md")
                build = f' data-build="{root}{stage}"' if stage else ""
                games.append(f'<pre hidden class="toy-game" data-name="{name}" data-slug="{slug(title)}" data-title="{html.escape(title, quote=True)}" '
                             f'data-page="{root}{page}#play-{slug(title)}" data-shot="{root}assets/shots/widget-{name}"'
                             # A toy with a stage (docs/build/NAME.md) links to it.
                             f'{build}>{html.escape(code)}</pre>')
        return "".join(games)

    @staticmethod
    def live_figure(meta, code, root):
        """The HTML of a live snippet. assets/live.js turns the pre into an
        editor and the picture into the running window."""
        name = meta["name"]
        if meta.get("shot"):
            alt = html.escape(meta["alt"] or f"The widget {name}", quote=True)
            pic = (f'<picture><source srcset="{root}assets/shots/widget-{name}-dark.png" media="(prefers-color-scheme: dark)">'
                   f'<img src="{root}assets/shots/widget-{name}-light.png" width="360" height="240" alt="{alt}" loading="lazy"></picture>')
        else:
            pic = '<span class="ld-empty">The live window shows here.</span>'
        data = f' data-name="{html.escape(name)}"' if name else ""
        # A shot of a plain run ("shot: update") equals the first frame of the snippet.
        data += ' data-still="1"' if meta.get("still") and meta.get("shot") else ""
        code_html = f'<div class="ld-code"><pre><code class="language-tcl">{html.escape(code)}</code></pre></div>'
        if name == "toy-console":
            # The handheld of the Toys page: the game list first, and the
            # code of the game next to the handheld. The code of each toy
            # of the widget pages is in a hidden pre, for assets/toys.js.
            return (f'<figure class="live-demo toy toy-console" id="{meta["id"]}"{data}>'
                    f'<div class="ld-view"><div class="ld-frame">{pic}</div></div>'
                    f'{code_html}'
                    f'<figcaption class="ld-bar"><span class="ld-tag">Live</span>'
                    f'<a class="toy-page" hidden></a><span class="toy-status" role="status"></span></figcaption>'
                    f'<div class="ld-err" role="status" hidden></div>{Build.toy_games(root)}</figure>\n')
        if meta.get("showcase"):
            # A showcase: the app in the page itself, over the width of
            # the page and with no toolbar (assets/showcase.js). The size is
            # the logical size of the app, and the narrow size is for a
            # phone. The code is under a toggle.
            (w, h), (nw, nh) = [x.split("x") for x in meta["showcase"]]
            lines = code.count("\n")
            return (f'<figure class="showcase" data-size="{w}x{h}" data-narrow="{nw}x{nh}" style="--ar: {w} / {h}; --nar: {nw} / {nh}">'
                    f'<div class="sc-stage"><p class="sc-poster">The piece starts when it comes into view. It needs JavaScript and WebAssembly.</p></div>'
                    f'<details class="sc-code"><summary>The code: {lines} lines of Tcl</summary>{code_html}</details></figure>\n')
        if name and name.startswith("toy-"):
            # A toy: the handheld first and large, and its code under a
            # toggle, so that the page next to the game is short.
            return (f'<figure class="live-demo toy" id="{meta["id"]}"{data}>'
                    f'<div class="ld-view"><div class="ld-frame">{pic}</div></div>'
                    f'<details class="ld-more"><summary>Show the code</summary>{code_html}</details>'
                    f'<figcaption class="ld-bar"><span class="ld-tag">Live</span></figcaption>'
                    f'<div class="ld-err" role="status" hidden></div></figure>\n')
        return (f'<figure class="live-demo" id="{meta["id"]}"{data}>'
                f'{code_html}'
                f'<div class="ld-view"><div class="ld-frame">{pic}</div></div>'
                f'<figcaption class="ld-bar"><span class="ld-tag">Live</span></figcaption>'
                f'<div class="ld-err" role="status" hidden></div></figure>\n')

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
        script = f'\n<script type="module" src="{root}assets/live.js"></script>' if 'class="live-demo' in body else ""
        if 'class="showcase' in body:
            script += f'\n<script type="module" src="{root}assets/showcase.js"></script>'
        if 'data-name="toy-' in body:
            script += f'\n<script type="module" src="{root}assets/toys.js"></script>'

        desc = "A Tk replacement in Zig, on the ztcl interpreter, with a GPU renderer and CSS styles."
        return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{name}</title><meta name="description" content="{desc}">
<link rel="canonical" href="{SITE}{page}">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}assets/site.css">{script}</head>
<body><a class="skip" href="#content">Skip to the content</a>
<header class="top"><div class="wrap"><a class="logo" href="{root}"><span class="glyph" aria-hidden="true">tk</span>ztk</a>
<nav class="toplinks" aria-label="Site"><a href="{root}overview/" aria-current="page">Docs</a><a href="{root}widgets/">Widgets</a><a href="{root}toys/">Toys</a><a class="sib" href="https://beetlebug.org/ztcl/">ztcl</a><a href="{REPO}">GitHub</a></nav></div></header>
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
            if path.startswith("play/"):
                # The web build of --live. A build with no --live has no play/ folder.
                if self.live is not None and not (self.live / path[len("play/"):]).exists():
                    raise SystemExit(f"docs/site/index.html: link to a missing file: {href}")
                continue
            if path in ("llms.txt", "llms-full.txt", "api.json"):
                # The files for agents (agents()).
                continue
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

    @staticmethod
    def agents(out):
        """The files for agents (https://llmstxt.org): llms.txt lists the
        pages, llms-full.txt has the Markdown of each page, and api.json
        is the API index of tools/api-index.tcl."""
        intro = ("# ztk\n\n> Tk rebuilt in Zig on the ztcl interpreter. A script uses the Tk 8.6 commands, "
                 "and ztk draws it with CSS styles: on Wayland, on Windows with Direct3D 12, and in a browser with WebGPU or WebGL 2. "
                 "An agent can see and drive the window it builds: ztk::snapshot gives a PNG of a widget, "
                 "ztk::tree gives each widget with its class and its box, and ztk::inject sends pointer and key "
                 "events. `ztk --headless` runs a script with no display.\n\n")
        lines, full, group = [intro], [intro], None
        for src, page, section, label in PAGES:
            if section == "References":
                continue
            if section != group:
                lines.append(f"\n## {section}\n\n")
                group = section
            lines.append(f"- [{label}]({SITE}{page})\n")
            full.append(f"\n\n<!-- {SITE}{page} -->\n\n" + (ROOT / src).read_text(encoding="utf-8"))
        lines.append(f"\n## For agents\n\n- [API index]({SITE}api.json): each command, and each widget command with its options and their defaults, from the build of the site.\n"
                     f"- [Full text]({SITE}llms-full.txt): the Markdown of each page above.\n")
        (out / "llms.txt").write_text("".join(lines), encoding="utf-8")
        (out / "llms-full.txt").write_text("".join(full), encoding="utf-8")
        shutil.copy(SITE_DIR / "api.json", out / "api.json")

    def run(self, out):
        rendered = [(page, *self.render(src, page)) for src, page, _, _ in PAGES]
        for src, page, anchor in self.links:
            if anchor not in self.anchors.get(page, set()):
                raise SystemExit(f"{src}: link to a missing anchor: {page}#{anchor}")
        landing = (SITE_DIR / "index.html").read_text(encoding="utf-8")
        # The live snippet of the landing page: docs/site/hero.tcl.
        hero = {"live": True, "name": "hero", "id": "live-hero", "alt": "The window of the snippet: a greeting form, a scale that drives a progress bar, and a switch",
                "still": True, "shot": (SITE_DIR / "shots" / "widget-hero-light.png").is_file()}
        figure = self.live_figure(hero, (SITE_DIR / "hero.tcl").read_text(encoding="utf-8"), "").replace('class="live-demo"', 'class="live-demo stack"')
        landing = landing.replace("<!-- live: hero -->", figure)
        # A toy of a widget page on the landing page: `<!-- live: toy-NAME -->`.
        for name in re.findall(r"<!-- live: (toy-[a-z]+) -->", landing):
            code = next((m.group(1) for f in sorted((ROOT / "docs" / "widgets").glob("*.md"))
                         for m in [re.search(rf"<!-- widget: {name};[^\n]*-->\n```tcl\n(.*?)```\n", f.read_text(encoding="utf-8"), re.S)] if m), None)
            if code is None:
                raise SystemExit(f"docs/site/index.html: no widget page has the toy {name}")
            meta = {"live": True, "name": name, "id": f"live-{name}", "alt": f"The toy {name[4:]} before it runs", "still": True,
                    "shot": (SITE_DIR / "shots" / f"widget-{name}-light.png").is_file()}
            landing = landing.replace(f"<!-- live: {name} -->", self.live_figure(meta, code, ""))
        self.check_landing(landing)
        landing = landing.replace("</head>", '<script type="module" src="assets/live.js"></script>\n</head>', 1)
        if 'data-name="toy-' in landing:
            landing = landing.replace("</head>", '<script type="module" src="assets/toys.js"></script>\n</head>', 1)
        if out.exists():
            shutil.rmtree(out)
        for page, title, body in rendered:
            folder = out / page
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "index.html").write_text(self.document(page, title, body), encoding="utf-8")
        (out / "index.html").write_text(landing, encoding="utf-8")
        (out / "assets").mkdir()
        for name in ("site.css", "favicon.svg", "live.js", "replay.js", "stage.js", "toys.js", "showcase.js"):
            shutil.copy(SITE_DIR / name, out / "assets" / name)
        # The screenshots of the examples (tools/shots.sh).
        shutil.copytree(SITE_DIR / "shots", out / "assets" / "shots")
        shutil.copytree(SITE_DIR / "replays", out / "assets" / "replays")
        # The live demos and the playground: the files of `zig build wasm`, when they exist.
        if self.live is not None:
            shutil.copytree(self.live, out / "play")
            print(f"copied the web build from {self.live} to {out / 'play'}")
        for old, new in REDIRECTS.items():
            if not new.startswith("https:"):
                page, _, frag = new.partition("#")
                if page not in self.anchors or (frag and frag not in self.anchors[page]):
                    raise SystemExit(f"redirect {old}: link to a missing page or anchor: {new}")
                new = rel(old, page) + (f"#{frag}" if frag else "")
            (out / old).mkdir(parents=True, exist_ok=True)
            target = html.escape(new)
            (out / old / "index.html").write_text(
                f'<!doctype html><meta charset="utf-8"><title>Moved</title>'
                f'<meta http-equiv="refresh" content="0; url={target}">'
                f'<link rel="canonical" href="{target}"><a href="{target}">This page moved.</a>\n',
                encoding="utf-8")
        self.agents(out)
        (out / ".nojekyll").write_text("", encoding="utf-8")
        print(f"wrote {len(rendered) + 1} pages to {out}")


if __name__ == "__main__":
    # Use: build-docs.py [output folder] [--live zig-out/web]
    args = sys.argv[1:]
    live = None
    if "--live" in args:
        i = args.index("--live")
        live = Path(args[i + 1]).resolve()
        if not (live / "ztk.wasm").is_file():
            raise SystemExit(f"--live: no ztk.wasm in {live}: run zig build wasm first")
        del args[i : i + 2]
    b = Build()
    b.live = live
    b.run(Path(args[0]).resolve() if args else ROOT / "zig-out" / "docs-site")
