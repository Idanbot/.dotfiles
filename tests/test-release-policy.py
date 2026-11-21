#!/usr/bin/env python3
"""Offline unit tests for shared stable-release selection."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from dotfiles import releases


class ReleasePolicyTests(unittest.TestCase):
    def test_advisory_distinguishes_java_feature_lines(self):
        versions = ["27.0.1+1", "25.0.5+8", "26.0.2+1", "28.0.0-ea", "25.0.5+11"]
        self.assertEqual(
            releases.candidate_options(versions, "25.0.4.1+1", "major"),
            [
                {"version": "25.0.5+11", "labels": ["latest-compatible"]},
                {
                    "version": "27.0.1+1",
                    "labels": ["latest-stable", "outside compatibility policy"],
                },
            ],
        )

    def test_advisory_deduplicates_an_update_with_both_labels(self):
        self.assertEqual(
            releases.candidate_options(["3.14.10", "3.14.10", "3.14.9"], "3.14.9", "minor"),
            [{"version": "3.14.10", "labels": ["latest-compatible", "latest-stable"]}],
        )

    def test_advisory_reports_outside_line_even_if_no_compatible_update(self):
        self.assertEqual(
            releases.candidate_options(["3.15.0", "3.14.9"], "3.14.9", "minor"),
            [{"version": "3.15.0", "labels": ["latest-stable", "outside compatibility policy"]}],
        )
        self.assertEqual(releases.candidate_options(["3.15.0rc1", "3.14.8"], "3.14.9"), [])

    def test_explicit_override_must_be_a_known_stable_release(self):
        versions = ["3.14.10", "3.15.0", "3.16.0rc1"]
        self.assertEqual(
            releases.latest_compatible(versions, "3.14.9", "minor", requested="3.15.0"),
            "3.15.0",
        )
        for requested in ("3.16.0rc1", "3.15.1"):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                releases.latest_compatible(versions, "3.14.9", "minor", requested=requested)

    def test_npm_latest_tag_and_node_engine_bound_candidates(self):
        data = {
            "dist-tags": {"latest": "12.0.0"},
            "versions": {
                "11.4.0": {"engines": {"node": "^24.0.0"}},
                "12.0.0": {"engines": {"node": ">=26.0.0"}},
                "12.1.0": {},
                "12.0.0-rc.1": {},
            },
        }
        for node, expected in (("24.3.0", ["11.4.0"]), ("26.1.0", ["12.0.0"])):
            with self.subTest(node=node):
                self.assertEqual(releases.npm_versions(data, node), expected)
        data["dist-tags"]["latest"] = "12.0.0-rc.1"
        with self.assertRaises(ValueError):
            releases.npm_versions(data)

    def test_pypi_requires_a_non_yanked_distribution(self):
        data = {"releases": {
            "1.1.0": [{"yanked": True}],
            "1.2.0": [],
            "1.3.0rc1": [{"yanked": False}],
            "1.3.0": [{"yanked": True}, {"yanked": False}],
        }}
        self.assertEqual(releases.pypi_versions(data), ["1.3.0"])


if __name__ == "__main__":
    unittest.main()
