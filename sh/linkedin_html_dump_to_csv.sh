#!/bin/sh

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 path_to/html.html [output.csv]" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="${2:-connections.csv}"

if [ ! -f "$INPUT" ]; then
  echo "Error: file not found: $INPUT" >&2
  exit 1
fi

python3 - "$INPUT" "$OUTPUT" <<'PY'
import csv
import html
import re
import sys
from urllib.parse import urlparse, parse_qs, unquote

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path, "r", encoding="utf-8", errors="replace") as f:
    raw = f.read()

def clean_text(s):
    s = re.sub(r"<script\b.*?</script>", " ", s or "", flags=re.I | re.S)
    s = re.sub(r"<style\b.*?</style>", " ", s, flags=re.I | re.S)
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    s = s.replace("\u2019", "'")
    return re.sub(r"\s+", " ", s).strip()

def clean_name(s):
    s = clean_text(s)

    # LinkedIn badge suffixes that can leak from image alt text:
    #   Name's profile picture, open to work
    #   Name's profile picture, hiring
    #   Name profile picture, hiring
    badges = r"(open to work|hiring|actively hiring|looking for work|available for work)"

    s = re.sub(
        rf"\s*[’']s profile picture\s*,?\s*{badges}\s*$",
        "",
        s,
        flags=re.I,
    )
    s = re.sub(
        rf"\s+profile picture\s*,?\s*{badges}\s*$",
        "",
        s,
        flags=re.I,
    )
    s = re.sub(r"\s*[’']s profile picture\s*$", "", s, flags=re.I)
    s = re.sub(r"\s+profile picture\s*$", "", s, flags=re.I)

    # Clean up any remaining standalone badge suffix.
    s = re.sub(rf"\s*,?\s*{badges}\s*$", "", s, flags=re.I)

    return clean_text(s)

def attr(tag, name):
    m = re.search(r'\b' + re.escape(name) + r'\s*=\s*("|\')(.*?)\1', tag, flags=re.I | re.S)
    return html.unescape(m.group(2)) if m else ""

def normalize_profile_url(url):
    m = re.search(
        r"https?://(?:www\.)?linkedin\.com/in/[^/?#\"'&<>\s]+",
        html.unescape(url),
        flags=re.I,
    )
    if not m:
        return ""

    u = m.group(0).rstrip("/")
    parsed = urlparse(u)
    return "https://www.linkedin.com" + parsed.path.rstrip("/") + "/"

def profile_slug(profile_url):
    parts = [p for p in urlparse(profile_url).path.split("/") if p]
    return parts[1] if len(parts) >= 2 and parts[0] == "in" else ""

def get_context(pos, size=9000):
    return raw[pos:pos + size]

records = {}

anchor_re = re.compile(
    r'<a\b(?P<tag>[^>]*\bhref\s*=\s*["\'](?P<href>https?://(?:www\.)?linkedin\.com/in/[^"\']+)["\'][^>]*)>'
    r'(?P<body>.*?)</a>',
    flags=re.I | re.S
)

for m in anchor_re.finditer(raw):
    profile_url = normalize_profile_url(m.group("href"))
    if not profile_url:
        continue

    body = m.group("body")
    context = get_context(m.start())

    rec = records.setdefault(profile_url, {
        "name": "",
        "headline": "",
        "connected_on": "",
        "profile_url": profile_url,
        "profile_slug": profile_slug(profile_url),
        "recipient_id": "",
        "profile_urn": "",
        "message_url": "",
        "image_src": "",
        "image_alt": "",
    })

    # Name/headline are usually the first two <p> tags inside the text profile link.
    ps = re.findall(r"<p\b[^>]*>(.*?)</p>", body, flags=re.I | re.S)
    ps = [clean_text(p) for p in ps]
    ps = [p for p in ps if p and p.lower() != "message"]

    if len(ps) >= 1 and not rec["name"]:
        rec["name"] = clean_name(ps[0])

    if len(ps) >= 2 and not rec["headline"]:
        rec["headline"] = clean_text(ps[1])

    # Fallback name from image alt / aria-label.
    if not rec["name"]:
        alt_match = re.search(
            r'\b(?:alt|aria-label)\s*=\s*("|\')([^"\']*profile picture[^"\']*)\1',
            context,
            flags=re.I | re.S
        )
        if alt_match:
            rec["name"] = clean_name(alt_match.group(2))

    # Connected date.
    if not rec["connected_on"]:
        cm = re.search(
            r"Connected on\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})",
            clean_text(context),
            flags=re.I
        )
        if cm:
            rec["connected_on"] = cm.group(1)

    # Image src / alt.
    if not rec["image_src"] or not rec["image_alt"]:
        img = re.search(r"<img\b[^>]*>", context, flags=re.I | re.S)
        if img:
            img_tag = img.group(0)

            if not rec["image_src"]:
                rec["image_src"] = attr(img_tag, "src")

            if not rec["image_alt"]:
                rec["image_alt"] = clean_text(attr(img_tag, "alt"))

    # Message URL and LinkedIn internal recipient/profile IDs.
    if not rec["message_url"]:
        msg = re.search(
            r'href\s*=\s*("|\')(https?://www\.linkedin\.com/messaging/compose/\?[^"\']+)\1',
            context,
            flags=re.I | re.S
        )
        if msg:
            msg_url = html.unescape(msg.group(2))
            rec["message_url"] = msg_url

            parsed = urlparse(msg_url)
            q = parse_qs(parsed.query)

            rec["recipient_id"] = q.get("recipient", [""])[0]
            rec["profile_urn"] = unquote(q.get("profileUrn", [""])[0])

columns = [
    "name",
    "headline",
    "connected_on",
    "profile_url",
    "profile_slug",
    "recipient_id",
    "profile_urn",
    "message_url",
    "image_src",
    "image_alt",
]

rows = list(records.values())

# Remove junk rows that only had a URL but no useful card data.
rows = [
    r for r in rows
    if r["name"] or r["headline"] or r["connected_on"] or r["recipient_id"]
]

# Final cleanup pass in case a contaminated name came from an earlier duplicate record.
for r in rows:
    r["name"] = clean_name(r["name"])

with open(output_path, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=columns)
    writer.writeheader()
    writer.writerows(rows)

print("Wrote %d rows to %s" % (len(rows), output_path))
PY
