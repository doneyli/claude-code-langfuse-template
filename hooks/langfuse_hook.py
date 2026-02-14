#!/usr/bin/env python3.12
"""
Sends Claude Code traces to Langfuse after each response.

Hook type: Stop (runs after each assistant response)
Opt-in: Only runs when TRACE_TO_LANGFUSE=true is set in project settings.

Resilience: If Langfuse is unavailable, traces are queued locally and
automatically drained on the next successful connection.
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import socket

# Check if Langfuse is available
try:
    from langfuse import Langfuse
except ImportError:
    print("Error: langfuse package not installed. Run: pip install langfuse", file=sys.stderr)
    sys.exit(0)

# Configuration
LOG_FILE = Path.home() / ".claude" / "state" / "langfuse_hook.log"
STATE_FILE = Path.home() / ".claude" / "state" / "langfuse_state.json"
QUEUE_FILE = Path.home() / ".claude" / "state" / "pending_traces.jsonl"
DEBUG = os.environ.get("CC_LANGFUSE_DEBUG", "").lower() == "true"
HEALTH_CHECK_TIMEOUT = 2  # seconds


def log(level: str, message: str) -> None:
    """Log a message to the log file."""
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"{timestamp} [{level}] {message}\n")


def debug(message: str) -> None:
    """Log a debug message (only if DEBUG is enabled)."""
    if DEBUG:
        log("DEBUG", message)


def check_langfuse_health(host: str) -> bool:
    """Quick health check to see if Langfuse is reachable.

    Uses socket connection to avoid slow HTTP timeouts.
    """
    try:
        # Parse host to get hostname and port
        if host.startswith("http://"):
            host_part = host[7:]
            default_port = 80
        elif host.startswith("https://"):
            host_part = host[8:]
            default_port = 443
        else:
            host_part = host
            default_port = 443

        if ":" in host_part:
            hostname, port_str = host_part.split(":", 1)
            port = int(port_str.rstrip("/"))
        else:
            hostname = host_part.rstrip("/")
            port = default_port

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(HEALTH_CHECK_TIMEOUT)
        result = sock.connect_ex((hostname, port))
        sock.close()

        is_healthy = result == 0
        debug(f"Health check for {hostname}:{port} - {'OK' if is_healthy else 'FAILED'}")
        return is_healthy
    except Exception as e:
        debug(f"Health check error: {e}")
        return False


def queue_trace(trace_data: dict) -> None:
    """Append a trace to the local queue file."""
    QUEUE_FILE.parent.mkdir(parents=True, exist_ok=True)
    trace_data["queued_at"] = datetime.now(timezone.utc).isoformat()
    with open(QUEUE_FILE, "a") as f:
        f.write(json.dumps(trace_data) + "\n")
    log("INFO", f"Queued trace for session {trace_data.get('session_id', 'unknown')}, turn {trace_data.get('turn_num', '?')}")


def load_queued_traces() -> list[dict]:
    """Load all pending traces from the queue file."""
    if not QUEUE_FILE.exists():
        return []

    traces = []
    try:
        with open(QUEUE_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    traces.append(json.loads(line))
    except (json.JSONDecodeError, IOError) as e:
        log("ERROR", f"Failed to load queue: {e}")
        return []

    return traces


def clear_queue() -> None:
    """Clear the queue file after successful drain."""
    if QUEUE_FILE.exists():
        QUEUE_FILE.unlink()
        debug("Queue cleared")


def drain_queue(langfuse: Langfuse) -> int:
    """Drain all queued traces to Langfuse. Returns count of drained traces."""
    traces = load_queued_traces()
    if not traces:
        return 0

    log("INFO", f"Draining {len(traces)} queued traces to Langfuse")

    drained = 0
    for trace_data in traces:
        try:
            create_trace(
                langfuse=langfuse,
                session_id=trace_data["session_id"],
                turn_num=trace_data["turn_num"],
                user_msg=trace_data["user_msg"],
                assistant_msgs=trace_data["assistant_msgs"],
                tool_results=trace_data["tool_results"],
                project_name=trace_data.get("project_name", ""),
            )
            drained += 1
        except Exception as e:
            log("ERROR", f"Failed to drain trace: {e}")
            # If we fail mid-drain, rewrite remaining traces and exit
            remaining = traces[drained:]
            clear_queue()
            for remaining_trace in remaining:
                queue_trace(remaining_trace)
            return drained

    clear_queue()
    log("INFO", f"Successfully drained {drained} traces")
    return drained


def load_state() -> dict:
    """Load the state file containing session tracking info."""
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except (json.JSONDecodeError, IOError):
        return {}


def save_state(state: dict) -> None:
    """Save the state file."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def get_content(msg: dict) -> Any:
    """Extract content from a message."""
    if isinstance(msg, dict):
        if "message" in msg:
            return msg["message"].get("content")
        return msg.get("content")
    return None


