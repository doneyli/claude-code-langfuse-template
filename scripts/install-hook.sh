#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse flags
CLOUD_MODE=false
if [[ "${1:-}" == "--cloud" ]]; then
    CLOUD_MODE=true
fi

echo "====================================="
echo "Claude Code Langfuse Hook Installer"
if [ "$CLOUD_MODE" = true ]; then
    echo "  (Langfuse Cloud mode)"
fi
echo "====================================="
echo ""

if [ "$CLOUD_MODE" = true ]; then
    # --- Cloud mode: prompt for credentials interactively ---
    echo "Setting up Langfuse Cloud integration."
    echo ""

    # Prompt for public key
    read -rp "Enter your Langfuse public key (pk-lf-...): " LANGFUSE_PUBLIC_KEY
    if [[ -z "$LANGFUSE_PUBLIC_KEY" ]]; then
        echo -e "${RED}Error: Public key cannot be empty${NC}"
        exit 1
    fi
    if [[ ! "$LANGFUSE_PUBLIC_KEY" =~ ^pk-lf- ]]; then
        echo -e "${RED}Error: Public key must start with 'pk-lf-'${NC}"
        exit 1
    fi

    # Prompt for secret key
    read -rp "Enter your Langfuse secret key (sk-lf-...): " LANGFUSE_SECRET_KEY
    if [[ -z "$LANGFUSE_SECRET_KEY" ]]; then
        echo -e "${RED}Error: Secret key cannot be empty${NC}"
        exit 1
    fi
    if [[ ! "$LANGFUSE_SECRET_KEY" =~ ^sk-lf- ]]; then
        echo -e "${RED}Error: Secret key must start with 'sk-lf-'${NC}"
        exit 1
    fi

    # Prompt for region
    echo ""
    echo "Choose your Langfuse region:"
    echo "  1) EU  (cloud.langfuse.com)"
    echo "  2) US  (us.cloud.langfuse.com)"
    echo "  3) Custom URL"
    read -rp "Selection [1]: " REGION_CHOICE
    REGION_CHOICE="${REGION_CHOICE:-1}"

    case "$REGION_CHOICE" in
        1)
            LANGFUSE_HOST="https://cloud.langfuse.com"
            ;;
        2)
            LANGFUSE_HOST="https://us.cloud.langfuse.com"
            ;;
        3)
            read -rp "Enter your Langfuse URL (e.g. https://my-langfuse.example.com): " LANGFUSE_HOST
            if [[ -z "$LANGFUSE_HOST" ]]; then
                echo -e "${RED}Error: URL cannot be empty${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}Error: Invalid selection${NC}"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}✓ Cloud credentials configured${NC}"
    echo "  Host: $LANGFUSE_HOST"
    echo "  Public Key: $LANGFUSE_PUBLIC_KEY"
    echo ""

else
    # --- Self-hosted mode: read from .env ---
    # Check if .env exists
    if [ ! -f .env ]; then
        echo -e "${RED}Error: .env file not found${NC}"
        echo "Please run ./scripts/generate-env.sh first"
        echo ""
        echo "Or use --cloud for Langfuse Cloud: ./scripts/install-hook.sh --cloud"
        exit 1
    fi

    # Extract credentials from .env (safer than source - avoids code injection)
    get_env_value() {
        grep "^$1=" .env 2>/dev/null | cut -d= -f2- | head -1
    }

    LANGFUSE_PUBLIC_KEY=$(get_env_value "LANGFUSE_INIT_PROJECT_PUBLIC_KEY")
    LANGFUSE_SECRET_KEY=$(get_env_value "LANGFUSE_INIT_PROJECT_SECRET_KEY")
    LANGFUSE_HOST="http://localhost:3050"

    if [ -z "$LANGFUSE_PUBLIC_KEY" ] || [ -z "$LANGFUSE_SECRET_KEY" ]; then
        echo -e "${RED}Error: Could not read API keys from .env${NC}"
        echo "Ensure LANGFUSE_INIT_PROJECT_PUBLIC_KEY and LANGFUSE_INIT_PROJECT_SECRET_KEY are set"
        exit 1
    fi
fi

