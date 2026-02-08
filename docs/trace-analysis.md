# Analyzing Your Claude Code Traces

Once you've been collecting traces for a few days, you'll have enough data to find real patterns in how Claude Code works. This guide explains the methodology, the queries, and how to interpret the results.

## Two Scripts, Two Approaches

| Script | Backend | Best for | Speed |
|--------|---------|----------|-------|
| `scripts/analyze-traces.sh` | ClickHouse direct (port 8124) | Self-hosted, large datasets | Fast (seconds) |
| `scripts/analyze-traces-sdk.py` | Langfuse REST API via SDK | Cloud or self-hosted, any size | Slower (paginates at 100/page) |

Both produce the same five analyses. Choose based on your deployment.

### Why two approaches?

The Langfuse [Metrics API v2](https://langfuse.com/docs/api-and-data-platform/features/query-via-sdk) — which supports server-side aggregations — is currently **Cloud-only**. On self-hosted deployments, calling it returns:

```
"v2 APIs are currently in beta and only available on Langfuse Cloud"
```

The REST API v1 works on self-hosted but paginates at 100 items per page with no aggregation support. For a dataset of 2,000+ traces, that's 20+ paginated requests just to list traces, then more for observations.

Querying ClickHouse directly bypasses all pagination — you get instant full-dataset analytics in a single HTTP call.

## Quick Start

### ClickHouse direct (self-hosted)

```bash
# Requires: Docker running with Langfuse stack
./scripts/analyze-traces.sh

# JSON output (pipe to jq, use in notebooks)
./scripts/analyze-traces.sh --json | jq .

# Filter by project tag
./scripts/analyze-traces.sh --tag my-project
```

### SDK / REST API (any deployment)

```bash
# Install the SDK
pip install langfuse

# Set credentials (self-hosted: extract from Docker)
export LANGFUSE_PUBLIC_KEY=$(docker exec langfuse-web printenv LANGFUSE_INIT_PROJECT_PUBLIC_KEY)
export LANGFUSE_SECRET_KEY=$(docker exec langfuse-web printenv LANGFUSE_INIT_PROJECT_SECRET_KEY)
export LANGFUSE_HOST=http://localhost:3050

# Run
python3 scripts/analyze-traces-sdk.py

# JSON output
python3 scripts/analyze-traces-sdk.py --json | jq .

# Filter by tag
python3 scripts/analyze-traces-sdk.py --tag my-project
```

## How the Data Model Works

Understanding the Langfuse schema helps you write custom queries.

```
Session (conversation)
  └── Trace (one per turn)
        ├── observation: "Claude Response" (type: GENERATION)
        ├── observation: "Tool: Read"      (type: SPAN)
        ├── observation: "Tool: Edit"      (type: SPAN)
        ├── observation: "Tool: Bash"      (type: SPAN)
        └── observation: "Tool: Grep"      (type: SPAN)
```

- **Session**: Groups all turns in a Claude Code conversation. Identified by `session_id`.
- **Trace**: One per user turn. Named `"Turn 1"`, `"Turn 2"`, etc. Contains the user prompt as `input` and assistant response as `output`.
- **Observation**: A span within a trace. Tool calls are named `"Tool: <name>"`. The Claude response is a generation span named `"Claude Response"`.

### ClickHouse Tables

> **Warning**: These are internal Langfuse tables. The schema may change between versions. The queries in this guide were tested against Langfuse v3.150.0.

**`traces`** — One row per turn:

| Column | Type | Description |
|--------|------|-------------|
| `id` | String | Trace ID |
| `session_id` | Nullable(String) | Session grouping key |
| `name` | String | e.g., `"Turn 1"` |
| `timestamp` | DateTime64(3) | When the turn started |
| `tags` | Array(String) | e.g., `["claude-code", "my-project"]` |
| `input` | Nullable(String) | User prompt (JSON string) |
| `output` | Nullable(String) | Assistant response (JSON string) |
| `project_id` | String | Always `"claude-code"` for this template |

**`observations`** — One row per tool call or generation:

| Column | Type | Description |
|--------|------|-------------|
| `id` | String | Observation ID |
| `trace_id` | String | Parent trace |
| `name` | String | e.g., `"Tool: Read"`, `"Claude Response"` |
| `type` | String | `"SPAN"` for tools, `"GENERATION"` for Claude |
| `start_time` | DateTime64(3) | When the tool call started |
| `end_time` | Nullable(DateTime64(3)) | When it completed |
| `input` | Nullable(String) | Tool input (ZSTD compressed) |
| `output` | Nullable(String) | Tool output (ZSTD compressed) |

## The Five Analyses

### 1. Overview

Total traces, sessions, observations, and date range. Sanity check that data is flowing.

### 2. Tool Usage Distribution

Counts every `"Tool: *"` observation, excluding meta-tools (TaskCreate, TaskUpdate, ExitPlanMode, AskUserQuestion) that are orchestration overhead rather than coding activity.

**What to look for:**
- **Bash dominance** — If Bash is 40%+ of tool calls, Claude is spending more time executing commands (running tests, git ops, validation) than writing code. This is normal and healthy.
- **Read:Edit ratio** — A ratio near 1:1 means Claude reads a file for every edit. Higher means more exploration before acting.
- **Grep/Glob usage** — High search activity suggests Claude is working on unfamiliar codebases or large refactors.

### 3. Session Turn Distribution

Buckets sessions by how many turns they last. Expect a heavy skew toward single-turn sessions if you have automated workflows (email triage, scheduled tasks).

**What to look for:**
- **Single-turn percentage** — If >80% are single-turn, your most productive AI pattern is one-shot automation, not interactive coding.
- **Long tail** — Sessions with 15+ turns warrant investigation. Are they productive or spinning?

### 4. Productivity by Session Length

The key analysis. Groups multi-turn sessions by length and measures **code changes per turn** (Edit + Write calls divided by turn count).

**What to look for:**
- **Productivity cliff** — In our data, sessions with 4-7 turns produced 2.16 changes/turn (peak). Sessions with 13+ turns dropped to 1.18 changes/turn — a 45% decline. Each additional turn past the sweet spot produces diminishing returns.
- **Read-to-write ratio increase** — Longer sessions tend to have higher read:write ratios, meaning more searching and less producing. This is the "spinning" signal.

**Actionable takeaway:** If a session passes ~10 turns without shipping, consider restarting with a refined prompt. Break large tasks into smaller, focused sessions.

### 5. Read-Before-Edit Pattern

Checks whether traces that include Edit or Write also include a Read step. Measures the "measure twice, cut once" behavior.

**What to look for:**
- **High percentage (>85%)** — Claude consistently reads before editing. This is the disciplined pattern.
- **Low percentage (<70%)** — Could indicate rushed sessions or over-reliance on context from prior turns.
- **Exploration → Edit conversion** — What percentage of Read+Grep (deep exploration) sessions result in actual edits? Low conversion means exploration sessions that don't produce output.

## Writing Custom Queries

### Connect to ClickHouse

```bash
# Get the password from the running container
CH_PASS=$(docker exec langfuse-web printenv CLICKHOUSE_PASSWORD)

# Run any SQL query
curl -s "http://localhost:8124/?user=clickhouse&password=${CH_PASS}" \
  --data-binary "YOUR SQL HERE FORMAT Pretty"
```

### Example: Most active projects

```sql
SELECT
    arrayJoin(tags) as tag,
    count(DISTINCT session_id) as sessions,
    count() as traces
FROM traces
WHERE project_id = 'claude-code' AND is_deleted = 0
GROUP BY tag
ORDER BY sessions DESC
FORMAT Pretty
```

### Example: Average session duration

```sql
SELECT
    round(avg(duration_min), 1) as avg_minutes,
    round(median(duration_min), 1) as median_minutes
FROM (
    SELECT
        session_id,
        dateDiff('minute', min(timestamp), max(timestamp)) as duration_min
    FROM traces
    WHERE project_id = 'claude-code' AND is_deleted = 0
        AND session_id IS NOT NULL
    GROUP BY session_id
    HAVING count() > 1
)
FORMAT Pretty
```

### Example: Tool usage by project

```sql
SELECT
    arrayJoin(t.tags) as project,
    o.name as tool,
    count() as calls
FROM observations o
JOIN traces t ON o.trace_id = t.id AND t.project_id = 'claude-code'
WHERE o.project_id = 'claude-code' AND o.is_deleted = 0
    AND o.name LIKE 'Tool:%'
GROUP BY project, tool
ORDER BY project, calls DESC
FORMAT Pretty
```

### Example: First prompt length vs session turns

```sql
WITH first_turns AS (
    SELECT session_id, length(input) as prompt_len
    FROM traces
    WHERE project_id = 'claude-code' AND is_deleted = 0
        AND name = 'Turn 1' AND session_id IS NOT NULL
),
session_sizes AS (
    SELECT session_id, count() as turns
    FROM traces
    WHERE project_id = 'claude-code' AND is_deleted = 0
        AND session_id IS NOT NULL
    GROUP BY session_id
    HAVING turns > 1
)
SELECT
    multiIf(
        prompt_len < 100, 'Short (<100)',
        prompt_len < 300, 'Medium (100-300)',
        prompt_len < 600, 'Long (300-600)',
        'Very Long (600+)'
    ) as prompt_size,
    count() as sessions,
    round(avg(turns), 1) as avg_turns,
    round(median(turns), 1) as median_turns
FROM first_turns f
JOIN session_sizes s ON f.session_id = s.session_id
GROUP BY prompt_size
ORDER BY min(prompt_len)
FORMAT Pretty
```

## Caveats

- **ClickHouse schema is internal**: Langfuse does not document or guarantee the ClickHouse table structure. It may change between versions. Pin your Langfuse version if you build pipelines on these queries.
- **Historical sessions**: Sessions with IDs like `historical-2026-01-25` are imported from prior transcript archives. The `session_id NOT LIKE 'historical-%'` filter excludes them.
- **Automated sessions**: If you run Claude Code for automated tasks (email triage, scheduled jobs), these inflate single-turn session counts. Filter by tag to focus on interactive coding sessions.
- **Observation ordering**: ClickHouse does not guarantee row order within a trace. Use `start_time` if you need tool call sequence within a turn.