def is_tool_result(msg: dict) -> bool:
    """Check if a message contains tool results."""
    content = get_content(msg)
    if isinstance(content, list):
        return any(
            isinstance(item, dict) and item.get("type") == "tool_result"
            for item in content
        )
    return False


def get_tool_calls(msg: dict) -> list:
    """Extract tool use blocks from a message."""
    content = get_content(msg)
    if isinstance(content, list):
        return [
            item for item in content
            if isinstance(item, dict) and item.get("type") == "tool_use"
        ]
    return []


def get_text_content(msg: dict) -> str:
    """Extract text content from a message."""
    content = get_content(msg)
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        text_parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text_parts.append(item.get("text", ""))
            elif isinstance(item, str):
                text_parts.append(item)
        return "\n".join(text_parts)
    return ""


def merge_assistant_parts(parts: list) -> dict:
    """Merge multiple assistant message parts into one."""
    if not parts:
        return {}

    merged_content = []
    for part in parts:
        content = get_content(part)
        if isinstance(content, list):
            merged_content.extend(content)
        elif content:
            merged_content.append({"type": "text", "text": str(content)})

    # Use the structure from the first part
    result = parts[0].copy()
    if "message" in result:
        result["message"] = result["message"].copy()
        result["message"]["content"] = merged_content
    else:
        result["content"] = merged_content

    return result


def extract_project_name(project_dir: Path) -> str:
    """Extract a human-readable project name from the Claude projects directory name.

    Directory names look like: -Users-doneyli-djg-family-office
    We extract the last segment as the project name.
    """
    dir_name = project_dir.name
    # Split on the path-encoded dashes and take the last non-empty segment
    parts = dir_name.split("-")
    # Rebuild: find the last meaningful project name
    # Pattern: -Users-<user>-<project-name> or -Users-<user>-<path>-<project-name>
    # Take everything after the username (3rd segment onward)
    if len(parts) > 3:
        # parts[0] is empty (leading dash), parts[1] is "Users", parts[2] is username
        project_parts = parts[3:]
        return "-".join(project_parts)
    return dir_name


def find_latest_transcript() -> tuple[str, Path, str] | None:
    """Find the most recently modified transcript file.

    Claude Code stores transcripts as *.jsonl files directly in the project directory.
    Main conversation files have UUID names, agent files have agent-*.jsonl names.
    The session ID is stored inside each JSON line.

    Returns: (session_id, transcript_path, project_name) or None
    """
    projects_dir = Path.home() / ".claude" / "projects"

    if not projects_dir.exists():
        debug(f"Projects directory not found: {projects_dir}")
        return None

    latest_file = None
    latest_mtime = 0
    latest_project_dir = None

    for project_dir in projects_dir.iterdir():
        if not project_dir.is_dir():
            continue

        # Look for all .jsonl files directly in the project directory
        for transcript_file in project_dir.glob("*.jsonl"):
            mtime = transcript_file.stat().st_mtime
            if mtime > latest_mtime:
                latest_mtime = mtime
                latest_file = transcript_file
                latest_project_dir = project_dir

    if latest_file and latest_project_dir:
        # Extract session ID from the first line of the file
        try:
            first_line = latest_file.read_text().split("\n")[0]
            first_msg = json.loads(first_line)
            session_id = first_msg.get("sessionId", latest_file.stem)
            project_name = extract_project_name(latest_project_dir)
            debug(f"Found transcript: {latest_file}, session: {session_id}, project: {project_name}")
            return (session_id, latest_file, project_name)
        except (json.JSONDecodeError, IOError, IndexError) as e:
            debug(f"Error reading transcript {latest_file}: {e}")
            return None

    debug("No transcript files found")
    return None


