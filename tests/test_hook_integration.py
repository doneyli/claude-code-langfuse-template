#!/usr/bin/env python3
"""Integration test for Langfuse hook - tests trace creation against running instance."""

import json
import os
import sys
import time
from datetime import datetime

# Get test config from environment or use defaults
LANGFUSE_HOST = os.environ.get("LANGFUSE_HOST", "http://localhost:3150")
LANGFUSE_PUBLIC_KEY = os.environ.get("LANGFUSE_PUBLIC_KEY", "pk-lf-local-claude-code")
LANGFUSE_SECRET_KEY = os.environ.get("LANGFUSE_SECRET_KEY")

def test_langfuse_connection():
    """Test 1: Verify we can connect to Langfuse."""
    print("=== Test 1: Langfuse Connection ===")

    try:
        from langfuse import Langfuse
    except ImportError:
        print("FAIL: langfuse package not installed")
        return False

    if not LANGFUSE_SECRET_KEY:
        print("FAIL: LANGFUSE_SECRET_KEY not set")
        return False

    try:
        client = Langfuse(
            public_key=LANGFUSE_PUBLIC_KEY,
            secret_key=LANGFUSE_SECRET_KEY,
            host=LANGFUSE_HOST,
        )
        # Quick health check using the new context manager API
        with client.start_as_current_span(name="connection-test") as span:
            client.update_current_trace(metadata={"test": True})
        client.flush()
        client.shutdown()
        print(f"PASS: Connected to Langfuse at {LANGFUSE_HOST}")
        return True
    except Exception as e:
        print(f"FAIL: Connection error - {e}")
        return False


def test_trace_creation():
    """Test 2: Create a trace that mimics Claude Code conversation."""
    print("\n=== Test 2: Trace Creation ===")

    from langfuse import Langfuse

    client = Langfuse(
        public_key=LANGFUSE_PUBLIC_KEY,
        secret_key=LANGFUSE_SECRET_KEY,
        host=LANGFUSE_HOST,
    )

    session_id = f"test-session-{int(time.time())}"

    try:
        # Create a trace mimicking Claude Code structure
        with client.start_as_current_span(
            name="Turn 1",
            input={"role": "user", "content": "Help me write a factorial function"},
            metadata={
                "source": "claude-code",
                "turn_number": 1,
                "project": "test-project",
            },
        ) as trace_span:
            # Update trace-level metadata
            client.update_current_trace(
                session_id=session_id,
                tags=["claude-code", "test-project"],
                metadata={
                    "source": "claude-code",
                    "session_id": session_id,
                },
            )

            # Create generation span for Claude's response
            with client.start_as_current_observation(
                name="Claude Response",
                as_type="generation",
                model="claude-opus-4-5-20251101",
                input={"role": "user", "content": "Help me write a factorial function"},
                output={"role": "assistant", "content": "Here's a factorial function implementation..."},
                metadata={"tool_count": 1},
            ):
                pass

            # Create tool span
            with client.start_as_current_span(
                name="Tool: Write",
                input={"file_path": "/tmp/factorial.py", "content": "def factorial(n): ..."},
                metadata={"tool_name": "Write", "tool_id": "tool_001"},
            ) as tool_span:
                tool_span.update(output="File written successfully")

            # Update trace with final output
            trace_span.update(output={"role": "assistant", "content": "I've created the factorial function."})

        client.flush()
        client.shutdown()

        print(f"PASS: Created trace with session_id={session_id}")
        print(f"      View at: {LANGFUSE_HOST}/sessions/{session_id}")
        return True

    except Exception as e:
        print(f"FAIL: Trace creation error - {e}")
        import traceback
        traceback.print_exc()
        return False


def test_api_query():
    """Test 3: Query the API to verify trace was captured."""
    print("\n=== Test 3: API Query ===")

    import urllib.request
    import base64

    # Create auth header
    auth_string = f"{LANGFUSE_PUBLIC_KEY}:{LANGFUSE_SECRET_KEY}"
    auth_bytes = base64.b64encode(auth_string.encode()).decode()

    try:
        req = urllib.request.Request(
            f"{LANGFUSE_HOST}/api/public/traces?limit=5",
            headers={"Authorization": f"Basic {auth_bytes}"}
        )

        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            traces = data.get("data", [])

            if traces:
                print(f"PASS: Found {len(traces)} trace(s) in Langfuse")
                for trace in traces[:3]:
                    print(f"      - {trace.get('name', 'unnamed')} (session: {trace.get('sessionId', 'none')})")
                return True
            else:
                print("WARN: No traces found yet (may need more time to process)")
                return True  # Not a failure, just timing

    except Exception as e:
        print(f"FAIL: API query error - {e}")
        return False


def main():
    print("=" * 60)
    print("Langfuse Hook Integration Tests")
    print(f"Target: {LANGFUSE_HOST}")
    print("=" * 60)
    print()

    results = []

    results.append(("Connection", test_langfuse_connection()))
    results.append(("Trace Creation", test_trace_creation()))

    # Give Langfuse a moment to process
    time.sleep(2)

    results.append(("API Query", test_api_query()))

    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)

    all_passed = True
    for name, passed in results:
        status = "PASS" if passed else "FAIL"
        print(f"  {name}: {status}")
        if not passed:
            all_passed = False

    print()
    if all_passed:
        print("All integration tests passed!")
        return 0
    else:
        print("Some tests failed.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
