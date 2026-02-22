#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track failures
FAILURES=0

print_header() {
    echo ""
    echo -e "${BLUE}====================================="
    echo "$1"
    echo -e "=====================================${NC}"
    echo ""
}

check_pass() {
    echo -e "${GREEN}✓ $1${NC}"
}

check_fail() {
    echo -e "${RED}✗ $1${NC}"
    FAILURES=$((FAILURES + 1))
}

check_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Parse flags
POST_MODE=false
CLOUD_MODE=false
for arg in "$@"; do
    case "$arg" in
        --post)  POST_MODE=true ;;
        --cloud) CLOUD_MODE=true ;;
    esac
done

if [ "$POST_MODE" = true ]; then
    if [ "$CLOUD_MODE" = true ]; then
        print_header "Post-Setup Validation (Cloud)"
        echo "Verifying that Langfuse Cloud is configured correctly..."
    else
        print_header "Post-Setup Validation"
        echo "Verifying that Langfuse is running and configured correctly..."
    fi
else
    if [ "$CLOUD_MODE" = true ]; then
        print_header "Pre-Flight Checks (Cloud)"
        echo "Verifying prerequisites for Langfuse Cloud setup..."
    else
        print_header "Pre-Flight Checks"
        echo "Verifying prerequisites before setup..."
    fi
fi

echo ""

# =============================================================================
# PRE-FLIGHT CHECKS (always run)
# =============================================================================

echo "Checking prerequisites..."
echo ""

# Docker checks — skip in cloud mode
if [ "$CLOUD_MODE" = false ]; then
    # Check Docker installed
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')
        check_pass "Docker installed (version $DOCKER_VERSION)"
    else
        check_fail "Docker not installed"
        echo "    Install from: https://docs.docker.com/get-docker/"
    fi

    # Check Docker daemon running
    if docker info &> /dev/null; then
        check_pass "Docker daemon running"
    else
        check_fail "Docker daemon not running"
        echo "    macOS: open -a Docker"
        echo "    Linux: sudo systemctl start docker"
    fi

    # Check Docker Compose
    if docker compose version &> /dev/null; then
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)
        check_pass "Docker Compose available (version $COMPOSE_VERSION)"
    else
        check_fail "Docker Compose not available"
        echo "    Docker Compose is included with Docker Desktop"
        echo "    Or install: https://docs.docker.com/compose/install/"
    fi
fi