def find_modified_transcripts(state: dict, max_sessions: int = 10) -> list[tuple[str, Path, str]]:
    """Find all transcripts that have been modified since their last state update.

    Returns up to max_sessions transcripts, sorted by modification time (most recent first).
    This ensures we don't miss sessions when multiple are active concurrently.

    Returns: list of (session_id, transcript_path, project_name) tuples
    """
    projects_dir = Path.home() / ".claude" / "projects"

    if not projects_dir.exists():
        debug(f"Projects directory not found: {projects_dir}")
        return []

    modified_transcripts = []

    for project_dir in projects_dir.iterdir():
        if not project_dir.is_dir():
            continue

        project_name = extract_project_name(project_dir)

        # Look for all .jsonl files directly in the project directory
        for transcript_file in project_dir.glob("*.jsonl"):
            # Skip subagent transcripts (they're in subdirectories and caught by glob **)
            if "subagents" in str(transcript_file):
                continue

            try:
                # Get file modification time
                mtime = transcript_file.stat().st_mtime

                # Extract session ID from the first line
                first_line = transcript_file.read_text().split("\n")[0]
                first_msg = json.loads(first_line)
                session_id = first_msg.get("sessionId", transcript_file.stem)

                # Check if this session has been modified since last update
                session_state = state.get(session_id, {})
                last_update = session_state.get("updated", "1970-01-01T00:00:00+00:00")
                last_update_timestamp = datetime.fromisoformat(last_update).timestamp()

                # If file modified after last state update, it needs processing
                if mtime > last_update_timestamp:
                    modified_transcripts.append({
                        "session_id": session_id,
                        "transcript_file": transcript_file,
                        "project_name": project_name,
                        "mtime": mtime,
                    })
                    debug(f"Found modified session: {session_id} (project: {project_name})")
            except (json.JSONDecodeError, IOError, IndexError) as e:
                debug(f"Error reading transcript {transcript_file}: {e}")
                continue

    # Sort by modification time (most recent first) and limit
    modified_transcripts.sort(key=lambda x: x["mtime"], reverse=True)
    result = [
        (t["session_id"], t["transcript_file"], t["project_name"])
        for t in modified_transcripts[:max_sessions]
    ]

    debug(f"Found {len(result)} modified transcripts (out of {len(modified_transcripts)} total)")
    return result


