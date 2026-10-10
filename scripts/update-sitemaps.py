#!/usr/bin/env python3
"""Refresh search-engine sitemaps and AI discovery files in the site root.
Search engines (XML, sitemap protocol):
  sitemap.xml           — index of child sitemaps
  sitemap-pages.xml     — core / hub pages
  sitemap-asn.xml       — country ASN pages
  sitemap-dns.xml       — country DNS pages
  sitemap-blog.xml      — blog posts and guides
AI crawlers (llmstxt.org, Markdown):
  llms.txt              — short index
  llms-full.txt         — full URL inventory
Does not mix the two: XML files never list llms.txt; llms files never replace sitemaps.
"""
from __future__ import annotations
import json
import re
import sys
from datetime import date
from pathlib import Path
from xml.etree import ElementTree as ET
ROOT = Path(__file__).resolve().parent.parent
BASE_URL = "https://www.aleiwa.com"
TODAY = str(date.today())
NAMESERVER_SKIP = {"dnsip", "dnsview", "dnsinfo", "dnsip_moban"}
ASN_SKIP = {"asn"}
LLMS_PREVIEW = 30
CORE_PAGES = [
    ("/", "index.html", "1.0", "weekly"),
    ("/dns.html", "dns.html", "0.9", "weekly"),
    ("/topisps.html", "topisps.html", "0.9", "weekly"),
    ("/about.html", "about.html", "0.6", "monthly"),
    ("/privacy.html", "privacy.html", "0.4", "yearly"),
]
OTHER_PAGES = [
    ("/methodology.html", "methodology.html", "0.7", "monthly"),
    ("/looking-glass.html", "looking-glass.html", "0.6", "monthly"),
    ("/routeviews.html", "routeviews.html", "0.6", "monthly"),
    ("/blog/index.html", "blog/index.html", "0.8", "weekly"),
    ("/blog/bloglist.html", "blog/bloglist.html", "0.8", "weekly"),
]
BLOG_GUIDES = [
    "blog/choosing-dns-server.html",
    "blog/bgp-routing-internet-infrastructure.html",
    "blog/what-is-ldns.html",
]
def load_json(path: Path):
    if not path.exists():
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)
def lastmod_for(path: Path, updated_data: dict, code: str | None = None) -> str:
    if code and code in updated_data:
        return updated_data[code]
    try:
        return date.fromtimestamp(path.stat().st_mtime).isoformat()
    except OSError:
        return TODAY
def page_title(path: Path, fallback: str) -> str:
    if not path.exists():
        return fallback
    html = path.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"<title>(.*?)</title>", html, re.I | re.S)
    if m:
        title = re.sub(r"<[^>]+>", "", m.group(1))
        return re.sub(r"\s+", " ", title).strip() or fallback
    m = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.I | re.S)
    if m:
        title = re.sub(r"<[^>]+>", "", m.group(1))
        return re.sub(r"\s+", " ", title).strip() or fallback
    return fallback
def write_urlset(path: Path, urls: list[tuple[str, str, str, str]]) -> None:
    urlset = ET.Element("urlset", xmlns="http://www.sitemaps.org/schemas/sitemap/0.9")
    for loc, lastmod, changefreq, priority in urls:
        url_el = ET.SubElement(urlset, "url")
        ET.SubElement(url_el, "loc").text = loc
        ET.SubElement(url_el, "lastmod").text = lastmod
        ET.SubElement(url_el, "changefreq").text = changefreq
        ET.SubElement(url_el, "priority").text = priority
    tree = ET.ElementTree(urlset)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)
def write_index(path: Path, sitemaps: list[tuple[str, str]]) -> None:
    index = ET.Element(
        "sitemapindex", xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
    )
    for loc, lastmod in sitemaps:
        sm = ET.SubElement(index, "sitemap")
        ET.SubElement(sm, "loc").text = loc
        ET.SubElement(sm, "lastmod").text = lastmod
    tree = ET.ElementTree(index)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)
def md_item(title: str, url: str, description: str | None = None) -> str:
    desc = description or title
    return f"- [{title}]({url}): {desc}"
def write_llms(
    path: Path,
    *,
    full: bool,
    core: list[tuple[str, str]],
    other: list[tuple[str, str]],
    asn: list[tuple[str, str]],
    dns: list[tuple[str, str]],
    blog: list[tuple[str, str]],
) -> None:
    total = len(core) + len(other) + len(asn) + len(dns) + len(blog)
    def section(name: str, items: list[tuple[str, str]], preview: int | None) -> str:
        count = f" ({len(items)})" if full else ""
        lines = [f"## {name}{count}"]
        shown = items if full or preview is None else items[:preview]
        lines.extend(md_item(title, url) for title, url in shown)
        remaining = len(items) - len(shown)
        if remaining > 0:
            lines.append(f"- ... and {remaining} more (see llms-full.txt)")
        if not items:
            lines.append("- (none)")
        return "\n".join(lines)
    header = [
        "# Title",
        "> Aleiwa LLM index for structured discovery of DNS, ASN, and blog pages.",
        "",
        "This file provides a machine-readable entrypoint for LLMs.",
        "Search-engine sitemaps are separate XML files — do not treat this as a sitemap.",
        f"Sitemap index: {BASE_URL}/sitemap.xml",
        "",
        "## Docs",
        f"- [Canonical site]({BASE_URL}/): Reference link",
        f"- [Sitemap index]({BASE_URL}/sitemap.xml): Search engines",
        f"- [Pages sitemap]({BASE_URL}/sitemap-pages.xml): Search engines",
        f"- [ASN sitemap]({BASE_URL}/sitemap-asn.xml): Search engines",
        f"- [DNS sitemap]({BASE_URL}/sitemap-dns.xml): Search engines",
        f"- [Blog sitemap]({BASE_URL}/sitemap-blog.xml): Search engines",
        f"- Full URL inventory: {BASE_URL}/llms-full.txt",
        f"- Generated date: {TODAY}",
        f"- Total indexed URLs: {total}",
        "## Policies",
        f"- [Privacy policy]({BASE_URL}/privacy.html): Reference link",
        f"- [About page]({BASE_URL}/about.html): Reference link",
        "",
    ]
    body = [
        section("Core Pages", core, None),
        section("ASN Pages", asn, None if full else LLMS_PREVIEW),
        section("DNS Pages", dns, None if full else LLMS_PREVIEW),
        section("Blog Pages", blog, None),
        section("Other Pages", other, None),
        "",
    ]
    path.write_text("\n".join(header + body), encoding="utf-8")
def collect_country_pages(
    folder: Path, skip: set[str], country_map: dict, title_fmt: str
) -> list[tuple[Path, str, str]]:
    rows = []
    for f in sorted(folder.glob("*.html")):
        if f.stem in skip:
            continue
        country = country_map.get(f.stem, f.stem.upper())
        fallback = title_fmt.format(country=country)
        title = page_title(f, fallback)
        rows.append((f, title, f.stem))
    return rows
