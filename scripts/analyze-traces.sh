#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Langfuse Trace Analyzer — ClickHouse Direct
#
# Analyzes Claude Code session traces by querying Langfuse's internal
# ClickHouse database directly. Produces tool usage distributions, session
# metrics, productivity analysis, and behavioral patterns.
#
# Usage:
#   ./scripts/analyze-traces.sh              # Pretty terminal output
#   ./scripts/analyze-traces.sh --json       # Machine-readable JSON
#   ./scripts/analyze-traces.sh --tag myproj # Filter by project tag
#
# Prerequisites:
#   - Docker running with Langfuse stack (docker compose up -d)
#   - curl installed
#
# Why ClickHouse direct instead of the REST API?
#   The Langfuse REST API paginates at 100 items per page and has no
#   aggregation support. The Metrics API v2 (which does aggregation) is
#   Cloud-only. For self-hosted deployments, querying ClickHouse directly
#   is the only practical path for full-dataset analytics.
#
# See docs/trace-analysis.md for methodology and query explanations.
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Defaults
OUTPUT_FORMAT="pretty"
TAG_FILTER=""
CH_PORT="${LANGFUSE_CH_PORT:-8124}"
CH_USER="clickhouse"
CONTAINER_NAME="${LANGFUSE_CONTAINER:-langfuse-web}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --tag)
            TAG_FILTER="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--json] [--tag <project-tag>]"
            echo ""
            echo "Options:"
            echo "  --json           Output results as JSON (pipe to jq)"
            echo "  --tag <tag>      Filter traces by project tag"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  LANGFUSE_CH_PORT       ClickHouse HTTP port (default: 8124)"
            echo "  LANGFUSE_CONTAINER     Web container name (default: langfuse-web)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Helpers ---

print_header() {
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD} $1${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
}

print_subheader() {
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        echo -e "${CYAN}  $1${NC}"
        echo ""
    fi
}

check_pass() {
    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        echo -e "${GREEN}  ✓ $1${NC}"
    fi
}

check_fail() {
    echo -e "${RED}  ✗ $1${NC}" >&2
    exit 1
}

query_ch() {
    local sql="$1"
    local format="${2:-Pretty}"
    curl -sf "http://localhost:${CH_PORT}/?user=${CH_USER}&password=${CH_PASSWORD}" \
        --data-binary "$sql FORMAT $format" 2>/dev/null
}

query_ch_raw() {
    local sql="$1"
    curl -sf "http://localhost:${CH_PORT}/?user=${CH_USER}&password=${CH_PASSWORD}" \
        --data-binary "$sql" 2>/dev/null
}

# Build tag filter clause for SQL
tag_where() {
    if [[ -n "$TAG_FILTER" ]]; then
        echo "AND has(tags, '${TAG_FILTER}')"
    fi
}

# For observations, filter via trace join
tag_obs_where() {
    if [[ -n "$TAG_FILTER" ]]; then
        echo "AND trace_id IN (SELECT id FROM traces WHERE project_id = 'claude-code' AND is_deleted = 0 AND has(tags, '${TAG_FILTER}'))"
    fi
}

# --- Preflight Checks ---

if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
    echo ""
    echo -e "${BOLD}Langfuse Trace Analyzer${NC} ${DIM}(ClickHouse direct)${NC}"
fi

# Check Docker
if ! docker info &>/dev/null; then
    check_fail "Docker is not running. Start Docker and try again."
fi

# Check container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    check_fail "Container '${CONTAINER_NAME}' is not running. Run: docker compose up -d"
fi

# Extract ClickHouse password from running container
CH_PASSWORD=$(docker exec "$CONTAINER_NAME" printenv CLICKHOUSE_PASSWORD 2>/dev/null) || \
    check_fail "Could not read CLICKHOUSE_PASSWORD from ${CONTAINER_NAME}"

# Verify ClickHouse connectivity
if ! curl -sf "http://localhost:${CH_PORT}/ping" &>/dev/null; then
    check_fail "ClickHouse not reachable on port ${CH_PORT}"
fi

check_pass "Connected to ClickHouse on port ${CH_PORT}"

if [[ -n "$TAG_FILTER" ]]; then
    check_pass "Filtering by tag: ${TAG_FILTER}"
fi

# =============================================================================
# JSON output mode — collect all results in a single JSON object
# =============================================================================