def queue_turns_from_messages(
    messages: list,
    session_id: str,
    turn_count: int,
    project_name: str,
) -> int:
    """Parse messages into turns and queue them locally. Returns number of turns queued."""
    turns = 0
    current_user = None
    current_assistants = []
    current_assistant_parts = []
    current_msg_id = None
    current_tool_results = []

    for msg in messages:
        role = msg.get("type") or (msg.get("message", {}).get("role"))

        if role == "user":
            if is_tool_result(msg):
                current_tool_results.append(msg)
                continue

            # New user message - finalize previous turn
            if current_msg_id and current_assistant_parts:
                merged = merge_assistant_parts(current_assistant_parts)
                current_assistants.append(merged)
                current_assistant_parts = []
                current_msg_id = None

            if current_user and current_assistants:
                turns += 1
                turn_num = turn_count + turns
                queue_trace({
                    "session_id": session_id,
                    "turn_num": turn_num,
                    "user_msg": current_user,
                    "assistant_msgs": current_assistants,
                    "tool_results": current_tool_results,
                    "project_name": project_name,
                })

            current_user = msg
            current_assistants = []
            current_assistant_parts = []
            current_msg_id = None
            current_tool_results = []

        elif role == "assistant":
            msg_id = None
            if isinstance(msg, dict) and "message" in msg:
                msg_id = msg["message"].get("id")

            if not msg_id:
                current_assistant_parts.append(msg)
            elif msg_id == current_msg_id:
                current_assistant_parts.append(msg)
            else:
                if current_msg_id and current_assistant_parts:
                    merged = merge_assistant_parts(current_assistant_parts)
                    current_assistants.append(merged)
                current_msg_id = msg_id
                current_assistant_parts = [msg]

    # Process final turn
    if current_msg_id and current_assistant_parts:
        merged = merge_assistant_parts(current_assistant_parts)
        current_assistants.append(merged)

    if current_user and current_assistants:
        turns += 1
        turn_num = turn_count + turns
        queue_trace({
            "session_id": session_id,
            "turn_num": turn_num,
            "user_msg": current_user,
            "assistant_msgs": current_assistants,
            "tool_results": current_tool_results,
            "project_name": project_name,
        })

    return turns


def create_trace(
    langfuse: Langfuse,
    session_id: str,
    turn_num: int,
    user_msg: dict,
    assistant_msgs: list,
    tool_results: list,
    project_name: str = "",
) -> None:
    """Create a Langfuse trace for a single turn using the new SDK API."""
    # Extract user text
    user_text = get_text_content(user_msg)

    # Extract final assistant text
    final_output = ""
    if assistant_msgs:
        final_output = get_text_content(assistant_msgs[-1])

    # Get model info from first assistant message
    model = "claude"
    if assistant_msgs and isinstance(assistant_msgs[0], dict) and "message" in assistant_msgs[0]:
        model = assistant_msgs[0]["message"].get("model", "claude")

    # Collect all tool calls and results
    all_tool_calls = []
    for assistant_msg in assistant_msgs:
        tool_calls = get_tool_calls(assistant_msg)
        for tool_call in tool_calls:
            tool_name = tool_call.get("name", "unknown")
            tool_input = tool_call.get("input", {})
            tool_id = tool_call.get("id", "")

            # Find matching tool result
            tool_output = None
            for tr in tool_results:
                tr_content = get_content(tr)
                if isinstance(tr_content, list):
                    for item in tr_content:
                        if isinstance(item, dict) and item.get("tool_use_id") == tool_id:
                            tool_output = item.get("content")
                            break

            all_tool_calls.append({
                "name": tool_name,
                "input": tool_input,
                "output": tool_output,
                "id": tool_id,
            })

    # Build tags list
    tags = ["claude-code"]
    if project_name:
        tags.append(project_name)

    # Create root span (implicitly creates a trace), then set trace-level attributes
    with langfuse.start_as_current_span(
        name=f"Turn {turn_num}",
        input={"role": "user", "content": user_text},
        metadata={
            "source": "claude-code",
            "turn_number": turn_num,
            "project": project_name,
        },
    ) as trace_span:
        # Set session_id and tags on the underlying trace
        langfuse.update_current_trace(
            session_id=session_id,
            tags=tags,
            metadata={
                "source": "claude-code",
                "turn_number": turn_num,
                "session_id": session_id,
                "project": project_name,
            },
        )

        # Create generation for the LLM response
        with langfuse.start_as_current_observation(
            name="Claude Response",
            as_type="generation",
            model=model,
            input={"role": "user", "content": user_text},
            output={"role": "assistant", "content": final_output},
            metadata={
                "tool_count": len(all_tool_calls),
            },
        ):
            pass

        # Create spans for tool calls
        for tool_call in all_tool_calls:
            with langfuse.start_as_current_span(
                name=f"Tool: {tool_call['name']}",
                input=tool_call["input"],
                metadata={
                    "tool_name": tool_call["name"],
                    "tool_id": tool_call["id"],
                },
            ) as tool_span:
                tool_span.update(output=tool_call["output"])
            debug(f"Created span for tool: {tool_call['name']}")

        # Update trace with output
        trace_span.update(output={"role": "assistant", "content": final_output})

    debug(f"Created trace for turn {turn_num}")


