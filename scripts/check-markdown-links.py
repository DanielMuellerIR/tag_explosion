#!/usr/bin/env python3
"""Prüft relative Dateiziele in den getrackten Markdown-Dateien."""
import re
import string
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
LINK_START = re.compile(r"\]\(\s*")
LINK_DEFINITION = re.compile(r"^ {0,3}\[(?!\^)[^\]\n]+\]:\s*")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
TICKS = re.compile(r"`+")


def escaped(line, position):
    prefix = line[:position]
    return (len(prefix) - len(prefix.rstrip("\\"))) % 2 == 1


def hide_code(line):
    runs = list(TICKS.finditer(line))
    pieces = []
    previous = 0
    index = 0
    while index < len(runs):
        opening = runs[index]
        index += 1
        if escaped(line, opening.start()):
            continue
        close = next((i for i in range(index, len(runs)) if runs[i][0] == opening[0]), None)
        if close is None:
            continue
        end = runs[close].end()
        pieces.extend((line[previous:opening.start()], " " * (end - opening.start())))
        previous = end
        index = close + 1
    return "".join(pieces) + line[previous:]


def destination(line, start):
    if start == len(line):
        return ""
    angle = line[start] == "<"
    index = start + int(angle)
    depth = 0
    target = []
    while index < len(line):
        char = line[index]
        if char == "\\" and index + 1 < len(line) and line[index + 1] in string.punctuation:
            target.append(line[index + 1])
            index += 2
            continue
        if angle and char == ">":
            return "".join(target)
        if not angle:
            if char.isspace() or (char == ")" and depth == 0):
                break
            depth += (char == "(") - (char == ")")
        target.append(char)
        index += 1
    return "" if angle or depth else "".join(target)


def targets(source):
    fence = ""
    for number, line in enumerate(source.splitlines(), start=1):
        marker = FENCE.match(line)
        if marker:
            if not fence:
                fence = marker[1]
                continue
            if marker[1].startswith(fence) and not marker[2].strip():
                fence = ""
                continue
        if fence:
            continue
        if line.startswith(("    ", "\t")):
            continue
        original = line
        line = hide_code(line)
        definition = LINK_DEFINITION.match(line)
        if definition:
            yield number, destination(original, definition.end())
        for match in LINK_START.finditer(line):
            before = line.rfind("[", 0, match.start())
            if before != -1 and not escaped(line, before) and not escaped(line, match.start()):
                yield number, destination(original, match.end())


def main():
    markdown = subprocess.check_output(["git", "ls-files", "-z", "--", "*.md"], cwd=ROOT).decode()
    failed = False
    for name in filter(None, markdown.split("\0")):
        file = ROOT / name
        for line, target in targets(file.read_text(encoding="utf-8")):
            link = urlsplit(target)
            if link.scheme or link.netloc or not link.path or link.path.startswith("/"):
                continue
            if not (file.parent / unquote(link.path)).exists():
                print(f"{name}:{line}: Linkziel fehlt: {target}")
                failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
