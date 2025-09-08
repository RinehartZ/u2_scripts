#!/usr/bin/env python3

import argparse
import os
import re
import sys
import time
import uuid
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

import requests
import yaml


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Add torrent/magnet to qBittorrent with category and upload limit matched by tracker host."
    )
    parser.add_argument(
        "source",
        help="Path to .torrent file or a magnet URI",
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("QBT_HOST", "http://localhost:8080"),
        help="qBittorrent WebUI base URL (default: %(default)s or env QBT_HOST)",
    )
    parser.add_argument(
        "--username",
        default=os.environ.get("QBT_USERNAME"),
        help="WebUI username (default: env QBT_USERNAME)",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("QBT_PASSWORD"),
        help="WebUI password (default: env QBT_PASSWORD)",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("QBT_RULES_FILE", os.path.join(os.path.dirname(__file__), "rules.yaml")),
        help="Path to rules YAML (default: %(default)s or env QBT_RULES_FILE)",
    )
    parser.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS certificate verification",
    )
    parser.add_argument(
        "--no-unpause",
        action="store_true",
        help="Do not auto-resume after applying rules (torrent stays paused)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="Seconds to wait for the torrent to appear after add (default: %(default)s)",
    )
    return parser.parse_args()


def qb_login(session: requests.Session, base_url: str, username: Optional[str], password: Optional[str]) -> None:
    if not username or not password:
        print("Error: Missing username/password. Provide --username/--password or env QBT_USERNAME/QBT_PASSWORD.", file=sys.stderr)
        sys.exit(2)
    resp = session.post(f"{base_url}/api/v2/auth/login", data={"username": username, "password": password})
    if resp.status_code != 200 or resp.text != "Ok.":
        print(f"Error: Login failed (status {resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)


def qb_add_source(session: requests.Session, base_url: str, source: str, tag: str, paused: bool = True) -> None:
    if source.startswith("magnet:?"):
        data = {
            "paused": "true" if paused else "false",
            "tags": tag,
            "urls": source,
        }
        resp = session.post(f"{base_url}/api/v2/torrents/add", data=data)
    else:
        if not os.path.isfile(source):
            print(f"Error: File not found: {source}", file=sys.stderr)
            sys.exit(2)
        with open(source, "rb") as f:
            files = {"torrents": (os.path.basename(source), f, "application/x-bittorrent")}
            data = {
                "paused": "true" if paused else "false",
                "tags": tag,
            }
            resp = session.post(f"{base_url}/api/v2/torrents/add", data=data, files=files)
    if resp.status_code != 200:
        print(f"Error: Failed to add torrent (status {resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)


def qb_find_torrents_by_tag(session: requests.Session, base_url: str, tag: str) -> List[Dict]:
    resp = session.get(f"{base_url}/api/v2/torrents/info", params={"tag": tag})
    if resp.status_code != 200:
        raise RuntimeError(f"Failed to query torrents by tag: {resp.status_code} {resp.text}")
    return resp.json()


def qb_get_trackers(session: requests.Session, base_url: str, torrent_hash: str) -> List[Dict]:
    resp = session.get(f"{base_url}/api/v2/torrents/trackers", params={"hash": torrent_hash})
    if resp.status_code != 200:
        raise RuntimeError(f"Failed to fetch trackers: {resp.status_code} {resp.text}")
    return resp.json()


def extract_hostnames_from_trackers(trackers: List[Dict]) -> List[str]:
    hosts: List[str] = []
    for tr in trackers:
        url = tr.get("url", "")
        if not url:
            continue
        try:
            parsed = urlparse(url)
            if parsed.hostname:
                hosts.append(parsed.hostname)
        except Exception:
            continue
    # Ensure unique order-preserving
    seen = set()
    unique_hosts = []
    for h in hosts:
        if h not in seen:
            seen.add(h)
            unique_hosts.append(h)
    return unique_hosts


def load_rules(path: str) -> Dict:
    if not os.path.isfile(path):
        print(f"Error: Rules file not found: {path}", file=sys.stderr)
        sys.exit(2)
    with open(path, "r", encoding="utf-8") as f:
        try:
            data = yaml.safe_load(f) or {}
        except yaml.YAMLError as e:
            print(f"Error: Failed to parse YAML rules: {e}", file=sys.stderr)
            sys.exit(2)
    data.setdefault("defaults", {})
    data.setdefault("rules", [])
    return data


def match_rules(hosts: List[str], rules_cfg: Dict) -> Tuple[Optional[str], Optional[int]]:
    category: Optional[str] = None
    up_limit_kib: Optional[int] = None

    rules: List[Dict] = rules_cfg.get("rules", [])

    for host in hosts:
        for rule in rules:
            match = rule.get("match")
            match_regex = rule.get("match_regex")
            is_hit = False
            if match and host == match:
                is_hit = True
            elif match_regex:
                try:
                    if re.search(match_regex, host):
                        is_hit = True
                except re.error:
                    # Skip invalid regex rules
                    pass
            if is_hit:
                if "category" in rule and rule["category"]:
                    category = rule["category"]
                if "up_limit_kib" in rule:
                    try:
                        up_limit_kib = int(rule["up_limit_kib"])
                    except (TypeError, ValueError):
                        pass
                # First matching rule wins
                return category, up_limit_kib

    defaults = rules_cfg.get("defaults", {})
    if category is None and defaults.get("category"):
        category = defaults.get("category")
    if up_limit_kib is None and "up_limit_kib" in defaults:
        try:
            up_limit_kib = int(defaults.get("up_limit_kib", 0))
        except (TypeError, ValueError):
            up_limit_kib = None

    return category, up_limit_kib


def qb_get_categories(session: requests.Session, base_url: str) -> Dict:
    resp = session.get(f"{base_url}/api/v2/torrents/categories")
    if resp.status_code != 200:
        raise RuntimeError(f"Failed to fetch categories: {resp.status_code} {resp.text}")
    return resp.json()


def qb_create_category_if_missing(session: requests.Session, base_url: str, category: str) -> None:
    if not category:
        return
    cats = qb_get_categories(session, base_url)
    if category in cats:
        return
    resp = session.post(f"{base_url}/api/v2/torrents/createCategory", data={"category": category})
    if resp.status_code != 200:
        # If already exists or cannot be created, warn but continue
        print(f"Warning: createCategory returned {resp.status_code}: {resp.text}", file=sys.stderr)


def qb_set_category(session: requests.Session, base_url: str, torrent_hash: str, category: str) -> None:
    if not category:
        return
    resp = session.post(f"{base_url}/api/v2/torrents/setCategory", data={"hashes": torrent_hash, "category": category})
    if resp.status_code != 200:
        print(f"Warning: setCategory failed ({resp.status_code}): {resp.text}", file=sys.stderr)


def qb_set_upload_limit(session: requests.Session, base_url: str, torrent_hash: str, limit_kib_per_s: Optional[int]) -> None:
    if limit_kib_per_s is None:
        return
    # qB expects bytes/sec. KiB/s -> bytes/s
    limit_bytes = max(0, int(limit_kib_per_s) * 1024)
    resp = session.post(f"{base_url}/api/v2/torrents/setUploadLimit", data={"hashes": torrent_hash, "limit": str(limit_bytes)})
    if resp.status_code != 200:
        print(f"Warning: setUploadLimit failed ({resp.status_code}): {resp.text}", file=sys.stderr)


def qb_remove_tag(session: requests.Session, base_url: str, torrent_hash: str, tag: str) -> None:
    resp = session.post(f"{base_url}/api/v2/torrents/removeTags", data={"hashes": torrent_hash, "tags": tag})
    # Ignore non-200, tag removal is best-effort


def qb_resume(session: requests.Session, base_url: str, torrent_hash: str) -> None:
    resp = session.post(f"{base_url}/api/v2/torrents/resume", data={"hashes": torrent_hash})
    if resp.status_code != 200:
        print(f"Warning: resume failed ({resp.status_code}): {resp.text}", file=sys.stderr)


def main() -> None:
    args = parse_args()

    session = requests.Session()
    session.verify = not args.insecure

    qb_login(session, args.host, args.username, args.password)

    rules_cfg = load_rules(args.config)

    unique_tag = f"qbt-rules-{uuid.uuid4()}"

    qb_add_source(session, args.host, args.source, unique_tag, paused=True)

    # Poll for the new torrent to appear under our unique tag
    deadline = time.time() + args.timeout
    torrents: List[Dict] = []
    while time.time() < deadline:
        torrents = qb_find_torrents_by_tag(session, args.host, unique_tag)
        if torrents:
            break
        time.sleep(0.5)

    if not torrents:
        print("Error: Added torrent not found by tag within timeout.", file=sys.stderr)
        sys.exit(1)

    # Assume only one source per run; use the first
    torrent = torrents[0]
    torrent_hash = torrent.get("hash")

    trackers = qb_get_trackers(session, args.host, torrent_hash)
    hosts = extract_hostnames_from_trackers(trackers)

    category, up_limit_kib = match_rules(hosts, rules_cfg)

    if category:
        qb_create_category_if_missing(session, args.host, category)
        qb_set_category(session, args.host, torrent_hash, category)

    qb_set_upload_limit(session, args.host, torrent_hash, up_limit_kib)

    qb_remove_tag(session, args.host, torrent_hash, unique_tag)

    if not args.no_unpause:
        qb_resume(session, args.host, torrent_hash)

    applied = []
    if category:
        applied.append(f"category={category}")
    if up_limit_kib is not None:
        applied.append(f"up_limit_kib={up_limit_kib}")
    applied_str = ", ".join(applied) if applied else "no rules applied"

    print(f"Applied: {applied_str}. Hosts: {', '.join(hosts) if hosts else 'none'}")


if __name__ == "__main__":
    main()
