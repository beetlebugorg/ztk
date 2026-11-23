# SPDX-License-Identifier: BSD-2-Clause
"""Counts the size of a Tk source tree from its manual pages and tests.

Use: python3 -I tools/tk-count.py <tk source folder>

It reads the files as text. It runs no code of Tk. The output is one
table for the manual pages and one table for the test files.
"""
import glob
import os
import re
import sys


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def pages(root):
    rows = []
    for path in sorted(glob.glob(os.path.join(root, "doc", "*.n"))):
        text = read(path)
        # .OP starts one widget-specific option. .SO to .SE lists the
        # standard options that the widget has.
        own = len(re.findall(r"^\.OP\s+\S+", text, re.M))
        std = 0
        for block in re.finditer(r"^\.SO(.*?)^\.SE", text, re.M | re.S):
            std += len(re.findall(r"\\-(\w+)", block.group(1)))
        rows.append((os.path.basename(path), own, std, len(text.splitlines())))
    return rows


def tests(root):
    rows = []
    base = os.path.join(root, "tests")
    files = glob.glob(os.path.join(base, "*.test"))
    files += glob.glob(os.path.join(base, "ttk", "*.test"))
    for path in sorted(files):
        text = read(path)
        count = len(re.findall(r"^\s*test\s+\S+", text, re.M))
        rows.append((os.path.relpath(path, base), count, len(text.splitlines())))
    return rows


def main():
    root = sys.argv[1]
    page_rows = pages(root)
    print("| Manual page | Own options | Standard options | Lines |")
    print("|---|---|---|---|")
    for name, own, std, lines in page_rows:
        print(f"| `{name}` | {own} | {std} | {lines} |")
    print(f"| **{len(page_rows)} pages** | **{sum(r[1] for r in page_rows)}** "
          f"| **{sum(r[2] for r in page_rows)}** | **{sum(r[3] for r in page_rows)}** |")
    print()
    test_rows = tests(root)
    print("| Test file | Test lines | Lines |")
    print("|---|---|---|")
    for name, count, lines in test_rows:
        print(f"| `{name}` | {count} | {lines} |")
    print(f"| **{len(test_rows)} files** | **{sum(r[1] for r in test_rows)}** "
          f"| **{sum(r[2] for r in test_rows)}** |")


main()