def process_transcript(langfuse: Langfuse, session_id: str, transcript_file: Path, state: dict, project_name: str = "") -> int:
    """Process a transcript file and create traces for new turns."""
    # Get previous state for this session
    session_state = state.get(session_id, {})
    last_line = session_state.get("last_line", 0)
    turn_count = session_state.get("turn_count", 0)

    # Read transcript
    lines = transcript_file.read_text().strip().split("\n")
    total_lines = len(lines)

    if last_line >= total_lines:
        debug(f"No new lines to process (last: {last_line}, total: {total_lines})")
        return 0

    # Parse new messages
    new_messages = []
    for i in range(last_line, total_lines):
        try:
            msg = json.loads(lines[i])
            new_messages.append(msg)
        except json.JSONDecodeError:
            continue

    if not new_messages:
        return 0

    debug(f"Processing {len(new_messages)} new messages")

    # Group messages into turns (user -> assistant(s) -> tool_results)
    turns = 0
    current_user = None
    current_assistants = []
    current_assistant_parts = []
    current_msg_id = None
    current_tool_results = []

    for msg in new_messages:
        role = msg.get("type") or (msg.get("message", {}).get("role"))

        if role == "user":
            # Check if this is a tool result
            if is_tool_result(msg):
                current_tool_results.append(msg)
                continue

            # New user message - finalize previous turn
            if current_msg_id and current_assistant_parts:
                merged = merge_assistant_parts(current_assistant_parts)
                current_assistants.append(merged)
                current_assistant_parts = []
                current_msg_id = None

            if current_user and current_assistants:
                turns += 1
                turn_num = turn_count + turns
                create_trace(langfuse, session_id, turn_num, current_user, current_assistants, current_tool_results, project_name)

            # Start new turn
            current_user = msg
            current_assistants = []
            current_assistant_parts = []
            current_msg_id = None
            current_tool_results = []

        elif role == "assistant":
            msg_id = None
            if isinstance(msg, dict) and "message" in msg:
                msg_id = msg["message"].get("id")

            if not msg_id:
                # No message ID, treat as continuation
                current_assistant_parts.append(msg)
            elif msg_id == current_msg_id:
                # Same message ID, add to current parts
                current_assistant_parts.append(msg)
            else:
                # New message ID - finalize previous message
                if current_msg_id and current_assistant_parts:
                    merged = merge_assistant_parts(current_assistant_parts)
                    current_assistants.append(merged)

                # Start new assistant message
                current_msg_id = msg_id
                current_assistant_parts = [msg]

    # Process final turn
    if current_msg_id and current_assistant_parts:
        merged = merge_assistant_parts(current_assistant_parts)
        current_assistants.append(merged)

    if current_user and current_assistants:
        turns += 1
        turn_num = turn_count + turns
        create_trace(langfuse, session_id, turn_num, current_user, current_assistants, current_tool_results, project_name)

    # Update state
    state[session_id] = {
        "last_line": total_lines,
        "turn_count": turn_count + turns,
        "updated": datetime.now(timezone.utc).isoformat(),
    }
    save_state(state)

    return turns


