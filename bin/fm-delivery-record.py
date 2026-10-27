#!/usr/bin/env python3
"""Produce and consume Firstmate conditional delivery declarations.

emit --head SHA prints the internal-only direct-PR body record after semantic
intake classification; it is not pipeline provenance or authentication.
check-live reads the PR number from GITHUB_EVENT_PATH, fetches its current body
and head through the GitHub API, and writes direct=true/false to GITHUB_OUTPUT.
The workflow falls through to the existing no-mistakes action unless direct=true.
A failed live lookup fails the job closed; cached event bodies are never judged.

This record deliberately has the existing pipeline body's structural trust level:
a contributor can lie about classification just as they can forge that body's
pipeline assertion. Semantic intake must treat supervision behavior as product,
not infer internal-only from a path, branch, author or repository name.
One complete v1 record with exactly these fields is accepted for the current
head only. Missing, duplicate, unknown-version, malformed, stale, or non-internal
records require the full no-mistakes verifier. Reclassification removes
the record; head changes require regenerating it. Normal CI still applies.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PREFIX = "<!-- firstmate-delivery:"
VERSION = PREFIX + "v1 "
CLOSING = " -->"
FIELDS = {"policy", "mode", "surface", "head_sha"}
POLICY = "no-mistakes-prod-only"


def sha_valid(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def internal_direct(pr):
    """Judge only normalized live body/head facts, never actor identity."""
    if not isinstance(pr, dict):
        return False
    body = pr.get("body")
    head = pr.get("head")
    if not isinstance(body, str) or not isinstance(head, dict):
        return False
    sha = head.get("sha")
    if not sha_valid(sha) or body.count(PREFIX) != 1:
        return False
    start = body.find(VERSION)
    if start < 0:
        return False
    start += len(VERSION)
    end = body.find(CLOSING, start)
    if end < 0:
        return False
    try:
        record = json.loads(body[start:end], object_pairs_hook=unique_object)
    except (ValueError, TypeError):
        return False
    return (
        isinstance(record, dict)
        and set(record) == FIELDS
        and record.get("policy") == POLICY
        and record.get("mode") == "direct-PR"
        and record.get("surface") == "internal-only"
        and record.get("head_sha") == sha
    )


def live_pr():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    number = event["pull_request"]["number"]
    repo = os.environ["GITHUB_REPOSITORY"]
    if type(number) is not int or number <= 0 or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("invalid PR identity")
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    request = urllib.request.Request(
        f"{api}/repos/{repo}/pulls/{number}",
        headers={
            "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise ValueError("live PR lookup did not return 200")
        pr = json.load(response)
    if not isinstance(pr, dict) or pr.get("number") != number:
        raise ValueError("live PR identity mismatch")
    if not isinstance(pr.get("head"), dict) or not sha_valid(pr["head"].get("sha")):
        raise ValueError("invalid live head")
    if pr.get("body") is not None and not isinstance(pr.get("body"), str):
        raise ValueError("invalid live body")
    return pr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    emit = commands.add_parser("emit", help="serialize an internal-only direct-PR declaration for a committed head")
    emit.add_argument("--head", required=True)
    commands.add_parser("check-live", help="judge live GitHub PR body/head and emit workflow output")
    args = parser.parse_args()
    try:
        if args.command == "emit":
            if not sha_valid(args.head):
                raise ValueError("--head must be a full lowercase Git commit SHA")
            record = dict(policy=POLICY, mode="direct-PR", surface="internal-only", head_sha=args.head)
            print(VERSION + json.dumps(record, separators=(",", ":")) + CLOSING)
            return 0
        direct = internal_direct(live_pr())
        print(json.dumps({"direct": direct, "requires_no_mistakes": not direct}))
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("direct=" + str(direct).lower() + "\n")
        return 0
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        print("::error::Could not evaluate delivery declaration from current PR facts.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
