# tests/python/test_schema.py
#
# Tests for llm/schema.py: strict JSON response validation.
# No network access; pure functions only.

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from llm.schema import (  # noqa: E402
    ALL_STATUSES,
    FAILURE_STATUSES,
    MODEL_STATUSES,
    failure,
    parse_model_json,
    validate_response,
)

ALLOWED = {"MAYOR-001", "MAYOR-002", "MAYOR-003"}


class TestModelAnswers(unittest.TestCase):
    def test_valid_choice(self):
        v = validate_response(
            '{"response_status": "valid_choice", "candidate_id": "MAYOR-002"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "valid_choice")
        self.assertEqual(v.candidate_id, "MAYOR-002")

    def test_undecided_null_candidate(self):
        v = validate_response(
            '{"response_status": "undecided", "candidate_id": null}', ALLOWED
        )
        self.assertEqual(v.response_status, "undecided")
        self.assertIsNone(v.candidate_id)

    def test_not_voting_null_candidate(self):
        v = validate_response(
            '{"response_status": "not_voting", "candidate_id": null}', ALLOWED
        )
        self.assertEqual(v.response_status, "not_voting")
        self.assertIsNone(v.candidate_id)

    def test_code_fence_tolerated(self):
        v = validate_response(
            '```json\n{"response_status": "undecided", "candidate_id": null}\n```',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "undecided")

    def test_surrounding_prose_tolerated(self):
        v = validate_response(
            'Here is my answer: {"response_status": "not_voting", '
            '"candidate_id": null} hope that helps!',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "not_voting")


class TestInvalidCandidateIDs(unittest.TestCase):
    def test_unknown_candidate_id(self):
        v = validate_response(
            '{"response_status": "valid_choice", "candidate_id": "MAYOR-999"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "invalid")
        self.assertIn("not in this race", v.detail)

    def test_candidate_from_other_race(self):
        # W01-C01 is a ward candidate; not valid in the mayor race.
        v = validate_response(
            '{"response_status": "valid_choice", "candidate_id": "W01-C01"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "invalid")

    def test_valid_choice_with_null(self):
        v = validate_response(
            '{"response_status": "valid_choice", "candidate_id": null}', ALLOWED
        )
        self.assertEqual(v.response_status, "invalid")

    def test_undecided_with_candidate(self):
        v = validate_response(
            '{"response_status": "undecided", "candidate_id": "MAYOR-001"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "invalid")

    def test_not_voting_with_candidate(self):
        v = validate_response(
            '{"response_status": "not_voting", "candidate_id": "MAYOR-001"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "invalid")


class TestMalformed(unittest.TestCase):
    def test_malformed_json(self):
        v = validate_response('{"response_status": "undecided", ', ALLOWED)
        self.assertEqual(v.response_status, "invalid")

    def test_not_json_at_all(self):
        v = validate_response("I pick the first candidate!", ALLOWED)
        self.assertEqual(v.response_status, "invalid")

    def test_empty(self):
        v = validate_response("", ALLOWED)
        self.assertEqual(v.response_status, "invalid")

    def test_missing_response_status(self):
        v = validate_response('{"candidate_id": null}', ALLOWED)
        self.assertEqual(v.response_status, "invalid")
        self.assertIn("response_status", v.detail)

    def test_missing_candidate_id(self):
        v = validate_response('{"response_status": "undecided"}', ALLOWED)
        self.assertEqual(v.response_status, "invalid")
        self.assertIn("candidate_id", v.detail)

    def test_extra_fields_rejected(self):
        v = validate_response(
            '{"response_status": "undecided", "candidate_id": null, '
            '"reasoning": "because"}',
            ALLOWED,
        )
        self.assertEqual(v.response_status, "invalid")

    def test_unknown_status(self):
        v = validate_response(
            '{"response_status": "abstain", "candidate_id": null}', ALLOWED
        )
        self.assertEqual(v.response_status, "invalid")


class TestStatusVocabularies(unittest.TestCase):
    def test_model_and_failure_disjoint(self):
        self.assertEqual(
            set(MODEL_STATUSES) & set(FAILURE_STATUSES), set()
        )
        self.assertEqual(set(ALL_STATUSES), set(MODEL_STATUSES) | set(FAILURE_STATUSES))

    def test_failure_helper_rejects_model_status(self):
        with self.assertRaises(ValueError):
            failure("valid_choice", "nope")

    def test_parse_object_required(self):
        payload, err = parse_model_json("[1, 2, 3]")
        self.assertIsNone(payload)
        self.assertIsNotNone(err)


if __name__ == "__main__":
    unittest.main()
