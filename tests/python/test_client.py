# tests/python/test_client.py
#
# Tests for llm/client.py: retry policy, backoff, permanent-vs-transient
# failure classification, and technical failure statuses.
#
# ALL HTTP IS MOCKED via an injected http_post callable. These tests
# never contact OpenRouter (or any network host).

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import requests  # noqa: E402

from llm.client import APIError, OpenRouterClient  # noqa: E402

MSGS = [
    {"role": "system", "content": "sys"},
    {"role": "user", "content": "user"},
]


class FakeResponse:
    """Minimal stand-in for requests.Response."""

    def __init__(self, status_code=200, body=None, text=None, headers=None):
        self.status_code = status_code
        self.headers = headers or {}
        if text is not None:
            self.text = text
        else:
            self.text = json.dumps(body) if body is not None else ""
        self._body = body

    def json(self):
        if self._body is None:
            raise ValueError("no body")
        return self._body


def ok_body(content='{"response_status": "undecided", "candidate_id": null}',
            usage=None):
    body = {
        "model": "provider/model-a",
        "model_version": "2026-09-01",
        "choices": [{"message": {"role": "assistant", "content": content}}],
    }
    if usage is not None:
        body["usage"] = usage
    return body


def make_client(seq, max_retries=3, **kw):
    """Client whose http_post pops scripted responses in order."""
    calls = []

    def http_post(url, headers=None, data=None, timeout=None):
        calls.append({"url": url, "headers": headers, "data": data, "timeout": timeout})
        item = seq[min(len(calls) - 1, len(seq) - 1)]
        if isinstance(item, Exception):
            raise item
        return item

    client = OpenRouterClient(
        api_key="sk-test-not-a-real-key",
        max_retries=max_retries,
        http_post=http_post,
        sleep=lambda s: None,   # no real sleeping in tests
        **kw,
    )
    return client, calls


class TestSuccess(unittest.TestCase):
    def test_single_success(self):
        client, calls = make_client([FakeResponse(body=ok_body(
            usage={"prompt_tokens": 120, "completion_tokens": 15, "cost": 0.00042}
        ))])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertTrue(r.ok)
        self.assertIn("undecided", r.text)
        self.assertEqual(r.usage["cost"], 0.00042)
        self.assertEqual(r.model_version_reported, "2026-09-01")
        self.assertEqual(r.attempts, 1)
        self.assertEqual(len(calls), 1)

    def test_request_payload_contains_generation_params(self):
        client, calls = make_client([FakeResponse(body=ok_body())])
        client.complete("provider/model-a", MSGS, 0.3, 128)
        sent = json.loads(calls[0]["data"])
        self.assertEqual(sent["temperature"], 0.3)
        self.assertEqual(sent["max_tokens"], 128)
        self.assertEqual(sent["model"], "provider/model-a")
        # Authorization header present but never echoed into results.
        self.assertTrue(calls[0]["headers"]["Authorization"].startswith("Bearer "))

    def test_missing_content_is_missing_status(self):
        body = {"choices": [{"message": {"content": ""}}], "usage": {}}
        client, calls = make_client([FakeResponse(body=body)])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertFalse(r.ok)
        self.assertEqual(r.failure_status, "missing")

    def test_no_choices_is_missing_status(self):
        client, _ = make_client([FakeResponse(body={"choices": []})])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.failure_status, "missing")


class TestRetries(unittest.TestCase):
    def test_429_then_success(self):
        client, calls = make_client([
            FakeResponse(status_code=429, text="slow down",
                         headers={"Retry-After": "2"}),
            FakeResponse(body=ok_body()),
        ])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertTrue(r.ok)
        self.assertEqual(r.attempts, 2)
        self.assertEqual(len(calls), 2)

    def test_429_exhausts_to_rate_limit(self):
        client, calls = make_client(
            [FakeResponse(status_code=429, text="slow down")] * 10, max_retries=2
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertFalse(r.ok)
        self.assertEqual(r.failure_status, "rate_limit")
        self.assertEqual(len(calls), 3)  # 1 initial + 2 retries

    def test_500_then_success(self):
        client, calls = make_client([
            FakeResponse(status_code=500, text="boom"),
            FakeResponse(status_code=503, text="boom"),
            FakeResponse(body=ok_body()),
        ])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertTrue(r.ok)
        self.assertEqual(r.attempts, 3)

    def test_timeout_then_success(self):
        client, _ = make_client([
            requests.Timeout("read timed out"),
            FakeResponse(body=ok_body()),
        ])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertTrue(r.ok)
        self.assertEqual(r.attempts, 2)

    def test_timeouts_exhaust_to_timeout_status(self):
        client, calls = make_client(
            [requests.Timeout("read timed out")] * 10, max_retries=3
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.failure_status, "timeout")
        self.assertEqual(len(calls), 4)

    def test_connection_error_to_api_error(self):
        client, _ = make_client(
            [requests.ConnectionError("refused")] * 10, max_retries=1
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.failure_status, "api_error")

    def test_retry_honours_retry_after(self):
        sleeps = []
        client, _ = make_client([
            FakeResponse(status_code=429, headers={"Retry-After": "7"}),
            FakeResponse(body=ok_body()),
        ])
        client._sleep = sleeps.append
        client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(sleeps, [7.0])


class TestPermanentFailures(unittest.TestCase):
    def test_400_not_retried(self):
        client, calls = make_client(
            [FakeResponse(status_code=400, text="bad request")] * 5, max_retries=5
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.failure_status, "api_error")
        self.assertEqual(r.http_status, 400)
        self.assertEqual(len(calls), 1)  # no retries for permanent errors

    def test_401_not_retried(self):
        client, calls = make_client(
            [FakeResponse(status_code=401, text="bad key")], max_retries=3
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.http_status, 401)
        self.assertEqual(len(calls), 1)

    def test_402_not_retried(self):
        client, calls = make_client(
            [FakeResponse(status_code=402, text="insufficient credits")], max_retries=3
        )
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertEqual(r.http_status, 402)
        self.assertEqual(len(calls), 1)

    def test_200_non_json_body(self):
        client, _ = make_client([FakeResponse(status_code=200, text="<html>oops</html>")])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertFalse(r.ok)
        self.assertEqual(r.failure_status, "invalid")
        self.assertEqual(r.attempts, 1)

    def test_client_requires_key(self):
        with self.assertRaises(APIError):
            OpenRouterClient(api_key=None)

    def test_api_key_never_in_result(self):
        client, _ = make_client([FakeResponse(body=ok_body())])
        r = client.complete("provider/model-a", MSGS, 0.7, 256)
        self.assertNotIn("sk-test", json.dumps(r.__dict__, default=str))


if __name__ == "__main__":
    unittest.main()
