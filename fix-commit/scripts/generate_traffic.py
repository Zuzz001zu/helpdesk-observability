#!/usr/bin/env python3
"""Send realistic traffic to the helpdesk API so that the dashboards have something to show.

Mostly normal use (create, list, read, move tickets through the workflow), plus the
usual mistakes: unknown ticket ids (404), forbidden status changes (409) and invalid
payloads (422). Standard library only, so it runs anywhere Python 3.10+ is installed.
"""

from __future__ import annotations

import argparse
import json
import random
import time
import urllib.error
import urllib.request
from collections import Counter

PRIORITIES = ["low", "medium", "high", "critical"]
SUBJECTS = [
    "Outlook keeps asking for password",
    "VPN disconnects every hour",
    "Printer on 3rd floor offline",
    "New laptop for an intern",
    "Access to the shared drive",
    "Teams camera not detected",
    "Password reset for SAP",
]


class Client:
    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.statuses: Counter[int | str] = Counter()

    def call(self, method: str, path: str, body: dict | None = None) -> dict | None:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        request.add_header("X-API-Key", self.api_key)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                self.statuses[response.status] += 1
                payload = response.read()
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            self.statuses[error.code] += 1
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            # the API restarting or not reachable: count it and keep going
            self.statuses["no answer"] += 1
        return None

    def wait_until_ready(self, timeout: float) -> None:
        """The container can be "running" a few seconds before uvicorn accepts connections."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(self.base_url + "/health", timeout=2):
                    return
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                time.sleep(1)
        raise SystemExit(f"{self.base_url} did not answer within {timeout:.0f}s")


def run(client: Client, duration: float, rate: float) -> None:
    ids: list[int] = []
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        action = random.choices(
            ["create", "list", "read", "move", "comment", "stats", "missing", "conflict", "invalid"],
            weights=[20, 30, 20, 10, 5, 5, 4, 4, 2],
        )[0]

        if action == "create" or not ids:
            ticket = client.call("POST", "/tickets", {
                "title": random.choice(SUBJECTS),
                "requester_email": f"user{random.randint(1, 300)}@example.org",
                "priority": random.choice(PRIORITIES),
            })
            if ticket:
                ids.append(ticket["id"])
        elif action == "list":
            client.call("GET", f"/tickets?status=open&priority={random.choice(PRIORITIES)}&size=20")
        elif action == "read":
            client.call("GET", f"/tickets/{random.choice(ids)}")
        elif action == "move":
            client.call("PATCH", f"/tickets/{random.choice(ids)}",
                        {"status": random.choice(["in_progress", "resolved"])})
        elif action == "comment":
            client.call("POST", f"/tickets/{random.choice(ids)}/comments",
                        {"author": "support", "body": "Looking into it", "internal": True})
        elif action == "stats":
            client.call("GET", "/stats")
        elif action == "missing":
            client.call("GET", f"/tickets/{random.randint(900_000, 999_999)}")
        elif action == "conflict":
            ticket_id = random.choice(ids)
            client.call("PATCH", f"/tickets/{ticket_id}", {"status": "resolved"})
            client.call("PATCH", f"/tickets/{ticket_id}", {"status": "closed"})
            client.call("PATCH", f"/tickets/{ticket_id}", {"status": "in_progress"})  # closed is final: 409
        elif action == "invalid":
            client.call("POST", "/tickets", {"title": "x", "requester_email": "not-an-email"})

        time.sleep(random.expovariate(rate))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--api-key", default="change-me")
    parser.add_argument("--duration", type=float, default=60, help="seconds")
    parser.add_argument("--rate", type=float, default=5, help="average requests per second")
    args = parser.parse_args()

    client = Client(args.url, args.api_key)
    client.wait_until_ready(timeout=120)
    run(client, args.duration, args.rate)
    summary = ", ".join(f"{code}: {n}" for code, n in sorted(client.statuses.items(), key=str))
    print(f"sent {sum(client.statuses.values())} requests ({summary})")


if __name__ == "__main__":
    main()
