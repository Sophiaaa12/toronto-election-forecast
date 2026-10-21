# llm/news.py
#
# Daily Toronto news context for the daily silicon-sampling tracker.
#
# Each day the tracker downloads the RSS feeds of several Toronto local
# news outlets, keeps recent items, and renders them into one plain-text
# "news block" that is shown identically to every persona (the same
# design as the Synthetic Voter Project, which uses newspaper front
# pages). Headlines and RSS descriptions are used VERBATIM (HTML
# stripped, truncated): no LLM summarisation step, so the context is
# auditable and costs nothing.
#
# Usage:
#   python3 -m llm.news --date 2026-10-21 --out processed/daily/news/2026-10-21.json
#
# Output JSON (committed, one file per poll date):
#   poll_date, fetched_at_utc, sources (per-feed status), items (kept
#   headlines), news_block (exact text placed in the prompt).

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Callable, Optional

import requests

FEEDS: list[tuple[str, str]] = [
    ("CBC Toronto", "https://www.cbc.ca/webfeed/rss/rss-canada-toronto"),
    ("Toronto Star", "https://www.thestar.com/search/?f=rss&t=article&c=news/gta&l=50&s=start_time&sd=desc"),
    ("CityNews Toronto", "https://toronto.citynews.ca/feed/"),
    ("Global News Toronto", "https://globalnews.ca/toronto/feed/"),
    ("Toronto Sun", "https://torontosun.com/category/news/local-news/feed"),
]

# Items mentioning these terms are listed first so the municipal
# campaign is not crowded out by unrelated local stories.
ELECTION_TERMS = re.compile(
    r"\b(elections?|mayor|mayoral|councillors?|council|wards?|ballots?|"
    r"polls?|polling|votes?|voters?|voting|campaign(s|ing)?|debates?|"
    r"city hall|candidates?)\b",
    re.IGNORECASE,
)
TORONTO_TERMS = re.compile(r"\b(toronto|chow|bradford)\b", re.IGNORECASE)

# Syndicated wire copy with a non-Toronto dateline ("TUCSON, Ariz. (AP) —").
WIRE_DATELINE = re.compile(r"^([A-Z][A-Za-z .,'-]+)\((AP|Reuters|AFP)\)")

MAX_ITEMS_TOTAL = 12
MAX_ITEMS_PER_SOURCE = 4
MAX_DESCRIPTION_CHARS = 160
LOOKBACK_HOURS = 36
MIN_SOURCES_OK = 2
MIN_ITEMS = 5

# CBC drops connections from non-browser user agents.
USER_AGENT = "Mozilla/5.0"


@dataclass(frozen=True)
class NewsItem:
    source: str
    title: str
    description: str
    published_utc: Optional[str]
    link: Optional[str]
    election_related: bool
    toronto_related: bool


def _clean(text: Optional[str]) -> str:
    if not text:
        return ""
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def _truncate(text: str, n: int) -> str:
    if len(text) <= n:
        return text
    cut = text[: n - 1].rsplit(" ", 1)[0]
    return cut.rstrip(",;:.") + "…"


def _parse_date(raw: Optional[str]) -> Optional[datetime]:
    if not raw:
        return None
    try:
        dt = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_feed(source: str, xml_bytes: bytes) -> list[NewsItem]:
    """Parse one RSS 2.0 document into NewsItems (feed order kept)."""
    root = ET.fromstring(xml_bytes)
    items: list[NewsItem] = []
    for it in root.iter("item"):
        title = _clean(it.findtext("title"))
        if not title:
            continue
        desc = _clean(it.findtext("description"))
        wire = WIRE_DATELINE.match(desc)
        if wire and "TORONTO" not in wire.group(1).upper():
            continue
        desc = _truncate(desc, MAX_DESCRIPTION_CHARS)
        if desc.lower().startswith(title.lower()):
            desc = ""
        dt = _parse_date(it.findtext("pubDate"))
        items.append(
            NewsItem(
                source=source,
                title=title,
                description=desc,
                published_utc=dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None,
                link=(it.findtext("link") or "").strip() or None,
                election_related=bool(ELECTION_TERMS.search(f"{title} {desc}")),
                toronto_related=bool(TORONTO_TERMS.search(f"{title} {desc}")),
            )
        )
    return items