# Check Python 3.11+
PYTHON=""
for cmd in python3.13 python3.12 python3.11 python3; do
    if command -v "$cmd" &> /dev/null; then
        VERSION=$($cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
        MAJOR=$(echo "$VERSION" | cut -d. -f1)
        MINOR=$(echo "$VERSION" | cut -d. -f2)
        if [ "$MAJOR" -eq 3 ] && [ "$MINOR" -ge 11 ]; then
            PYTHON=$cmd
            check_pass "Python $VERSION available ($cmd)"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    check_fail "Python 3.11+ not found"
    echo "    macOS: brew install python@3.12"
    echo "    Ubuntu: sudo apt install python3.12"
fi

# openssl check — skip in cloud mode
if [ "$CLOUD_MODE" = false ]; then
    if command -v openssl &> /dev/null; then
        OPENSSL_VERSION=$(openssl version 2>/dev/null | cut -d' ' -f2)
        check_pass "openssl available (version $OPENSSL_VERSION)"
    else
        check_fail "openssl not installed"
        echo "    macOS: brew install openssl"
        echo "    Ubuntu: sudo apt install openssl"
    fi
fi

# .env.example check — skip in cloud mode
if [ "$CLOUD_MODE" = false ]; then
    if [ -f .env.example ]; then
        check_pass ".env.example found"
    else
        check_warn ".env.example not found (are you in the repo directory?)"
    fi
fi

# Port checks only in pre-flight, non-cloud mode
if [ "$POST_MODE" = false ] && [ "$CLOUD_MODE" = false ]; then
    echo ""
    echo "Checking port availability..."
    echo ""

    # Check ports
    check_port() {
        local PORT=$1
        local SERVICE=$2
        if lsof -i ":$PORT" &> /dev/null; then
            check_fail "Port $PORT in use ($SERVICE)"
            echo "    Run: lsof -i :$PORT"
        else
            check_pass "Port $PORT available ($SERVICE)"
        fi
    }

    check_port 3050 "Langfuse Web"
    check_port 5433 "PostgreSQL"
    check_port 6379 "Redis"
    check_port 8124 "ClickHouse HTTP"
    check_port 9000 "MinIO"
fi

# =============================================================================
# POST-SETUP CHECKS (only with --post flag)
# =============================================================================

if [ "$POST_MODE" = true ]; then
    echo ""
    echo "Checking setup completion..."
    echo ""

    if [ "$CLOUD_MODE" = false ]; then
        # --- Self-hosted post checks ---

        # Check .env exists
        if [ -f .env ]; then
            check_pass ".env file exists"

            # Check if credentials are generated (not placeholder values)
            if grep -q "POSTGRES_PASSWORD=changeme" .env 2>/dev/null; then
                check_fail ".env has placeholder credentials (run ./scripts/generate-env.sh)"
            else
                check_pass ".env has generated credentials"
            fi
        else
            check_fail ".env file not found (run: cp .env.example .env && ./scripts/generate-env.sh)"
        fi

        echo ""
        echo "Checking Docker services..."
        echo ""

        # Check containers running (try docker compose first, fall back to docker ps)
        COMPOSE_RUNNING=$(docker compose ps 2>/dev/null | grep -E "Up|running" | wc -l | tr -d ' ' || echo "0")

        if [ "$COMPOSE_RUNNING" -ge 5 ] 2>/dev/null; then
            RUNNING=$COMPOSE_RUNNING
        else
            # Fallback: check for langfuse containers directly
            RUNNING=$(docker ps --filter "name=langfuse" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        fi

        if [ "$RUNNING" -ge 5 ]; then
            check_pass "Docker services running ($RUNNING containers)"
        else
            check_fail "Docker services not running (found $RUNNING, expected 6)"
            echo "    Run: docker compose up -d"
            echo "    Then wait 30-60 seconds for initialization"
        fi

        # Check container health
        UNHEALTHY_COMPOSE=$(docker compose ps 2>/dev/null | grep -c "unhealthy" || true)
        UNHEALTHY_DOCKER=$(docker ps --filter "name=langfuse" --format "{{.Status}}" 2>/dev/null | grep -c "unhealthy" || true)
        UNHEALTHY=$((UNHEALTHY_COMPOSE + UNHEALTHY_DOCKER))

        if [ "$UNHEALTHY" -eq 0 ]; then
            check_pass "All containers healthy"
        else
            check_warn "$UNHEALTHY container(s) unhealthy"
            echo "    Run: docker compose ps"
            echo "    Check logs: docker compose logs -f"
        fi

        # Check Langfuse API (self-hosted)
        echo ""
        echo "Checking Langfuse API..."
        echo ""

        if curl -s --max-time 5 http://localhost:3050/api/public/health 2>/dev/null | grep -qi "ok\|healthy"; then
            check_pass "Langfuse API responding"
        else
            check_fail "Langfuse API not responding"
            echo "    Wait 30-60 seconds after 'docker compose up -d'"
            echo "    Check: curl http://localhost:3050/api/public/health"
        fi
    else
        # --- Cloud post checks ---

        # Read LANGFUSE_HOST from settings.json
        SETTINGS_FILE="$HOME/.claude/settings.json"
        CLOUD_HOST=""
        if [ -f "$SETTINGS_FILE" ] && [ -n "$PYTHON" ]; then
            CLOUD_HOST=$($PYTHON -c "
import json, sys
try:
    with open('$SETTINGS_FILE') as f:
        s = json.load(f)
    print(s.get('env', {}).get('LANGFUSE_HOST', ''))
except Exception:
    pass
" 2>/dev/null || true)
        fi

        if [ -n "$CLOUD_HOST" ]; then
            check_pass "LANGFUSE_HOST configured: $CLOUD_HOST"
        else
            check_fail "LANGFUSE_HOST not found in settings.json"
            echo "    Run: ./scripts/install-hook.sh --cloud"
        fi

        # Check Langfuse Cloud API health
        echo ""
        echo "Checking Langfuse Cloud API..."
        echo ""

        if [ -n "$CLOUD_HOST" ]; then
            if curl -s --max-time 10 "$CLOUD_HOST/api/public/health" 2>/dev/null | grep -qi "ok\|healthy"; then
                check_pass "Langfuse Cloud API responding ($CLOUD_HOST)"
            else
                check_warn "Langfuse Cloud API not reachable ($CLOUD_HOST)"
                echo "    This may be a temporary network issue"
                echo "    Check: curl $CLOUD_HOST/api/public/health"
            fi
        fi
    fi

    echo ""
    echo "Checking hook installation..."
    echo ""

    # Check hook file
    HOOK_FILE="$HOME/.claude/hooks/langfuse_hook.py"
    if [ -f "$HOOK_FILE" ]; then
        check_pass "Hook file installed ($HOOK_FILE)"
    else
        check_fail "Hook file not found"
        if [ "$CLOUD_MODE" = true ]; then
            echo "    Run: ./scripts/install-hook.sh --cloud"
        else
            echo "    Run: ./scripts/install-hook.sh"
        fi
    fi

    # Check settings.json
    SETTINGS_FILE="$HOME/.claude/settings.json"
    if [ -f "$SETTINGS_FILE" ]; then
        check_pass "settings.json exists"

        # Check for Langfuse configuration
        if grep -q "LANGFUSE_PUBLIC_KEY" "$SETTINGS_FILE" 2>/dev/null; then
            check_pass "Langfuse keys configured in settings.json"
        else
            check_fail "Langfuse keys not found in settings.json"
            if [ "$CLOUD_MODE" = true ]; then
                echo "    Run: ./scripts/install-hook.sh --cloud"
            else
                echo "    Run: ./scripts/install-hook.sh"
            fi
        fi

        if grep -q "TRACE_TO_LANGFUSE" "$SETTINGS_FILE" 2>/dev/null; then
            if grep -q '"TRACE_TO_LANGFUSE": "true"' "$SETTINGS_FILE" 2>/dev/null; then
                check_pass "Tracing enabled (TRACE_TO_LANGFUSE=true)"
            else
                check_warn "Tracing may be disabled"
            fi
        else
            check_fail "TRACE_TO_LANGFUSE not set"
        fi

        # Check hook registration
        if grep -q "langfuse_hook.py" "$SETTINGS_FILE" 2>/dev/null; then
            check_pass "Hook registered in settings.json"
        else
            check_fail "Hook not registered in settings.json"
            if [ "$CLOUD_MODE" = true ]; then
                echo "    Run: ./scripts/install-hook.sh --cloud"
            else
                echo "    Run: ./scripts/install-hook.sh"
            fi
        fi
    else
        check_fail "settings.json not found"
        if [ "$CLOUD_MODE" = true ]; then
            echo "    Run: ./scripts/install-hook.sh --cloud"
        else
            echo "    Run: ./scripts/install-hook.sh"
        fi
    fi

    # Check langfuse package installed
    echo ""
    echo "Checking Python packages..."
    echo ""

    if [ -n "$PYTHON" ]; then
        if $PYTHON -c "import langfuse" 2>/dev/null; then
            LANGFUSE_VERSION=$($PYTHON -c "import langfuse; print(langfuse.__version__)" 2>/dev/null || echo "unknown")
            check_pass "langfuse package installed (version $LANGFUSE_VERSION)"
        else
            check_fail "langfuse package not installed"
            echo "    Run: $PYTHON -m pip install langfuse"
        fi
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

print_header "Summary"

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    if [ "$POST_MODE" = true ]; then
        if [ "$CLOUD_MODE" = true ]; then
            echo "Your Langfuse Cloud setup is ready to use."
            echo ""
            echo "Next steps:"
            echo "  1. Start a Claude Code conversation"
            echo "  2. Watch traces appear in your Langfuse Cloud dashboard"
        else
            echo "Your Langfuse setup is ready to use."
            echo ""
            echo "Next steps:"
            echo "  1. Open http://localhost:3050 in your browser"
            echo "  2. Log in with the credentials from your .env file"
            echo "  3. Start a Claude Code conversation"
            echo "  4. Watch traces appear in real-time!"
        fi
    else
        if [ "$CLOUD_MODE" = true ]; then
            echo "All prerequisites are met. You can proceed with cloud setup:"
            echo ""
            echo "  ./scripts/install-hook.sh --cloud"
            echo ""
            echo "After setup, run: ./scripts/validate-setup.sh --cloud --post"
        else
            echo "All prerequisites are met. You can proceed with setup:"
            echo ""
            echo "  cp .env.example .env"
            echo "  ./scripts/generate-env.sh"
            echo "  docker compose up -d"
            echo "  # Wait 30-60 seconds"
            echo "  ./scripts/install-hook.sh"
            echo ""
            echo "After setup, run: ./scripts/validate-setup.sh --post"
        fi
    fi
else
    echo -e "${RED}$FAILURES check(s) failed${NC}"
    echo ""
    echo "Please fix the issues above before continuing."
    if [ "$POST_MODE" = false ]; then
        if [ "$CLOUD_MODE" = true ]; then
            echo "Re-run this script after fixing: ./scripts/validate-setup.sh --cloud"
        else
            echo "Re-run this script after fixing: ./scripts/validate-setup.sh"
        fi
    fi
fi

echo ""
exit $FAILURES