if [[ "$OUTPUT_FORMAT" == "json" ]]; then

    # Overview
    overview=$(query_ch_raw "
        SELECT
            count() as total_traces,
            count(DISTINCT session_id) as total_sessions,
            min(timestamp) as earliest,
            max(timestamp) as latest
        FROM traces
        WHERE project_id = 'claude-code' AND is_deleted = 0
            $(tag_where)
        FORMAT JSONEachRow
    ")

    obs_count=$(query_ch_raw "
        SELECT count() as total_observations
        FROM observations
        WHERE project_id = 'claude-code' AND is_deleted = 0
            $(tag_obs_where)
        FORMAT JSONEachRow
    ")

    # Tool distribution
    tool_dist=$(query_ch_raw "
        SELECT
            name,
            count() as count,
            round(count() * 100.0 / (
                SELECT count() FROM observations
                WHERE project_id = 'claude-code' AND is_deleted = 0
                    AND name LIKE 'Tool:%'
                    AND name NOT LIKE 'Tool: Task%'
                    AND name NOT LIKE 'Tool: ExitPlan%'
                    AND name NOT LIKE 'Tool: AskUser%'
                    $(tag_obs_where)
            ), 1) as pct
        FROM observations
        WHERE project_id = 'claude-code' AND is_deleted = 0
            AND name LIKE 'Tool:%'
            AND name NOT LIKE 'Tool: Task%'
            AND name NOT LIKE 'Tool: ExitPlan%'
            AND name NOT LIKE 'Tool: AskUser%'
            $(tag_obs_where)
        GROUP BY name
        ORDER BY count DESC
        FORMAT JSONEachRow
    ")

    # Session distribution
    session_dist=$(query_ch_raw "
        WITH session_turns AS (
            SELECT session_id, count() as turns
            FROM traces
            WHERE project_id = 'claude-code' AND is_deleted = 0
                AND session_id IS NOT NULL AND session_id NOT LIKE 'historical-%'
                $(tag_where)
            GROUP BY session_id
        )
        SELECT
            multiIf(
                turns = 1, '1',
                turns <= 3, '2-3',
                turns <= 7, '4-7',
                turns <= 12, '8-12',
                '13+'
            ) as bucket,
            count() as sessions,
            round(avg(turns), 1) as avg_turns
        FROM session_turns
        GROUP BY bucket
        ORDER BY min(turns)
        FORMAT JSONEachRow
    ")

    # Productivity
    productivity=$(query_ch_raw "
        WITH session_metrics AS (
            SELECT
                t.session_id,
                count(DISTINCT t.id) as turns,
                countIf(o.name = 'Tool: Edit') + countIf(o.name = 'Tool: Write') as changes,
                countIf(o.name = 'Tool: Read') as reads,
                countIf(o.name = 'Tool: Bash') as bashes
            FROM traces t
            LEFT JOIN observations o ON t.id = o.trace_id AND o.project_id = 'claude-code'
            WHERE t.project_id = 'claude-code' AND t.is_deleted = 0
                AND t.session_id IS NOT NULL AND t.session_id NOT LIKE 'historical-%'
                $(tag_where | sed 's/tags/t.tags/g')
            GROUP BY t.session_id
            HAVING turns > 1
        )
        SELECT
            multiIf(turns<=3,'2-3',turns<=7,'4-7',turns<=12,'8-12','13+') as bucket,
            count() as sessions,
            round(avg(changes), 1) as avg_changes,
            round(avg(reads), 1) as avg_reads,
            round(avg(bashes), 1) as avg_bashes,
            round(avg(changes) / avg(turns), 2) as changes_per_turn,
            round(avg(reads) / greatest(avg(changes), 0.1), 1) as read_to_write_ratio
        FROM session_metrics
        GROUP BY bucket
        ORDER BY min(turns)
        FORMAT JSONEachRow
    ")

    # Read-before-edit
    patterns=$(query_ch_raw "
        WITH trace_tools AS (
            SELECT
                trace_id,
                has(groupArray(name), 'Tool: Read') as has_read,
                has(groupArray(name), 'Tool: Edit') as has_edit,
                has(groupArray(name), 'Tool: Write') as has_write,
                has(groupArray(name), 'Tool: Grep') as has_grep,
                length(groupArray(name)) as tool_count
            FROM observations
            WHERE project_id = 'claude-code' AND is_deleted = 0 AND name LIKE 'Tool:%'
                $(tag_obs_where)
            GROUP BY trace_id
            HAVING tool_count >= 3
        )
        SELECT
            countIf(has_edit) as traces_with_edit,
            countIf(has_edit AND has_read) as edit_with_read,
            round(countIf(has_edit AND has_read) * 100.0 / greatest(countIf(has_edit), 1), 1) as pct_read_before_edit,
            countIf(has_write) as traces_with_write,
            countIf(has_write AND has_read) as write_with_read,
            round(countIf(has_write AND has_read) * 100.0 / greatest(countIf(has_write), 1), 1) as pct_read_before_write,
            countIf(has_read AND has_grep) as exploration_traces,
            countIf(has_read AND has_grep AND has_edit) as exploration_to_edit,
            round(countIf(has_read AND has_grep AND has_edit) * 100.0 / greatest(countIf(has_read AND has_grep), 1), 1) as pct_exploration_to_edit
        FORMAT JSONEachRow
    ")

    # Assemble JSON
    echo "{"
    echo "  \"overview\": ${overview},"
    echo "  \"observation_count\": ${obs_count},"
    echo "  \"tool_distribution\": [$(echo "$tool_dist" | paste -sd, -)],"
    echo "  \"session_distribution\": [$(echo "$session_dist" | paste -sd, -)],"
    echo "  \"productivity_by_length\": [$(echo "$productivity" | paste -sd, -)],"
    echo "  \"patterns\": ${patterns}"
    echo "}"

    exit 0
fi

# =============================================================================
# Pretty output mode
# =============================================================================

# --- 1. Overview ---
print_header "1. Overview"

query_ch "
SELECT
    count() as traces,
    count(DISTINCT session_id) as sessions,
    formatDateTime(min(timestamp), '%Y-%m-%d') as earliest,
    formatDateTime(max(timestamp), '%Y-%m-%d') as latest
FROM traces
WHERE project_id = 'claude-code' AND is_deleted = 0
    $(tag_where)
"

obs_total=$(query_ch_raw "SELECT count() FROM observations WHERE project_id = 'claude-code' AND is_deleted = 0 $(tag_obs_where)")
echo -e "  ${DIM}Total observations: ${obs_total}${NC}"
echo ""

# --- 2. Tool Usage Distribution ---
print_header "2. Tool Usage Distribution"
print_subheader "Coding tools only (excludes TaskCreate/Update, ExitPlanMode, AskUser)"

query_ch "
SELECT
    name as tool,
    count() as calls,
    round(count() * 100.0 / (
        SELECT count() FROM observations
        WHERE project_id = 'claude-code' AND is_deleted = 0
            AND name LIKE 'Tool:%'
            AND name NOT LIKE 'Tool: Task%'
            AND name NOT LIKE 'Tool: ExitPlan%'
            AND name NOT LIKE 'Tool: AskUser%'
            $(tag_obs_where)
    ), 1) as pct
FROM observations
WHERE project_id = 'claude-code' AND is_deleted = 0
    AND name LIKE 'Tool:%'
    AND name NOT LIKE 'Tool: Task%'
    AND name NOT LIKE 'Tool: ExitPlan%'
    AND name NOT LIKE 'Tool: AskUser%'
    $(tag_obs_where)
GROUP BY tool
ORDER BY calls DESC
LIMIT 15
"

print_subheader "Grouped by action type"

query_ch "
SELECT
    multiIf(
        name IN ('Tool: Read'), 'READ (understand)',
        name IN ('Tool: Grep', 'Tool: Glob'), 'SEARCH (find)',
        name IN ('Tool: Edit', 'Tool: Write'), 'WRITE (modify)',
        name IN ('Tool: Bash'), 'EXECUTE (run/test)',
        name IN ('Tool: WebSearch', 'Tool: WebFetch'), 'WEB (research)',
        name LIKE 'Tool: mcp%', 'MCP (external tools)',
        'OTHER'
    ) as category,
    count() as calls,
    round(count() * 100.0 / (
        SELECT count() FROM observations
        WHERE project_id = 'claude-code' AND is_deleted = 0 AND name LIKE 'Tool:%'
            $(tag_obs_where)
    ), 1) as pct
FROM observations
WHERE project_id = 'claude-code' AND is_deleted = 0 AND name LIKE 'Tool:%'
    $(tag_obs_where)
GROUP BY category
ORDER BY calls DESC
"

# --- 3. Session Turn Distribution ---
print_header "3. Session Turn Distribution"
print_subheader "How many turns do sessions typically last?"

query_ch "
WITH session_turns AS (
    SELECT session_id, count() as turns
    FROM traces
    WHERE project_id = 'claude-code' AND is_deleted = 0
        AND session_id IS NOT NULL AND session_id NOT LIKE 'historical-%'
        $(tag_where)
    GROUP BY session_id
)
SELECT
    multiIf(
        turns = 1, '1 turn',
        turns <= 3, '2-3 turns',
        turns <= 7, '4-7 turns',
        turns <= 12, '8-12 turns',
        '13+ turns'
    ) as bucket,
    count() as sessions,
    round(avg(turns), 1) as avg_turns_in_bucket
FROM session_turns
GROUP BY bucket
ORDER BY min(turns)
"

# --- 4. Productivity by Session Length ---
print_header "4. Productivity by Session Length"
print_subheader "Code changes per turn — does efficiency drop in longer sessions?"

query_ch "
WITH session_metrics AS (
    SELECT
        t.session_id,
        count(DISTINCT t.id) as turns,
        countIf(o.name = 'Tool: Edit') + countIf(o.name = 'Tool: Write') as changes,
        countIf(o.name = 'Tool: Read') as reads,
        countIf(o.name = 'Tool: Bash') as bashes
    FROM traces t
    LEFT JOIN observations o ON t.id = o.trace_id AND o.project_id = 'claude-code'
    WHERE t.project_id = 'claude-code' AND t.is_deleted = 0
        AND t.session_id IS NOT NULL AND t.session_id NOT LIKE 'historical-%'
        $(tag_where | sed 's/tags/t.tags/g')
    GROUP BY t.session_id
    HAVING turns > 1
)
SELECT
    multiIf(turns<=3,'2-3 turns',turns<=7,'4-7 turns',turns<=12,'8-12 turns','13+ turns') as bucket,
    count() as sessions,
    round(avg(changes), 1) as avg_code_changes,
    round(avg(reads), 1) as avg_reads,
    round(avg(bashes), 1) as avg_bashes,
    round(avg(changes) / avg(turns), 2) as changes_per_turn,
    round(avg(reads) / greatest(avg(changes), 0.1), 1) as read_to_write_ratio
FROM session_metrics
GROUP BY bucket
ORDER BY min(turns)
"

echo -e "  ${DIM}changes_per_turn = avg(Edit + Write) / avg(turns)${NC}"
echo -e "  ${DIM}read_to_write_ratio = avg(Read) / avg(Edit + Write)${NC}"
echo ""

# --- 5. Read-Before-Edit Pattern ---
print_header "5. Read-Before-Edit Pattern"
print_subheader "Do successful edits start with reading the file first?"

query_ch "
WITH trace_tools AS (
    SELECT
        trace_id,
        groupArray(name) as tools,
        has(tools, 'Tool: Read') as has_read,
        has(tools, 'Tool: Edit') as has_edit,
        has(tools, 'Tool: Write') as has_write,
        has(tools, 'Tool: Grep') as has_grep,
        length(tools) as tool_count
    FROM observations
    WHERE project_id = 'claude-code' AND is_deleted = 0 AND name LIKE 'Tool:%'
        $(tag_obs_where)
    GROUP BY trace_id
    HAVING tool_count >= 3
)
SELECT
    'Traces with Edit' as pattern,
    countIf(has_edit) as total,
    countIf(has_edit AND has_read) as with_read,
    round(countIf(has_edit AND has_read) * 100.0 / greatest(countIf(has_edit), 1), 1) as pct
FROM trace_tools

UNION ALL

SELECT
    'Traces with Write',
    countIf(has_write),
    countIf(has_write AND has_read),
    round(countIf(has_write AND has_read) * 100.0 / greatest(countIf(has_write), 1), 1)
FROM trace_tools

UNION ALL

SELECT
    'Exploration (Read+Grep) → Edit',
    countIf(has_read AND has_grep),
    countIf(has_read AND has_grep AND has_edit),
    round(countIf(has_read AND has_grep AND has_edit) * 100.0 / greatest(countIf(has_read AND has_grep), 1), 1)
FROM trace_tools
"

# --- Summary ---
if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD} Done.${NC} ${DIM}See docs/trace-analysis.md for interpretation guide.${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi
