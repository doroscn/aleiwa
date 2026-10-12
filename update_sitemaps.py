#!/usr/bin/env python3
"""Generate Aleiwa XML sitemaps and LLM indexes from the repository's HTML files."""

from __future__ import annotations

import html
import re
import subprocess
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
from xml.etree import ElementTree as ET

BASE_URL = "https://www.aleiwa.com"
ROOT = Path(__file__).resolve().parent
SITEMAP_NS = "http://www.sitemaps.org/schemas/sitemap/0.9"
ET.register_namespace("", SITEMAP_NS)
TODAY = date.today().isoformat()
PREVIEW_PER_COUNTRY_TYPE = 30


class PageMetadataParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.h1_parts: list[str] = []
        self._in_title = False
        self._h1_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag.lower() == "title":
            self._in_title = True
        elif tag.lower() == "h1":
            self._h1_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False
        elif tag.lower() == "h1" and self._h1_depth:
            self._h1_depth -= 1

    def handle_data(self, data: str) -> None:
        text = " ".join(data.split())
        if not text:
            return
        if self._in_title:
            self.title_parts.append(text)
        if self._h1_depth:
            self.h1_parts.append(text)


def page_metadata(path: Path) -> tuple[str, str]:
    parser = PageMetadataParser()
    try:
        parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        pass
    title = " ".join(parser.title_parts).strip()
    h1 = " ".join(parser.h1_parts).strip()
    if not title:
        title = h1 or path.stem.replace("-", " ").replace("_", " ").title()
    description = title
    if h1 and h1.lower() not in title.lower():
        description = f"{title} — {h1}"
    return clean_text(title), clean_text(description)


def clean_text(value: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(value)).strip()


def relative_url(path: Path) -> str:
    rel = path.relative_to(ROOT).as_posix()
    if rel == "index.html":
        return BASE_URL + "/"
    return BASE_URL + "/" + rel


def last_modified(path: Path) -> str:
    """Use the last Git change date; fall back to a YYYYMMDD filename or today."""
    rel = path.relative_to(ROOT).as_posix()
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", rel],
            cwd=ROOT, check=True, capture_output=True, text=True, timeout=10,
        )
        value = result.stdout.strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            return value
    except (subprocess.SubprocessError, OSError):
        pass

    match = re.search(r"(?<!\d)(20\d{2})(\d{2})(\d{2})(?!\d)", path.stem)
    if match:
        try:
            return date(int(match.group(1)), int(match.group(2)), int(match.group(3))).isoformat()
        except ValueError:
            pass
    return TODAY


def collect_pages() -> dict[str, list[dict[str, str]]]:
    pages: dict[str, list[dict[str, str]]] = {
        "pages": [], "asn": [], "dns": [], "blog": []
    }

    # Core and other standalone HTML pages in the repository root.
    for path in sorted(ROOT.glob("*.html")):
        if path.name.lower() in {"404.html"}:
            continue
        title, description = page_metadata(path)
        pages["pages"].append(make_entry(path, title, description))

    # Country ASN pages.
    asn_dir = ROOT / "asn"
    if asn_dir.is_dir():
        for path in sorted(asn_dir.glob("*.html")):
            title, description = page_metadata(path)
            pages["asn"].append(make_entry(path, title, description))

    # Country public-DNS pages.
    dns_dir = ROOT / "nameserver"
    if dns_dir.is_dir():
        for path in sorted(dns_dir.glob("*.html")):
            title, description = page_metadata(path)
            pages["dns"].append(make_entry(path, title, description))

    # Blog articles and the blog landing page.
    blog_dir = ROOT / "blog"
    if blog_dir.is_dir():
        for path in sorted(blog_dir.glob("*.html")):
            title, description = page_metadata(path)
            pages["blog"].append(make_entry(path, title, description))

    # Stable ordering: country pages by path; blog pages newest first where filename dates exist.
    pages["pages"].sort(key=lambda x: x["url"])
    pages["asn"].sort(key=lambda x: x["url"])
    pages["dns"].sort(key=lambda x: x["url"])
    pages["blog"].sort(key=lambda x: (x["lastmod"], x["url"]), reverse=True)
    return pages


def make_entry(path: Path, title: str, description: str) -> dict[str, str]:
    return {
        "path": path.relative_to(ROOT).as_posix(),
        "url": relative_url(path),
        "title": title,
        "description": description,
        "lastmod": last_modified(path),
    }


def write_urlset(filename: str, entries: list[dict[str, str]], priority: str) -> None:
    root = ET.Element(f"{{{SITEMAP_NS}}}urlset")
    for entry in entries:
        url = ET.SubElement(root, f"{{{SITEMAP_NS}}}url")
        ET.SubElement(url, f"{{{SITEMAP_NS}}}loc").text = entry["url"]
        ET.SubElement(url, f"{{{SITEMAP_NS}}}lastmod").text = entry["lastmod"]
        ET.SubElement(url, f"{{{SITEMAP_NS}}}changefreq").text = "monthly"
        ET.SubElement(url, f"{{{SITEMAP_NS}}}priority").text = priority
    write_xml(filename, root)


