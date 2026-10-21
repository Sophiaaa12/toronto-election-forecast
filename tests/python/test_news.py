# tests/python/test_news.py
#
# Tests for llm/news.py (daily news block) and the v2 daily prompt.
# No network access: feeds are inline XML and HTTP is injected.

import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.news import fetch_news, parse_feed, render_news_block, select_items  # noqa: E402
from llm.prompts import (  # noqa: E402
    SYSTEM_PROMPT,
    Candidate,
    DailyContext,
    Persona,
    build_messages,
    prompt_fingerprint,
)

NOW = datetime(2026, 10, 21, 11, 0, tzinfo=timezone.utc)


def rss(*items: tuple[str, str, str]) -> bytes:
    body = "".join(
        f"<item><title>{t}</title><description>{d}</description>"
        f"<pubDate>{p}</pubDate><link>https://example.com/{i}</link></item>"
        for i, (t, d, p) in enumerate(items)
    )
    return f"<rss><channel>{body}</channel></rss>".encode("utf-8")


RECENT = "Wed, 21 Oct 2026 06:00:00 -0400"
OLD = "Sat, 17 Oct 2026 06:00:00 -0400"


class TestParse(unittest.TestCase):
    def test_strips_html_and_entities(self):
        items = parse_feed("CBC", rss((
            "Chow &amp; Bradford debate",
            "&lt;img src='x.jpg'/&gt;&lt;p&gt;Candidates clash at city hall&lt;/p&gt;",
            RECENT,
        )))
        self.assertEqual(items[0].title, "Chow & Bradford debate")
        self.assertEqual(items[0].description, "Candidates clash at city hall")
        self.assertTrue(items[0].election_related)
        self.assertTrue(items[0].toronto_related)
        self.assertEqual(items[0].published_utc, "2026-10-21T10:00:00Z")

    def test_drops_foreign_wire_copy(self):
        items = parse_feed("CityNews", rss(
            ("Student alleges assault", "TUCSON, Ariz. (AP) — A sorority member...", RECENT),
            ("TTC fare news", "TORONTO (AP) — Fares rise", RECENT),
        ))
        self.assertEqual([i.title for i in items], ["TTC fare news"])

    def test_long_description_truncated(self):
        items = parse_feed("Star", rss(("Title", "word " * 100, RECENT)))
        self.assertLessEqual(len(items[0].description), 160)
        self.assertTrue(items[0].description.endswith("…"))


class TestSelect(unittest.TestCase):
    def test_priority_recency_and_dedup(self):
        by_source = {
            "A": parse_feed("A", rss(
                ("Raccoon rescued", "", RECENT),
                ("Oshawa mayoral race wide open", "", RECENT),
                ("Old Toronto mayor story", "", OLD),
            )),
            "B": parse_feed("B", rss(
                ("Chow leads in new poll", "Toronto mayor", RECENT),
                ("raccoon RESCUED", "", RECENT),
            )),
        }
        sel = select_items(by_source, NOW)
        titles = [i.title for i in sel]
        self.assertEqual(titles[0], "Chow leads in new poll")       # Toronto election first
        self.assertEqual(titles[1], "Oshawa mayoral race wide open")  # other election next
        self.assertNotIn("Old Toronto mayor story", titles)          # outside lookback
        self.assertEqual(sum(t.lower() == "raccoon rescued" for t in titles), 1)

    def test_caps(self):
        many = rss(*[(f"Story {i}", "", RECENT) for i in range(10)])
        by_source = {s: parse_feed(s, many) for s in ("A", "B", "C", "D")}
        sel = select_items(by_source, NOW, max_total=12, max_per_source=4)
        self.assertEqual(len(sel), 4)  # identical titles are de-duplicated across sources
        by_source = {s: parse_feed(s, rss(*[(f"{s} story {i}", "", RECENT) for i in range(10)]))
                     for s in ("A", "B", "C", "D")}
        sel = select_items(by_source, NOW, max_total=12, max_per_source=4)
        self.assertEqual(len(sel), 12)
        self.assertEqual(max(sum(i.source == s for i in sel) for s in "ABCD"), 3)

    def test_render(self):
        items = parse_feed("CBC", rss(("Headline", "Summary text", RECENT)))
        self.assertEqual(render_news_block(items), "- [CBC] Headline — Summary text")


class _Resp:
    def __init__(self, content: bytes):
        self.content = content

    def raise_for_status(self):
        pass


class TestFetch(unittest.TestCase):
    def test_failed_feed_recorded_and_usable_flag(self):
        good = rss(*[(f"Toronto story {i}", "", RECENT) for i in range(4)])

        def http_get(url, headers=None, timeout=None):
            if "bad" in url:
                raise requests.ConnectionError("boom")
            return _Resp(good.replace(b"Toronto story", url[-1:].encode() + b" story"))

        feeds = [("One", "https://x/1"), ("Two", "https://x/2"), ("Bad", "https://bad/3")]
        out = fetch_news("2026-10-21", feeds=feeds, http_get=http_get, now_utc=NOW)
        self.assertEqual(out["n_sources_ok"], 2)
        self.assertFalse(out["sources"][2]["ok"])
        self.assertIn("ConnectionError", out["sources"][2]["error"])
        self.assertEqual(len(out["items"]), 8)
        self.assertTrue(out["usable"])

        out = fetch_news("2026-10-21", feeds=feeds[2:], http_get=http_get, now_utc=NOW)
        self.assertFalse(out["usable"])


class TestDailyPrompt(unittest.TestCase):
    P = Persona("P000001", ward=1, age_group="20-29", education_group="High school or less")
    CANDS = [Candidate("MAYOR-009", "Olivia Chow"), Candidate("MAYOR-005", "Brad Bradford")]

    def test_v1_unchanged_without_context(self):
        msgs = build_messages(self.P, "mayor", self.CANDS)
        self.assertEqual(msgs[0]["content"], SYSTEM_PROMPT)

    def test_context_in_system_message(self):
        ctx = DailyContext("2026-10-21", "- [CBC] Chow leads")
        msgs = build_messages(self.P, "mayor", self.CANDS, ctx)
        system = msgs[0]["content"]
        self.assertIn("prompt version v2", system)
        self.assertIn("Today is 2026-10-21", system)
        self.assertIn("- [CBC] Chow leads", system)
        self.assertEqual(msgs[1], build_messages(self.P, "mayor", self.CANDS)[1])

    def test_news_changes_fingerprint(self):
        a = build_messages(self.P, "mayor", self.CANDS, DailyContext("2026-10-21", "- x"))
        b = build_messages(self.P, "mayor", self.CANDS, DailyContext("2026-10-22", "- x"))
        c = build_messages(self.P, "mayor", self.CANDS, DailyContext("2026-10-21", "- y"))
        fps = {prompt_fingerprint(m)["sha256"] for m in (a, b, c)}
        self.assertEqual(len(fps), 3)


if __name__ == "__main__":
    unittest.main()
