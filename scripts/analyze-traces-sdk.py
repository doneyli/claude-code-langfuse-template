#!/usr/bin/env python3
"""
Langfuse Trace Analyzer — SDK / REST API

Analyzes Claude Code session traces using the official Langfuse Python SDK.
Produces the same analytics as analyze-traces.sh but works with both
self-hosted and Langfuse Cloud deployments.

Usage:
    python3 scripts/analyze-traces-sdk.py              # Pretty output
    python3 scripts/analyze-traces-sdk.py --json       # JSON output
    python3 scripts/analyze-traces-sdk.py --tag myproj # Filter by tag

Prerequisites:
    pip install langfuse

Environment variables:
    LANGFUSE_PUBLIC_KEY  — Project public key
    LANGFUSE_SECRET_KEY  — Project secret key
    LANGFUSE_HOST        — Langfuse URL (default: http://localhost:3050)

Note: This script paginates through the REST API (100 items/page), so it
will be slower than analyze-traces.sh for large datasets. For self-hosted
deployments with thousands of traces, prefer the ClickHouse-direct script.

See docs/trace-analysis.md for methodology and interpretation guide.
"""

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime

try:
    from langfuse import Langfuse
except ImportError:
    print("Error: langfuse package not installed. Run: pip install langfuse", file=sys.stderr)
    sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(description="Analyze Langfuse traces from Claude Code sessions")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--tag", type=str, default="", help="Filter by project tag")
    parser.add_argument("--limit", type=int, default=0, help="Max traces to fetch (0 = all)")
    return parser.parse_args()


def fetch_all_traces(client, tag_filter="", limit=0):
    """Fetch all traces with pagination."""
    traces = []
    page = 1
    while True:
        batch = client.api.trace.list(limit=100, page=page)
        if not batch.data:
            break
        for t in batch.data:
            if tag_filter and tag_filter not in (t.tags or []):
                continue
            traces.append(t)
        if limit and len(traces) >= limit:
            traces = traces[:limit]
            break
        if page >= batch.meta.total_pages:
            break
        page += 1
        if page % 10 == 0:
            print(f"  Fetching traces... page {page}/{batch.meta.total_pages}", file=sys.stderr)
    return traces


def fetch_observations_for_trace(client, trace_id):
    """Fetch all observations for a single trace."""
    observations = []
    page = 1
    while True:
        batch = client.api.observations.get_many(trace_id=trace_id, limit=100, page=page)
        if not batch.data:
            break
        observations.extend(batch.data)
        if page >= batch.meta.total_pages:
            break
        page += 1
    return observations


