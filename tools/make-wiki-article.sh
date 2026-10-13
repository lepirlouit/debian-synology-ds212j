#!/bin/bash
# Regenerate docs/wiki-article.mediawiki from README.md for the MediaWiki article.
# - relative links to repository files become absolute GitHub links
# - the H1 is dropped (MediaWiki shows the page title), a repository note and categories are added
# Needs docker (pandoc/core image). Publish with tools/wiki-publish.py.
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
BASE=https://github.com/lepirlouit/debian-synology-ds212j
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$TOP" "$BASE" "$TMP/README-abs.md" <<'PY'
import os, re, sys
top, base, out = sys.argv[1:4]
s = open(os.path.join(top, "README.md")).read()
def fix(m):
    text, target = m.group(1), m.group(2)
    if re.match(r"(https?:|mailto:|#)", target):
        return m.group(0)
    path = target.rstrip("/")
    kind = "tree" if os.path.isdir(os.path.join(top, path)) else "blob"
    return f"[{text}]({base}/{kind}/main/{path})"
open(out, "w").write(re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", fix, s))
PY

docker run --rm -v "$TMP":/data -w /data --user "$(id -u):$(id -g)" pandoc/core:3.5 \
	-f gfm -t mediawiki README-abs.md -o wiki.mediawiki

python3 - "$TMP/wiki.mediawiki" "$TOP/docs/wiki-article.mediawiki" "$BASE" <<'PY'
import re, sys
src, dst, base = sys.argv[1:4]
s = open(src).read()
s = re.sub(r'\A<span id="[^"]*"></span>\n= [^\n]* =\n\n', "", s)
note = f"''Patches, scripts and configuration files: [{base} {base.split('//')[1]}].''\n\n"
s = re.sub(r"(</blockquote>\n)", lambda m: m.group(1) + note, s, count=1)
s = s.rstrip() + "\n\n[[Category:Synology]]\n[[Category:Debian]]\n[[Category:Linux]]\n"
open(dst, "w").write(s)
PY
echo "docs/wiki-article.mediawiki: $(wc -l < "$TOP/docs/wiki-article.mediawiki") lines"