# Find Python 3.11+
PYTHON=""
for cmd in python3.13 python3.12 python3.11 python3; do
    if command -v "$cmd" &> /dev/null; then
        VERSION=$($cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        MAJOR=$(echo $VERSION | cut -d. -f1)
        MINOR=$(echo $VERSION | cut -d. -f2)
        if [ "$MAJOR" -eq 3 ] && [ "$MINOR" -ge 11 ]; then
            PYTHON=$cmd
            echo -e "${GREEN}✓ Found Python $VERSION at $cmd${NC}"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo -e "${RED}Error: Python 3.11 or higher is required${NC}"
    echo "Please install Python 3.11+ and try again"
    echo ""
    echo "Installation options:"
    echo "  macOS: brew install python@3.12"
    echo "  Ubuntu/Debian: sudo apt install python3.12"
    echo "  Or use pyenv: pyenv install 3.12"
    exit 1
fi

# Install langfuse package
echo ""
echo "Installing langfuse Python package..."
$PYTHON -m pip install --quiet --upgrade pip
$PYTHON -m pip install --quiet langfuse

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Installed langfuse package${NC}"
else
    echo -e "${RED}Error: Failed to install langfuse package${NC}"
    exit 1
fi

# Create hooks directory
HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
echo -e "${GREEN}✓ Created hooks directory: $HOOKS_DIR${NC}"

# Copy hook script
HOOK_SOURCE="hooks/langfuse_hook.py"
HOOK_DEST="$HOOKS_DIR/langfuse_hook.py"

if [ ! -f "$HOOK_SOURCE" ]; then
    echo -e "${RED}Error: Hook source file not found: $HOOK_SOURCE${NC}"
    echo "Please run this script from the repository root"
    exit 1
fi

cp "$HOOK_SOURCE" "$HOOK_DEST"
chmod +x "$HOOK_DEST"
echo -e "${GREEN}✓ Installed hook script: $HOOK_DEST${NC}"

# Update settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
SETTINGS_DIR="$(dirname "$SETTINGS_FILE")"

mkdir -p "$SETTINGS_DIR"

# Check if settings.json exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo -e "${YELLOW}Creating new settings.json${NC}"
    cat > "$SETTINGS_FILE" << 'EOF'
{
  "env": {},
  "hooks": {}
}
EOF
fi

# Read existing settings
SETTINGS_CONTENT=$(cat "$SETTINGS_FILE")

# Use Python to update JSON (more reliable than jq)
$PYTHON << EOF
import json
import sys

# Read current settings
with open("$SETTINGS_FILE", "r") as f:
    settings = json.load(f)

# Ensure env and hooks sections exist
if "env" not in settings:
    settings["env"] = {}
if "hooks" not in settings:
    settings["hooks"] = {}

# Add environment variables
settings["env"]["TRACE_TO_LANGFUSE"] = "true"
settings["env"]["LANGFUSE_PUBLIC_KEY"] = "$LANGFUSE_PUBLIC_KEY"
settings["env"]["LANGFUSE_SECRET_KEY"] = "$LANGFUSE_SECRET_KEY"
settings["env"]["LANGFUSE_HOST"] = "$LANGFUSE_HOST"

# Add Stop hook if not already present
if "Stop" not in settings["hooks"]:
    settings["hooks"]["Stop"] = []

# Check if hook already registered
hook_command = "$PYTHON $HOOK_DEST"
hook_exists = False
for hook_group in settings["hooks"]["Stop"]:
    if "hooks" in hook_group:
        for hook in hook_group["hooks"]:
            if hook.get("type") == "command" and "$HOOK_DEST" in hook.get("command", ""):
                hook_exists = True
                break

if not hook_exists:
    settings["hooks"]["Stop"].append({
        "hooks": [
            {
                "type": "command",
                "command": hook_command
            }
        ]
    })

# Write updated settings
with open("$SETTINGS_FILE", "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("Updated settings.json")
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Updated Claude Code settings: $SETTINGS_FILE${NC}"
else
    echo -e "${RED}Error: Failed to update settings.json${NC}"
    exit 1
fi

echo ""
echo "====================================="
echo "Installation Complete!"
echo "====================================="
echo ""
echo "Configuration:"
echo "  Hook: $HOOK_DEST"
echo "  Settings: $SETTINGS_FILE"
echo "  Host: $LANGFUSE_HOST"
echo "  Public Key: $LANGFUSE_PUBLIC_KEY"
echo ""

if [ "$CLOUD_MODE" = true ]; then
    echo "Verification steps:"
    echo "  1. Start a Claude Code conversation"
    echo "  2. Check traces at $LANGFUSE_HOST"
    echo ""
    echo "Optional: Run validation"
    echo "  ./scripts/validate-setup.sh --cloud --post"
else
    echo "Verification steps:"
    echo "  1. Ensure Docker is running"
    echo "  2. Start Langfuse: docker compose up -d"
    echo "  3. Wait 30-60 seconds for services to initialize"
    echo "  4. Start a Claude Code conversation"
    echo "  5. Check traces at http://localhost:3050"
    echo ""
    echo "Optional: Run validation"
    echo "  ./scripts/validate-setup.sh --post"
fi

echo ""
echo "Debug commands:"
echo "  View hook logs: tail -f ~/.claude/state/langfuse_hook.log"
echo "  Enable debug mode: Add CC_LANGFUSE_DEBUG=true to env in settings.json"
echo "  Test hook manually: $PYTHON $HOOK_DEST"
echo ""
echo -e "${GREEN}Happy tracing!${NC}"
echo ""