def analyze(traces, client, tag_filter=""):
    """Run all analyses on fetched traces."""

    # --- 1. Overview ---
    session_ids = set()
    timestamps = []
    for t in traces:
        if t.session_id:
            session_ids.add(t.session_id)
        if t.timestamp:
            timestamps.append(t.timestamp)

    overview = {
        "total_traces": len(traces),
        "total_sessions": len(session_ids),
        "earliest": min(timestamps).isoformat() if timestamps else None,
        "latest": max(timestamps).isoformat() if timestamps else None,
    }

    # --- Build per-trace observation data ---
    # Group traces by session
    sessions = defaultdict(list)
    for t in traces:
        sid = t.session_id or "no-session"
        if sid.startswith("historical-"):
            continue
        sessions[sid].append(t)

    # Fetch observations for traces with tool calls
    print("  Fetching observations (this may take a while)...", file=sys.stderr)
    trace_observations = {}
    tool_counter = Counter()
    total_obs = 0

    # Only fetch observations for multi-turn sessions to save time
    traces_to_fetch = []
    for sid, session_traces in sessions.items():
        if len(session_traces) > 1:
            traces_to_fetch.extend(session_traces)

    # Also sample single-turn sessions (up to 50) for tool distribution
    single_turn_sessions = [ts[0] for sid, ts in sessions.items() if len(ts) == 1]
    traces_to_fetch.extend(single_turn_sessions[:50])

    for i, t in enumerate(traces_to_fetch):
        obs_list = fetch_observations_for_trace(client, t.id)
        trace_observations[t.id] = obs_list
        total_obs += len(obs_list)
        for o in obs_list:
            if o.name and o.name.startswith("Tool:"):
                tool_counter[o.name] += 1
        if (i + 1) % 20 == 0:
            print(f"  Processed {i + 1}/{len(traces_to_fetch)} traces...", file=sys.stderr)

    overview["total_observations"] = total_obs

    # --- 2. Tool Distribution ---
    # Filter out meta tools
    meta_prefixes = ("Tool: Task", "Tool: ExitPlan", "Tool: AskUser")
    coding_tools = {k: v for k, v in tool_counter.items()
                    if not any(k.startswith(p) for p in meta_prefixes)}
    total_coding = sum(coding_tools.values())

    tool_distribution = []
    for name, count in sorted(coding_tools.items(), key=lambda x: -x[1]):
        pct = round(count * 100.0 / total_coding, 1) if total_coding else 0
        tool_distribution.append({"name": name, "count": count, "pct": pct})

    # Grouped categories
    categories = Counter()
    for name, count in tool_counter.items():
        if name == "Tool: Read":
            categories["READ (understand)"] += count
        elif name in ("Tool: Grep", "Tool: Glob"):
            categories["SEARCH (find)"] += count
        elif name in ("Tool: Edit", "Tool: Write"):
            categories["WRITE (modify)"] += count
        elif name == "Tool: Bash":
            categories["EXECUTE (run/test)"] += count
        elif name in ("Tool: WebSearch", "Tool: WebFetch"):
            categories["WEB (research)"] += count
        elif name.startswith("Tool: mcp"):
            categories["MCP (external tools)"] += count
        elif name.startswith("Tool: Task") or name.startswith("Tool: ExitPlan") or name.startswith("Tool: AskUser"):
            categories["META (task mgmt)"] += count
        else:
            categories["OTHER"] += count

    total_all = sum(categories.values())
    category_distribution = []
    for cat, count in sorted(categories.items(), key=lambda x: -x[1]):
        pct = round(count * 100.0 / total_all, 1) if total_all else 0
        category_distribution.append({"category": cat, "count": count, "pct": pct})

    # --- 3. Session Turn Distribution ---
    turn_buckets = Counter()
    for sid, session_traces in sessions.items():
        n = len(session_traces)
        if n == 1:
            turn_buckets["1 turn"] += 1
        elif n <= 3:
            turn_buckets["2-3 turns"] += 1
        elif n <= 7:
            turn_buckets["4-7 turns"] += 1
        elif n <= 12:
            turn_buckets["8-12 turns"] += 1
        else:
            turn_buckets["13+ turns"] += 1

    bucket_order = ["1 turn", "2-3 turns", "4-7 turns", "8-12 turns", "13+ turns"]
    session_distribution = [{"bucket": b, "sessions": turn_buckets.get(b, 0)} for b in bucket_order]

    # --- 4. Productivity by Session Length ---
    productivity = []
    for bucket_name, min_turns, max_turns in [("2-3 turns", 2, 3), ("4-7 turns", 4, 7),
                                                ("8-12 turns", 8, 12), ("13+ turns", 13, 999)]:
        bucket_sessions = []
        for sid, session_traces in sessions.items():
            n = len(session_traces)
            if min_turns <= n <= max_turns:
                changes = 0
                reads = 0
                bashes = 0
                for t in session_traces:
                    for o in trace_observations.get(t.id, []):
                        if o.name == "Tool: Edit" or o.name == "Tool: Write":
                            changes += 1
                        elif o.name == "Tool: Read":
                            reads += 1
                        elif o.name == "Tool: Bash":
                            bashes += 1
                bucket_sessions.append({
                    "turns": n, "changes": changes, "reads": reads, "bashes": bashes
                })

        if bucket_sessions:
            avg_changes = round(sum(s["changes"] for s in bucket_sessions) / len(bucket_sessions), 1)
            avg_reads = round(sum(s["reads"] for s in bucket_sessions) / len(bucket_sessions), 1)
            avg_bashes = round(sum(s["bashes"] for s in bucket_sessions) / len(bucket_sessions), 1)
            avg_turns = sum(s["turns"] for s in bucket_sessions) / len(bucket_sessions)
            changes_per_turn = round(avg_changes / avg_turns, 2) if avg_turns else 0
            r2w = round(avg_reads / max(avg_changes, 0.1), 1)
            productivity.append({
                "bucket": bucket_name,
                "sessions": len(bucket_sessions),
                "avg_changes": avg_changes,
                "avg_reads": avg_reads,
                "avg_bashes": avg_bashes,
                "changes_per_turn": changes_per_turn,
                "read_to_write_ratio": r2w,
            })

    # --- 5. Read-Before-Edit Pattern ---
    traces_with_edit = 0
    edit_with_read = 0
    traces_with_write = 0
    write_with_read = 0
    exploration_traces = 0
    exploration_to_edit = 0

    for tid, obs_list in trace_observations.items():
        tool_names = {o.name for o in obs_list if o.name and o.name.startswith("Tool:")}
        if len(tool_names) < 3:
            continue

        has_read = "Tool: Read" in tool_names
        has_edit = "Tool: Edit" in tool_names
        has_write = "Tool: Write" in tool_names
        has_grep = "Tool: Grep" in tool_names

        if has_edit:
            traces_with_edit += 1
            if has_read:
                edit_with_read += 1

        if has_write:
            traces_with_write += 1
            if has_read:
                write_with_read += 1

        if has_read and has_grep:
            exploration_traces += 1
            if has_edit:
                exploration_to_edit += 1

    patterns = {
        "traces_with_edit": traces_with_edit,
        "edit_with_read": edit_with_read,
        "pct_read_before_edit": round(edit_with_read * 100.0 / max(traces_with_edit, 1), 1),
        "traces_with_write": traces_with_write,
        "write_with_read": write_with_read,
        "pct_read_before_write": round(write_with_read * 100.0 / max(traces_with_write, 1), 1),
        "exploration_traces": exploration_traces,
        "exploration_to_edit": exploration_to_edit,
        "pct_exploration_to_edit": round(exploration_to_edit * 100.0 / max(exploration_traces, 1), 1),
    }

    return {
        "overview": overview,
        "tool_distribution": tool_distribution,
        "category_distribution": category_distribution,
        "session_distribution": session_distribution,
        "productivity_by_length": productivity,
        "patterns": patterns,
    }


