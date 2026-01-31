#!/usr/bin/env bash
# Full integration test for claude-code-langfuse-template
#
# This script validates the complete setup process:
# 1. Environment generation
# 2. Docker Compose startup
# 3. Langfuse health checks
# 4. Hook functionality
#
# USAGE:
#   ./tests/test_full_integration.sh           # Run with standard ports
#   ./tests/test_full_integration.sh --isolated # Run with isolated ports (for CI)
#
# The --isolated flag uses non-standard ports to avoid conflicts with existing services.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_PROJECT="langfuse-integration-test"
ISOLATED_MODE=false
LANGFUSE_PORT=3050

# Parse arguments
for arg in "$@"; do
    case $arg in
        --isolated)
            ISOLATED_MODE=true
            LANGFUSE_PORT=3150
            shift
            ;;
    esac
done

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

warn() {
    echo -e "${YELLOW}WARN${NC}: $1"
}

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    cd "$REPO_DIR" 2>/dev/null || true

    if [[ "$ISOLATED_MODE" == true ]]; then
        docker compose -p "$COMPOSE_PROJECT" -f docker-compose.test.yml down -v 2>/dev/null || true
    else
        docker compose -p "$COMPOSE_PROJECT" down -v 2>/dev/null || true
    fi

    # Remove generated .env only if we created it
    if [[ -f .env.test-generated ]]; then
        rm -f .env .env.test-generated
    fi

    echo "Cleanup complete"
}

# Set up cleanup trap
trap cleanup EXIT

echo "=============================================="
echo "Claude Code Langfuse Template Integration Test"
echo "=============================================="
echo ""
echo "Repository: $REPO_DIR"
echo "Isolated mode: $ISOLATED_MODE"
echo "Langfuse port: $LANGFUSE_PORT"
echo ""

cd "$REPO_DIR"

# ==========================================
# Test 1: Syntax validation
# ==========================================
echo "=== Test 1: Syntax Validation ==="

if bash -n scripts/generate-env.sh 2>/dev/null; then
    pass "generate-env.sh syntax valid"
else
    fail "generate-env.sh syntax invalid"
fi

if bash -n scripts/install-hook.sh 2>/dev/null; then
    pass "install-hook.sh syntax valid"
else
    fail "install-hook.sh syntax invalid"
fi

if python3 -m py_compile hooks/langfuse_hook.py 2>/dev/null; then
    pass "langfuse_hook.py syntax valid"
else
    fail "langfuse_hook.py syntax invalid"
fi

if docker compose config > /dev/null 2>&1; then
    pass "docker-compose.yml valid"
else
    fail "docker-compose.yml invalid"
fi

# ==========================================
# Test 2: Environment generation
# ==========================================
echo ""
echo "=== Test 2: Environment Generation ==="

# Remove existing .env for clean test
rm -f .env

# Run generator with test inputs
if printf 'test@example.com\nTest User\ntestpass123\nTest Org\n' | ./scripts/generate-env.sh > /dev/null 2>&1; then
    pass "generate-env.sh executed successfully"
    touch .env.test-generated  # Mark that we created the .env
else
    fail "generate-env.sh failed"
fi

# Verify .env exists
if [[ -f .env ]]; then
    pass ".env file created"
else
    fail ".env file not created"
fi

# Verify critical variables are set
for var in POSTGRES_PASSWORD ENCRYPTION_KEY NEXTAUTH_SECRET LANGFUSE_INIT_PROJECT_SECRET_KEY; do
    val=$(grep "^$var=" .env 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "$val" && "$val" != "CHANGE_ME" ]]; then
        pass "$var is set"
    else
        fail "$var not properly set"
    fi
done

# Verify user-provided values
if grep -q "LANGFUSE_INIT_USER_EMAIL=test@example.com" .env 2>/dev/null; then
    pass "User email correctly set"
else
    fail "User email not set correctly"
fi

# ==========================================
# Test 3: Docker Compose startup
# ==========================================
echo ""
echo "=== Test 3: Docker Compose Startup ==="

COMPOSE_FILE="docker-compose.yml"
if [[ "$ISOLATED_MODE" == true ]]; then
    COMPOSE_FILE="docker-compose.test.yml"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        warn "docker-compose.test.yml not found, creating isolated config..."
        # Could generate it here, but for now just use standard
        COMPOSE_FILE="docker-compose.yml"
    fi
fi

echo "Starting Docker services..."
if docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d 2>&1 | tail -5; then
    pass "Docker Compose started"
else
    fail "Docker Compose failed to start"
fi

# Wait for services to be healthy
echo "Waiting for services to be healthy..."
sleep 10

# Check each service
SERVICES=("postgres" "redis" "clickhouse" "minio")
for svc in "${SERVICES[@]}"; do
    status=$(docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps --format json 2>/dev/null | jq -r ".[] | select(.Service == \"$svc\") | .Health" 2>/dev/null || echo "unknown")
    if [[ "$status" == "healthy" ]]; then
        pass "$svc is healthy"
    else
        warn "$svc health status: $status (may still be starting)"
    fi
done

# ==========================================
# Test 4: Langfuse health check
# ==========================================
echo ""
echo "=== Test 4: Langfuse Health Check ==="

# Wait additional time for Langfuse to initialize
echo "Waiting for Langfuse to initialize..."
max_attempts=30
attempt=0

while [[ $attempt -lt $max_attempts ]]; do
    response=$(curl -s "http://localhost:$LANGFUSE_PORT/api/public/health" 2>/dev/null || echo "")
    if echo "$response" | grep -q '"status":"OK"'; then
        pass "Langfuse API is healthy"
        break
    fi
    ((attempt++))
    sleep 2
done

if [[ $attempt -eq $max_attempts ]]; then
    fail "Langfuse API did not become healthy within timeout"
fi

# Check web UI responds
if curl -sI "http://localhost:$LANGFUSE_PORT" 2>/dev/null | grep -q "200 OK"; then
    pass "Langfuse web UI is accessible"
else
    fail "Langfuse web UI not accessible"
fi

# ==========================================
# Test 5: Hook functionality (if langfuse package available)
# ==========================================
echo ""
echo "=== Test 5: Hook Integration ==="

# Find a working Python with langfuse
PYTHON_CMD=""
for py in python3.12 python3.13 python3; do
    if command -v "$py" &>/dev/null; then
        if "$py" -c "import langfuse" 2>/dev/null; then
            PYTHON_CMD="$py"
            break
        fi
    fi
done

if [[ -n "$PYTHON_CMD" ]]; then
    pass "Python with langfuse found: $PYTHON_CMD"

    # Get secret key from .env
    SECRET_KEY=$(grep LANGFUSE_INIT_PROJECT_SECRET_KEY .env | cut -d= -f2)

    # Run integration test
    if LANGFUSE_HOST="http://localhost:$LANGFUSE_PORT" \
       LANGFUSE_PUBLIC_KEY="pk-lf-local-claude-code" \
       LANGFUSE_SECRET_KEY="$SECRET_KEY" \
       "$PYTHON_CMD" tests/test_hook_integration.py 2>&1 | tail -15; then
        pass "Hook integration tests passed"
    else
        fail "Hook integration tests failed"
    fi
else
    warn "Skipping hook tests - langfuse Python package not available"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo ""
echo "Tests run: $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
