from __future__ import annotations

import json
import unittest
from unittest import mock

from scripts import herdr_pr_review_watch as watch


def pr(number=11764, title="Clean Up AI TCA 1.26.0 Warnings", author="chandler", draft=False, requests=None):
    return {
        "number": number,
        "title": title,
        "url": f"https://github.com/doximity/iOS-Doximity/pull/{number}",
        "author": {"login": author},
        "isDraft": draft,
        "reviewRequests": requests if requests is not None else [{"login": "ronnierocha", "name": ""}],
    }


class ClassifyRequestedTests(unittest.TestCase):
    def test_direct_request(self):
        self.assertEqual(watch.classify_requested(pr(), "ronnierocha", {"ios_dialer"}), "direct")

    def test_team_request(self):
        request = pr(requests=[{"login": "", "name": "ios_dialer"}])
        self.assertEqual(watch.classify_requested(request, "ronnierocha", {"ios_dialer"}), "team")

    def test_unknown_request_defaults_to_team(self):
        request = pr(requests=[{"login": "", "name": "someoneelses"}])
        self.assertEqual(watch.classify_requested(request, "ronnierocha", {"ios_dialer"}), "team")


class ReviewScopeTests(unittest.TestCase):
    def test_exclusions(self):
        self.assertTrue(watch.is_excluded("Sources/Generated/file.g.swift"))
        self.assertTrue(watch.is_excluded("Tests/ThingTests.swift"))
        self.assertTrue(watch.is_excluded("Schema.graphql"))
        self.assertFalse(watch.is_excluded("Sources/Feature/View.swift"))

    def test_review_scope_counts_only_reviewed_files(self):
        payload = {
            "data": {"repository": {"pullRequest": {"files": {
                "totalCount": 4,
                "nodes": [
                    {"path": "A.swift", "additions": 10, "deletions": 2},
                    {"path": "B.g.swift", "additions": 900, "deletions": 800},
                    {"path": "CTests.swift", "additions": 50, "deletions": 5},
                    {"path": "D.swift", "additions": 7, "deletions": 0},
                ],
            }}}}
        }
        with mock.patch.object(watch, "run_json", return_value=payload):
            scope = watch.review_scope(11764)
        self.assertEqual(scope, {"files": 2, "total_files": 4, "additions": 17, "deletions": 2})


class JiraLinkTests(unittest.TestCase):
    def test_key_in_title(self):
        link = watch.jira_link(pr(title="IOSDOX-27215 Fix deep link"))
        self.assertEqual(link["issue_key"], "IOSDOX-27215")
        self.assertIn("browse/IOSDOX-27215", link["url"])

    def test_no_key(self):
        self.assertIsNone(watch.jira_link(pr(title="No key here")))


class ParseAssessmentTests(unittest.TestCase):
    def test_valid_line(self):
        out = "thinking...\nASSESSMENT_JSON: {\"rating\": 4, \"cr_estimate\": \"~1-2 hr\", \"summary\": \"Big TCA cleanup.\"}"
        self.assertEqual(
            watch.parse_assessment(out),
            {"rating": 4, "cr_estimate": "~1-2 hr", "summary": "Big TCA cleanup."},
        )

    def test_rejects_bad_rating(self):
        out = 'ASSESSMENT_JSON: {"rating": 9, "cr_estimate": "x", "summary": "y"}'
        self.assertIsNone(watch.parse_assessment(out))

    def test_missing_line(self):
        self.assertIsNone(watch.parse_assessment("no marker here"))

    def test_invalid_json(self):
        self.assertIsNone(watch.parse_assessment("ASSESSMENT_JSON: {not json"))


class ItemShapeTests(unittest.TestCase):
    def test_deterministic_summary(self):
        summary = watch.deterministic_summary(
            pr(author="chandler"), "chandler", "direct", {"additions": 1117, "deletions": 291, "files": 29}
        )
        self.assertIn("chandler asked for your review (direct)", summary)
        self.assertIn("+1117/−291 across 29 review files", summary)
        self.assertIn("PR #11764", summary)

    def test_item_id_is_stable(self):
        self.assertEqual(watch.item_id_for(11764), "pr-watch-doximity-ios-doximity-11764")


