#!/usr/bin/env python3
"""
reference/sigid_mirror.py

Phase 6.3 — sovereign mirror of sigidwiki.com's signal identification
catalog. Designed to be run repeatedly (manually or via
systemd/sigid-mirror.timer) and only fetch what's new or changed since
the last successful run — not a one-shot dump.

Approach: MediaWiki's own API (api.php), not HTML scraping. This is
the respectful, designed-for-this-purpose path for programmatic access
to a MediaWiki site — a world apart from scraping rendered HTML, ToS-
wise. First run bootstraps from whatever's on the live API; subsequent
runs use `list=recentchanges` to fetch only pages that changed.

UNCONFIRMED, flagged rather than guessed: whether api.php is actually
open on this specific wiki (some installs restrict it), and the exact
namespace/category scoping that captures "signal entries" specifically
rather than every wiki page (Talk:, User:, etc.). Defaults below are
reasonable starting points, not verified against the live site from
this environment — check API_DISCOVERY_PATHS resolve, and revisit
PAGE_NAMESPACE/PAGE_CATEGORY once you can see real API responses.

Output layout (per docs/data-layout.md's /data/reference proposal):
  /data/reference/sigid/metadata/<page-title>.json   — text + revision info
  /data/reference/sigid/images/<filename>             — waterfall images etc.
  /data/reference/sigid/audio/<filename>               — example audio
  /data/reference/sigid/manifest.db                    — sync state

Usage:
  python3 sigid_mirror.py                 # normal incremental run
  python3 sigid_mirror.py --once          # same; explicit for systemd
  python3 sigid_mirror.py --dry-run       # report only, no writes
  python3 sigid_mirror.py --full-resync   # ignore cached revisions,
                                           # re-check every page (files
                                           # still skip via content hash)
"""

import argparse
import hashlib
import json
import logging
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin

import requests

from sigid_manifest import SigidManifest

BASE_URL = "https://www.sigidwiki.com"
API_DISCOVERY_PATHS = ["/api.php", "/w/api.php"]  # try both, cache whichever works

USER_AGENT = (
    "sovereign-sigint-mirror/1.0 "
    "(https://github.com/joecupano/sovereign-sigint; personal SIGINT reference mirror)"
)
REQUEST_DELAY_SECONDS = 1.5  # rate limit between requests — be a good citizen
REQUEST_TIMEOUT = 30

# Main namespace (0) holds actual wiki content pages, excluding
# Talk:/User:/etc. Reasonable default; refine if the wiki categorizes
# signal entries distinctly from other main-namespace content (about
# pages, guides, etc.) — see module docstring.
PAGE_NAMESPACE = 0

DEFAULT_OUTPUT_ROOT = Path("/data/reference/sigid")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sigid_mirror")


class MediaWikiAPIError(Exception):
    pass


def discover_api(session: requests.Session) -> str:
    """Find the working api.php path. Raises if neither candidate responds
    with a valid MediaWiki siteinfo payload."""
    for path in API_DISCOVERY_PATHS:
        url = urljoin(BASE_URL, path)
        try:
            resp = session.get(
                url,
                params={"action": "query", "meta": "siteinfo", "format": "json"},
                timeout=REQUEST_TIMEOUT,
            )
            data = resp.json()
            if "query" in data and "general" in data.get("query", {}):
                log.info("MediaWiki API found at %s", url)
                return url
        except (requests.RequestException, ValueError):
            continue
    raise MediaWikiAPIError(
        f"No working MediaWiki API found at {API_DISCOVERY_PATHS} under {BASE_URL}. "
        "api.php may be restricted on this install — this script's incremental-sync "
        "approach depends on it. See module docstring for the fallback discussion "
        "(Special:Export, or a from-archive bootstrap) that would need building if so."
    )


MAX_RETRIES = 5
INITIAL_BACKOFF_SECONDS = 5


def _get_with_retry(session: requests.Session, url: str, params: dict | None = None):
    """Shared GET with rate-limit resilience — used by both api_get()
    (MediaWiki API JSON calls) and download_file() (raw file bytes).
    A 429 here is expected and recoverable across a run that can make
    hundreds of calls (confirmed via a real bootstrap run that hit one
    on page 3) — not something that should kill the whole sync.
    Honors the server's Retry-After header when present.
    """
    for attempt in range(MAX_RETRIES):
        resp = session.get(url, params=params, timeout=REQUEST_TIMEOUT)

        if resp.status_code == 429:
            retry_after = resp.headers.get("Retry-After")
            wait = float(retry_after) if retry_after is not None else INITIAL_BACKOFF_SECONDS * (2 ** attempt)
            print(f"  Rate limited (429) on {url} — waiting {wait:.1f}s (attempt {attempt + 1}/{MAX_RETRIES})...")
            time.sleep(wait)
            continue

        resp.raise_for_status()
        time.sleep(REQUEST_DELAY_SECONDS)
        return resp

    raise MediaWikiAPIError(
        f"Still rate-limited after {MAX_RETRIES} retries against {url} — "
        f"the delay between requests ({REQUEST_DELAY_SECONDS}s) may need to "
        "be more conservative for sustained runs, not just single calls."
    )


def api_get(session: requests.Session, api_url: str, params: dict) -> dict:
    params = {**params, "format": "json"}
    resp = _get_with_retry(session, api_url, params=params)
    return resp.json()


def list_all_pages(session: requests.Session, api_url: str) -> list[str]:
    """Full page enumeration — used only on first-ever run (bootstrap)."""
    titles = []
    apcontinue = None
    while True:
        params = {
            "action": "query",
            "list": "allpages",
            "apnamespace": PAGE_NAMESPACE,
            "aplimit": "max",
        }
        if apcontinue:
            params["apcontinue"] = apcontinue
        data = api_get(session, api_url, params)
        titles.extend(p["title"] for p in data.get("query", {}).get("allpages", []))
        cont = data.get("continue", {})
        if "apcontinue" not in cont:
            break
        apcontinue = cont["apcontinue"]
    log.info("Enumerated %d pages (namespace %d)", len(titles), PAGE_NAMESPACE)
    return titles


def list_recent_changes(session: requests.Session, api_url: str, since_iso: str) -> list[str]:
    """Pages changed since the last successful run — the incremental path."""
    titles = set()
    rccontinue = None
    while True:
        params = {
            "action": "query",
            "list": "recentchanges",
            "rcnamespace": PAGE_NAMESPACE,
            "rcstart": "now",
            "rcend": since_iso,
            "rcdir": "older",
            "rclimit": "max",
            "rcprop": "title",
        }
        if rccontinue:
            params["rccontinue"] = rccontinue
        data = api_get(session, api_url, params)
        titles.update(c["title"] for c in data.get("query", {}).get("recentchanges", []))
        cont = data.get("continue", {})
        if "rccontinue" not in cont:
            break
        rccontinue = cont["rccontinue"]
    log.info("Found %d changed page(s) since %s", len(titles), since_iso)
    return list(titles)


def fetch_page(session: requests.Session, api_url: str, title: str) -> dict:
    """Current revision content + wikitext for one page."""
    data = api_get(
        session,
        api_url,
        {
            "action": "query",
            "titles": title,
            "prop": "revisions|images",
            "rvprop": "ids|content|timestamp",
            "rvslots": "main",
        },
    )
    pages = data.get("query", {}).get("pages", {})
    if not pages:
        raise MediaWikiAPIError(f"No page data returned for '{title}'")
    page = next(iter(pages.values()))
    revisions = page.get("revisions", [])
    if not revisions:
        raise MediaWikiAPIError(f"No revisions returned for '{title}'")
    rev = revisions[0]
    content = rev.get("slots", {}).get("main", {}).get("*", "") or rev.get("*", "")
    images = [img["title"] for img in page.get("images", [])]
    return {
        "title": title,
        "revision_id": rev["revid"],
        "timestamp": rev["timestamp"],
        "wikitext": content,
        "image_titles": images,
    }


AUDIO_EXTENSIONS = {".wav", ".mp3", ".ogg", ".flac", ".m4a"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".bmp"}


def resolve_file_url(session: requests.Session, api_url: str, file_title: str) -> str | None:
    data = api_get(
        session, api_url,
        {"action": "query", "titles": file_title, "prop": "imageinfo", "iiprop": "url"},
    )
    pages = data.get("query", {}).get("pages", {})
    if not pages:
        return None
    page = next(iter(pages.values()))
    imageinfo = page.get("imageinfo", [])
    return imageinfo[0]["url"] if imageinfo else None


