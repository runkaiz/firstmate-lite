#!/usr/bin/env python3
"""Implement the source-quote contract owned by fm-brief.sh's header/--help."""

import json
import re
import sys
from pathlib import Path


MAX_QUOTE_BYTES = 65_536
ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?)|[ \t]*)$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


def section(spec):
    path_text, separator, title = spec.rpartition("#")
    if not separator or not path_text or not title:
        raise ValueError("--quote requires <report-path>#<heading text>")
    path = Path(path_text).absolute()
    if not path.is_file():
        raise ValueError(f"--quote source must be a readable regular file: {path}")
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    if "\0" in text:
        raise ValueError(f"--quote source contains NUL bytes: {path}")
    headings = []
    offset = 0
    fence = None
    # Split only on LF: other Unicode line separators are content, not Markdown.
    lines = raw.split(b"\n")
    for index, line in enumerate(lines):
        if index < len(lines) - 1:
            line += b"\n"
        scan = line.decode("utf-8").rstrip("\r\n")
        marker = FENCE.fullmatch(scan)
        if fence:
            if (marker and marker[1][0] == fence[0]
                    and len(marker[1]) >= fence[1] and not marker[2].strip()):
                fence = None
        elif marker and not (marker[1][0] == "`" and "`" in marker[2]):
            fence = (marker[1][0], len(marker[1]))
        else:
            heading = ATX.fullmatch(scan)
            if heading:
                name = re.sub(r"[ \t]+#+[ \t]*$", "", heading[2] or "").strip(" \t")
                headings.append((offset, len(heading[1]), name))
        offset += len(line)
    matches = [i for i, heading in enumerate(headings) if heading[2] == title]
    if len(matches) != 1:
        reason = "missing" if not matches else "ambiguous"
        raise ValueError(f"--quote heading {reason}: {title!r} in {path}")
    index = matches[0]
    start, level, _ = headings[index]
    end = next((pos for pos, depth, _ in headings[index + 1:] if depth <= level), len(raw))
    return path, title, raw[start:end]


def render(specs):
    quotes = [section(spec) for spec in specs]
    size = sum(len(content) for _, _, content in quotes)
    if size > MAX_QUOTE_BYTES:
        raise ValueError(f"--quote selections total {size} bytes; limit is {MAX_QUOTE_BYTES} bytes")
    output = bytearray(b"# Source quotes\n")
    for index, (path, title, content) in enumerate(quotes, 1):
        longest = max((len(run) for run in re.findall(rb"`+", content)), default=0)
        fence = b"`" * max(3, longest + 1)
        label = (f"\n## Source {index}\nSource: {json.dumps(str(path))}\n"
                 f"Heading: {json.dumps(title)}\n\n")
        output.extend(label.encode("utf-8") + fence + b"markdown\n" + content)
        if not content.endswith(b"\n"):
            output.extend(b"\n")
        output.extend(fence + b"\n")
    return output


if __name__ == "__main__":
    try:
        sys.stdout.buffer.write(render(sys.argv[1:]))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