def write_sitemap_index() -> None:
    root = ET.Element(f"{{{SITEMAP_NS}}}sitemapindex")
    for filename in (
        "sitemap-pages.xml", "sitemap-asn.xml", "sitemap-dns.xml", "sitemap-blog.xml"
    ):
        sitemap = ET.SubElement(root, f"{{{SITEMAP_NS}}}sitemap")
        ET.SubElement(sitemap, f"{{{SITEMAP_NS}}}loc").text = f"{BASE_URL}/{filename}"
        ET.SubElement(sitemap, f"{{{SITEMAP_NS}}}lastmod").text = TODAY
    write_xml("sitemap.xml", root)


def write_xml(filename: str, root: ET.Element) -> None:
    ET.indent(root, space="  ")
    body = ET.tostring(root, encoding="unicode", xml_declaration=False)
    (ROOT / filename).write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n' + body + "\n",
        encoding="utf-8",
    )


def markdown_link(entry: dict[str, str]) -> str:
    label = entry["title"].replace("\\", "\\\\").replace("]", "\\]")
    description = entry["description"].replace("\n", " ")
    return f"- [{label}]({entry['url']}): {description}"


def write_llms(pages: dict[str, list[dict[str, str]]]) -> None:
    all_entries = pages["pages"] + pages["asn"] + pages["dns"] + pages["blog"]
    # Keep the first occurrence if a URL appears in more than one category.
    unique: list[dict[str, str]] = []
    seen: set[str] = set()
    for entry in all_entries:
        if entry["url"] not in seen:
            unique.append(entry)
            seen.add(entry["url"])

    header = [
        "# Aleiwa Network Tools",
        "> Structured index for Aleiwa DNS, ASN, network information, and blog pages.",
        "",
        f"Source of truth: {BASE_URL}/sitemap.xml.",
        "",
        "## Sitemap files",
        f"- [Sitemap index]({BASE_URL}/sitemap.xml)",
        f"- [Core pages]({BASE_URL}/sitemap-pages.xml)",
        f"- [Country ASN pages]({BASE_URL}/sitemap-asn.xml)",
        f"- [Country DNS pages]({BASE_URL}/sitemap-dns.xml)",
        f"- [Blog and guides]({BASE_URL}/sitemap-blog.xml)",
        "- Full URL inventory: ./llms-full.txt",
        f"- Generated date: {TODAY}",
        f"- Total indexed URLs: {len(unique)}",
        "",
        "## Core Pages",
    ]
    compact = header + [markdown_link(e) for e in pages["pages"]]
    compact += ["", f"## ASN Pages (preview: first {PREVIEW_PER_COUNTRY_TYPE} of {len(pages['asn'])})"]
    compact += [markdown_link(e) for e in pages["asn"][:PREVIEW_PER_COUNTRY_TYPE]]
    compact += [f"- ... and {max(0, len(pages['asn']) - PREVIEW_PER_COUNTRY_TYPE)} more (see llms-full.txt)"] if len(pages["asn"]) > PREVIEW_PER_COUNTRY_TYPE else []
    compact += ["", f"## DNS Pages (preview: first {PREVIEW_PER_COUNTRY_TYPE} of {len(pages['dns'])})"]
    compact += [markdown_link(e) for e in pages["dns"][:PREVIEW_PER_COUNTRY_TYPE]]
    compact += [f"- ... and {max(0, len(pages['dns']) - PREVIEW_PER_COUNTRY_TYPE)} more (see llms-full.txt)"] if len(pages["dns"]) > PREVIEW_PER_COUNTRY_TYPE else []
    compact += ["", "## Blog Pages and Guides"]
    compact += [markdown_link(e) for e in pages["blog"][:30]]
    if len(pages["blog"]) > 30:
        compact.append(f"- ... and {len(pages['blog']) - 30} more (see llms-full.txt)")
    (ROOT / "llms.txt").write_text("\n".join(compact).rstrip() + "\n", encoding="utf-8")

    full = header + ["", "## Complete URL Inventory"]
    category_titles = [("Core Pages", pages["pages"]), ("ASN Pages", pages["asn"]),
                       ("DNS Pages", pages["dns"]), ("Blog Pages and Guides", pages["blog"])]
    for title, entries in category_titles:
        full += ["", f"### {title}"]
        full += [markdown_link(e) for e in entries]
    (ROOT / "llms-full.txt").write_text("\n".join(full).rstrip() + "\n", encoding="utf-8")


def main() -> None:
    pages = collect_pages()
    write_urlset("sitemap-pages.xml", pages["pages"], "0.6")
    write_urlset("sitemap-asn.xml", pages["asn"], "0.8")
    write_urlset("sitemap-dns.xml", pages["dns"], "0.8")
    write_urlset("sitemap-blog.xml", pages["blog"], "0.9")
    write_sitemap_index()
    write_llms(pages)

    print("Generated sitemap and LLM index files:")
    for filename in ("sitemap.xml", "sitemap-pages.xml", "sitemap-asn.xml",
                     "sitemap-dns.xml", "sitemap-blog.xml", "llms.txt", "llms-full.txt"):
        print(f"  {filename}")
    print("Counts: " + ", ".join(f"{name}={len(entries)}" for name, entries in pages.items()))


if __name__ == "__main__":
    main()