def download_file(session: requests.Session, url: str, dest: Path, manifest: SigidManifest) -> bool:
    """Returns True if actually downloaded (new/changed), False if skipped
    (unchanged per manifest)."""
    resp = _get_with_retry(session, url)
    content_hash = hashlib.sha256(resp.content).hexdigest()

    if not manifest.file_needs_download(url, content_hash):
        return False

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(resp.content)
    manifest.record_file_synced(url, content_hash, dest)
    return True


def sync_page(
    session: requests.Session,
    api_url: str,
    title: str,
    output_root: Path,
    manifest: SigidManifest,
    dry_run: bool,
) -> tuple[bool, int]:
    """Returns (page_was_synced, files_synced_count)."""
    page = fetch_page(session, api_url, title)

    last_known_rev = manifest.last_page_revision(title)
    if last_known_rev == page["revision_id"]:
        return False, 0  # already have this exact revision

    if dry_run:
        log.info("[dry-run] would sync page: %s (rev %d)", title, page["revision_id"])
        return True, 0

    safe_name = re.sub(r"[^\w\-.]", "_", title)
    metadata_path = output_root / "metadata" / f"{safe_name}.json"
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        json.dumps(
            {
                "title": page["title"],
                "revision_id": page["revision_id"],
                "revision_timestamp": page["timestamp"],
                "synced_at": datetime.now(timezone.utc).isoformat(),
                "wikitext": page["wikitext"],
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    files_synced = 0
    for file_title in page["image_titles"]:
        file_url = resolve_file_url(session, api_url, file_title)
        if not file_url:
            continue
        ext = Path(file_url).suffix.lower()
        if ext in AUDIO_EXTENSIONS:
            subdir = "audio"
        elif ext in IMAGE_EXTENSIONS:
            subdir = "images"
        else:
            continue  # not something this mirror cares about (icons, etc.)

        filename = re.sub(r"[^\w\-.]", "_", Path(file_url).name)
        dest = output_root / subdir / filename
        if download_file(session, file_url, dest, manifest):
            files_synced += 1

    manifest.record_page_synced(title, page["revision_id"])
    return True, files_synced


def run(output_root: Path, dry_run: bool, full_resync: bool) -> dict:
    output_root.mkdir(parents=True, exist_ok=True)
    manifest = SigidManifest(output_root / "manifest.db")

    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})

    api_url = discover_api(session)

    last_run = None if full_resync else manifest.last_successful_run_time()
    mode = "bootstrap" if last_run is None else "incremental"
    run_id = manifest.start_run(mode)

    try:
        if mode == "bootstrap":
            log.info("No prior successful run found — bootstrapping full page list.")
            titles = list_all_pages(session, api_url)
        else:
            titles = list_recent_changes(session, api_url, last_run)

        pages_synced = 0
        files_synced = 0
        for title in titles:
            try:
                synced, n_files = sync_page(session, api_url, title, output_root, manifest, dry_run)
                if synced:
                    pages_synced += 1
                    files_synced += n_files
                    log.info("Synced: %s (+%d files)", title, n_files)
            except MediaWikiAPIError as exc:
                log.error("Failed to sync '%s': %s", title, exc)

        if not dry_run:
            manifest.finish_run(run_id, pages_synced, files_synced, "success")
        return {"mode": mode, "pages_synced": pages_synced, "files_synced": files_synced}

    except Exception as exc:
        manifest.finish_run(run_id, 0, 0, "error", str(exc))
        raise


def main():
    parser = argparse.ArgumentParser(description="sovereign-sigint SigID mirror")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--once", action="store_true", help="no-op flag for clarity in systemd unit")
    parser.add_argument("--full-resync", action="store_true",
                         help="ignore cached page revisions, re-check every page")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    args = parser.parse_args()

    log.info("Starting SigID mirror sync (dry_run=%s, full_resync=%s)", args.dry_run, args.full_resync)
    try:
        result = run(args.output_root, args.dry_run, args.full_resync)
    except MediaWikiAPIError as exc:
        log.error("%s", exc)
        return 1

    log.info(
        "Done. mode=%s pages_synced=%d files_synced=%d",
        result["mode"], result["pages_synced"], result["files_synced"],
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