class CreateItemTests(unittest.TestCase):
    @mock.patch.object(watch, "active_work")
    def test_create_payload(self, active_work):
        active_work.return_value = {"ok": True, "data": {"id": "pr-watch-doximity-ios-doximity-11764"}}
        work_id = watch.create_item(pr(), "direct", {"files": 29, "total_files": 52, "additions": 1117, "deletions": 291})
        args = active_work.call_args[0]
        self.assertEqual(
            args,
            (
                "create",
                "--id", "pr-watch-doximity-ios-doximity-11764",
                "--kind", "task",
                "--title", "PR #11764 · Clean Up AI TCA 1.26.0 Warnings",
                "--summary", mock.ANY,
                "--workflow", "pr-review-watch",
                "--current-stage", "queued",
                "--next-action", "Pick a review path for PR #11764",
                "--metadata-json", mock.ANY,
            ),
        )
        metadata = json.loads(args[-1])
        self.assertEqual(metadata["pr"]["number"], 11764)
        self.assertEqual(metadata["requested_kind"], "direct")
        self.assertEqual(metadata["done_label"], "reviewed · complete")
        self.assertIsNone(metadata.get("jira"))
        self.assertEqual(work_id, "pr-watch-doximity-ios-doximity-11764")


class PassOnceTests(unittest.TestCase):
    @mock.patch.object(watch, "create_item")
    @mock.patch.object(watch, "board_item_ids")
    @mock.patch.object(watch, "fetch_queue")
    @mock.patch.object(watch, "gh_teams")
    @mock.patch.object(watch, "gh_me")
    def test_new_pr_creates_item_and_assesses(
        self, gh_me, gh_teams, fetch_queue, board_item_ids, create_item
    ):
        gh_me.return_value = "ronnierocha"
        gh_teams.return_value = {"ios_dialer"}
        fetch_queue.return_value = [pr()]
        board_item_ids.return_value = set()
        create_item.return_value = "pr-watch-doximity-ios-doximity-11764"
        with mock.patch.object(watch, "review_scope", return_value={"files": 1, "total_files": 1, "additions": 5, "deletions": 1}), \
             mock.patch.object(watch, "assess_pr", return_value={"rating": 2, "cr_estimate": "~20 min", "summary": "Small fix."}), \
             mock.patch.object(watch, "stage_content") as stage_content, \
             mock.patch.object(watch, "update_item") as update_item:
            counts = watch.pass_once()
        self.assertEqual(counts, {"queue": 1, "new": 1, "assessed": 1, "errors": 0})
        create_item.assert_called_once()
        stage_content.assert_called_once()
        update_item.assert_called_once()

    @mock.patch.object(watch, "board_item_ids")
    @mock.patch.object(watch, "fetch_queue")
    @mock.patch.object(watch, "gh_teams")
    @mock.patch.object(watch, "gh_me")
    def test_known_pr_is_skipped(self, gh_me, gh_teams, fetch_queue, board_item_ids):
        gh_me.return_value = "ronnierocha"
        gh_teams.return_value = set()
        fetch_queue.return_value = [pr()]
        board_item_ids.return_value = {"pr-watch-doximity-ios-doximity-11764"}
        with mock.patch.object(watch, "create_item") as create_item:
            counts = watch.pass_once()
        self.assertEqual(counts, {"queue": 1, "new": 0, "assessed": 0, "errors": 0})
        create_item.assert_not_called()

    @mock.patch.object(watch, "fetch_queue")
    def test_discovery_error_is_never_queue_clear(self, fetch_queue):
        fetch_queue.side_effect = watch.WatchError("gh exploded")
        with mock.patch.object(watch, "log") as log:
            counts = watch.pass_once()
        self.assertEqual(counts["errors"], 1)
        self.assertEqual(counts["new"], 0)
        log.assert_called_once()


if __name__ == "__main__":
    unittest.main()