def _priority(item: NewsItem) -> int:
    """0 = Toronto election story, 1 = other election story, 2 = other."""
    if item.election_related:
        return 0 if item.toronto_related else 1
    return 2


def select_items(
    items_by_source: dict[str, list[NewsItem]],
    now_utc: datetime,
    lookback_hours: int = LOOKBACK_HOURS,
    max_total: int = MAX_ITEMS_TOTAL,
    max_per_source: int = MAX_ITEMS_PER_SOURCE,
) -> list[NewsItem]:
    """Recent, de-duplicated items. Toronto election stories come first,
    then other election stories, then everything else; within each tier
    sources are interleaved so no single outlet dominates."""
    cutoff = now_utc - timedelta(hours=lookback_hours)
    seen: set[str] = set()
    ranked: list[tuple[int, int, NewsItem]] = []
    for items in items_by_source.values():
        kept = []
        for it in items:
            key = re.sub(r"\W+", " ", it.title.lower()).strip()
            if key in seen:
                continue
            if it.published_utc:
                dt = datetime.strptime(it.published_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                if dt < cutoff or dt > now_utc + timedelta(hours=1):
                    continue
            seen.add(key)
            kept.append(it)
        kept.sort(key=_priority)  # stable: feed order within a tier
        for idx, it in enumerate(kept[:max_per_source]):
            ranked.append((_priority(it), idx, it))
    ranked.sort(key=lambda t: (t[0], t[1]))
    return [it for _, _, it in ranked[:max_total]]


def render_news_block(items: list[NewsItem]) -> str:
    lines = []
    for it in items:
        line = f"- [{it.source}] {it.title}"
        if it.description:
            line += f" — {it.description}"
        lines.append(line)
    return "\n".join(lines)


def fetch_news(
    poll_date: str,
    feeds: list[tuple[str, str]] = FEEDS,
    http_get: Callable[..., requests.Response] = requests.get,
    now_utc: Optional[datetime] = None,
) -> dict:
    now_utc = now_utc or datetime.now(timezone.utc)
    sources = []
    items_by_source: dict[str, list[NewsItem]] = {}
    for name, url in feeds:
        status = {"source": name, "url": url, "ok": False, "n_items": 0, "error": None}
        try:
            resp = http_get(url, headers={"User-Agent": USER_AGENT}, timeout=20)
            resp.raise_for_status()
            parsed = parse_feed(name, resp.content)
            items_by_source[name] = parsed
            status.update(ok=True, n_items=len(parsed))
        except (requests.RequestException, ET.ParseError) as exc:
            status["error"] = f"{type(exc).__name__}: {exc}"[:300]
        sources.append(status)

    items = select_items(items_by_source, now_utc)
    n_ok = sum(s["ok"] for s in sources)
    return {
        "poll_date": poll_date,
        "fetched_at_utc": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lookback_hours": LOOKBACK_HOURS,
        "sources": sources,
        "n_sources_ok": n_ok,
        "items": [asdict(i) for i in items],
        "news_block": render_news_block(items),
        "usable": n_ok >= MIN_SOURCES_OK and len(items) >= MIN_ITEMS,
    }


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python3 -m llm.news",
                                description="Fetch the daily Toronto news block")
    p.add_argument("--date", required=True, help="poll date (YYYY-MM-DD, Toronto time)")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args(argv)

    result = fetch_news(args.date)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"news: {result['n_sources_ok']}/{len(result['sources'])} feeds ok, "
          f"{len(result['items'])} items kept -> {args.out}")
    if not result["usable"]:
        print(f"news block not usable (need >= {MIN_SOURCES_OK} feeds and "
              f">= {MIN_ITEMS} items); skipping today's poll", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