def main():
    script_start = datetime.now()
    debug("Hook started")

    # Check if tracing is enabled
    if os.environ.get("TRACE_TO_LANGFUSE", "").lower() != "true":
        debug("Tracing disabled (TRACE_TO_LANGFUSE != true)")
        sys.exit(0)

    # Check for required environment variables
    public_key = os.environ.get("CC_LANGFUSE_PUBLIC_KEY") or os.environ.get("LANGFUSE_PUBLIC_KEY")
    secret_key = os.environ.get("CC_LANGFUSE_SECRET_KEY") or os.environ.get("LANGFUSE_SECRET_KEY")
    host = os.environ.get("CC_LANGFUSE_HOST") or os.environ.get("LANGFUSE_HOST", "https://cloud.langfuse.com")

    if not public_key or not secret_key:
        log("ERROR", "Langfuse API keys not set (CC_LANGFUSE_PUBLIC_KEY / CC_LANGFUSE_SECRET_KEY)")
        sys.exit(0)

    # Load state
    state = load_state()

    # Find all modified transcripts (up to 10 most recent)
    modified_transcripts = find_modified_transcripts(state, max_sessions=10)

    if not modified_transcripts:
        debug("No modified transcripts found")
        sys.exit(0)

    debug(f"Found {len(modified_transcripts)} modified session(s) to process")

    # Check if Langfuse is reachable
    langfuse_available = check_langfuse_health(host)

    if not langfuse_available:
        # Queue all modified sessions
        log("WARN", f"Langfuse unavailable at {host}, queuing traces locally")

        total_turns_queued = 0
        for session_id, transcript_file, project_name in modified_transcripts:
            # Get previous state for this session
            session_state = state.get(session_id, {})
            last_line = session_state.get("last_line", 0)
            turn_count = session_state.get("turn_count", 0)

            # Read transcript
            try:
                lines = transcript_file.read_text().strip().split("\n")
                total_lines = len(lines)

                if last_line >= total_lines:
                    continue

                # Parse new messages and queue turns
                new_messages = []
                for i in range(last_line, total_lines):
                    try:
                        msg = json.loads(lines[i])
                        new_messages.append(msg)
                    except json.JSONDecodeError:
                        continue

                if new_messages:
                    turns_queued = queue_turns_from_messages(
                        new_messages, session_id, turn_count, project_name
                    )
                    total_turns_queued += turns_queued

                    # Update state even when queuing
                    state[session_id] = {
                        "last_line": total_lines,
                        "turn_count": turn_count + turns_queued,
                        "updated": datetime.now(timezone.utc).isoformat(),
                    }
            except Exception as e:
                debug(f"Error queuing session {session_id}: {e}")
                continue

        save_state(state)
        duration = (datetime.now() - script_start).total_seconds()
        log("INFO", f"Queued {total_turns_queued} turns from {len(modified_transcripts)} sessions in {duration:.1f}s")
        sys.exit(0)

    # Langfuse is available - initialize client
    try:
        langfuse = Langfuse(
            public_key=public_key,
            secret_key=secret_key,
            host=host,
        )
    except Exception as e:
        log("ERROR", f"Failed to initialize Langfuse client: {e}")
        sys.exit(0)

    try:
        # First, drain any queued traces
        drained = drain_queue(langfuse)
        if drained > 0:
            langfuse.flush()

        # Process all modified transcripts
        total_turns = 0
        for session_id, transcript_file, project_name in modified_transcripts:
            try:
                turns = process_transcript(langfuse, session_id, transcript_file, state, project_name)
                total_turns += turns
                debug(f"Processed {turns} turns from session {session_id}")
            except Exception as e:
                log("ERROR", f"Failed to process session {session_id}: {e}")
                import traceback
                debug(traceback.format_exc())
                continue

        # Flush to ensure all data is sent
        langfuse.flush()

        # Log execution time
        duration = (datetime.now() - script_start).total_seconds()
        log("INFO", f"Processed {total_turns} turns from {len(modified_transcripts)} sessions (drained {drained} from queue) in {duration:.1f}s")

        if duration > 180:
            log("WARN", f"Hook took {duration:.1f}s (>3min), consider optimizing")

    except Exception as e:
        log("ERROR", f"Failed to process transcripts: {e}")
        import traceback
        debug(traceback.format_exc())
    finally:
        langfuse.shutdown()

    sys.exit(0)


if __name__ == "__main__":
    main()