def print_pretty(results):
    """Print results in a human-readable format."""
    BOLD = "\033[1m"
    BLUE = "\033[0;34m"
    DIM = "\033[2m"
    NC = "\033[0m"

    def header(title):
        print(f"\n{BLUE}{'━' * 58}{NC}")
        print(f"{BOLD} {title}{NC}")
        print(f"{BLUE}{'━' * 58}{NC}\n")

    # Overview
    ov = results["overview"]
    header("1. Overview")
    print(f"  Traces:       {ov['total_traces']}")
    print(f"  Sessions:     {ov['total_sessions']}")
    print(f"  Observations: {ov['total_observations']}")
    print(f"  Date range:   {ov['earliest'][:10] if ov['earliest'] else 'N/A'} to {ov['latest'][:10] if ov['latest'] else 'N/A'}")

    # Tool distribution
    header("2. Tool Usage Distribution")
    print(f"  {'Tool':<35} {'Calls':>6} {'%':>6}")
    print(f"  {'─' * 49}")
    for t in results["tool_distribution"][:15]:
        print(f"  {t['name']:<35} {t['count']:>6} {t['pct']:>5.1f}%")

    print(f"\n  {DIM}Grouped by action type:{NC}")
    print(f"  {'Category':<25} {'Calls':>6} {'%':>6}")
    print(f"  {'─' * 39}")
    for c in results["category_distribution"]:
        print(f"  {c['category']:<25} {c['count']:>6} {c['pct']:>5.1f}%")

    # Session distribution
    header("3. Session Turn Distribution")
    print(f"  {'Bucket':<15} {'Sessions':>10}")
    print(f"  {'─' * 27}")
    for s in results["session_distribution"]:
        print(f"  {s['bucket']:<15} {s['sessions']:>10}")

    # Productivity
    header("4. Productivity by Session Length")
    print(f"  {'Bucket':<12} {'Sessions':>8} {'Changes':>9} {'Reads':>7} {'Chg/Turn':>10} {'R:W':>6}")
    print(f"  {'─' * 54}")
    for p in results["productivity_by_length"]:
        print(f"  {p['bucket']:<12} {p['sessions']:>8} {p['avg_changes']:>9} {p['avg_reads']:>7} {p['changes_per_turn']:>10} {p['read_to_write_ratio']:>5.1f}")
    print(f"\n  {DIM}changes_per_turn = avg(Edit + Write) / avg(turns){NC}")

    # Patterns
    header("5. Read-Before-Edit Pattern")
    pat = results["patterns"]
    print(f"  Traces with Edit:         {pat['traces_with_edit']:>5}  ({pat['pct_read_before_edit']}% also Read first)")
    print(f"  Traces with Write:        {pat['traces_with_write']:>5}  ({pat['pct_read_before_write']}% also Read first)")
    print(f"  Exploration (Read+Grep):  {pat['exploration_traces']:>5}  ({pat['pct_exploration_to_edit']}% lead to Edit)")

    print(f"\n{BLUE}{'━' * 58}{NC}")
    print(f"{BOLD} Done.{NC} {DIM}See docs/trace-analysis.md for interpretation guide.{NC}")
    print(f"{BLUE}{'━' * 58}{NC}\n")


def main():
    args = parse_args()

    # Initialize client
    host = os.environ.get("LANGFUSE_HOST", "http://localhost:3050")
    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY")

    if not public_key or not secret_key:
        print("Error: Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY environment variables.", file=sys.stderr)
        print(f"  Tip: Extract from Docker with:", file=sys.stderr)
        print(f"    export LANGFUSE_PUBLIC_KEY=$(docker exec langfuse-web printenv LANGFUSE_INIT_PROJECT_PUBLIC_KEY)", file=sys.stderr)
        print(f"    export LANGFUSE_SECRET_KEY=$(docker exec langfuse-web printenv LANGFUSE_INIT_PROJECT_SECRET_KEY)", file=sys.stderr)
        sys.exit(1)

    client = Langfuse(public_key=public_key, secret_key=secret_key, host=host)

    # Verify connection
    try:
        health = client.api.health.health()
        if not args.json:
            print(f"\n  Connected to Langfuse {health.version} at {host}")
    except Exception as e:
        print(f"Error: Could not connect to Langfuse at {host}: {e}", file=sys.stderr)
        sys.exit(1)

    # Fetch traces
    if not args.json:
        print("  Fetching traces...", file=sys.stderr)
    traces = fetch_all_traces(client, tag_filter=args.tag, limit=args.limit)

    if not traces:
        print("No traces found.", file=sys.stderr)
        sys.exit(0)

    if not args.json:
        print(f"  Found {len(traces)} traces. Analyzing...", file=sys.stderr)

    # Analyze
    results = analyze(traces, client, tag_filter=args.tag)

    # Output
    if args.json:
        print(json.dumps(results, indent=2, default=str))
    else:
        print_pretty(results)

    client.shutdown()


if __name__ == "__main__":
    main()
