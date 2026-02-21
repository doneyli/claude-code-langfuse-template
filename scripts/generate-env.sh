#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "====================================="
echo "Langfuse Credential Generator"
echo "====================================="
echo ""

# Check for openssl
if ! command -v openssl &> /dev/null; then
    echo -e "${RED}Error: openssl is required but not installed${NC}"
    echo "Please install openssl and try again"
    exit 1
fi

# Check if .env exists
if [ -f .env ]; then
    echo -e "${YELLOW}Warning: .env file already exists${NC}"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Keeping existing .env file."
        exit 0
    fi
fi

# Check if .env.example exists
if [ ! -f .env.example ]; then
    echo -e "${RED}Error: .env.example not found${NC}"
    echo "Please run this script from the repository root"
    exit 1
fi

echo "Generating secure random credentials..."
echo ""

# Generate random credentials
POSTGRES_PASSWORD=$(openssl rand -hex 24)
ENCRYPTION_KEY=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
SALT=$(openssl rand -hex 16)
CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)
MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)
REDIS_AUTH=$(openssl rand -hex 24)
PROJECT_SECRET_KEY="sk-lf-local-$(openssl rand -hex 16)"

# Prompt for user details
echo "Enter your details for the Langfuse admin user:"
echo ""

read -p "Email address: " USER_EMAIL
if [ -z "$USER_EMAIL" ]; then
    USER_EMAIL="admin@localhost.local"
    echo -e "${YELLOW}Using default: $USER_EMAIL${NC}"
fi

read -p "Full name (default: Admin): " USER_NAME
if [ -z "$USER_NAME" ]; then
    USER_NAME="Admin"
fi

read -sp "Password (default: auto-generated): " USER_PASSWORD
echo ""
if [ -z "$USER_PASSWORD" ]; then
    USER_PASSWORD=$(openssl rand -hex 12)
    echo -e "${YELLOW}Auto-generated password: $USER_PASSWORD${NC}"
fi

read -p "Organization name (default: My Org): " ORG_NAME
if [ -z "$ORG_NAME" ]; then
    ORG_NAME="My Org"
fi

echo ""
echo "Creating .env file..."

# Copy template and replace values
cp .env.example .env

# Use sed to replace values (macOS and Linux compatible)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
    sed -i '' "s|ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${ENCRYPTION_KEY}|" .env
    sed -i '' "s|NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=${NEXTAUTH_SECRET}|" .env
    sed -i '' "s|SALT=.*|SALT=${SALT}|" .env
    sed -i '' "s|CLICKHOUSE_PASSWORD=.*|CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}|" .env
    sed -i '' "s|MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" .env
    sed -i '' "s|REDIS_AUTH=.*|REDIS_AUTH=${REDIS_AUTH}|" .env
    sed -i '' "s|LANGFUSE_INIT_PROJECT_SECRET_KEY=.*|LANGFUSE_INIT_PROJECT_SECRET_KEY=${PROJECT_SECRET_KEY}|" .env
    sed -i '' "s|LANGFUSE_INIT_USER_EMAIL=.*|LANGFUSE_INIT_USER_EMAIL=${USER_EMAIL}|" .env
    sed -i '' "s|LANGFUSE_INIT_USER_NAME=.*|LANGFUSE_INIT_USER_NAME=${USER_NAME}|" .env
    sed -i '' "s|LANGFUSE_INIT_USER_PASSWORD=.*|LANGFUSE_INIT_USER_PASSWORD=${USER_PASSWORD}|" .env
    sed -i '' "s|LANGFUSE_INIT_ORG_NAME=.*|LANGFUSE_INIT_ORG_NAME=${ORG_NAME}|" .env
else
    # Linux
    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
    sed -i "s|ENCRYPTION_KEY=.*|ENCRYPTION_KEY=${ENCRYPTION_KEY}|" .env
    sed -i "s|NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=${NEXTAUTH_SECRET}|" .env
    sed -i "s|SALT=.*|SALT=${SALT}|" .env
    sed -i "s|CLICKHOUSE_PASSWORD=.*|CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}|" .env
    sed -i "s|MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" .env
    sed -i "s|REDIS_AUTH=.*|REDIS_AUTH=${REDIS_AUTH}|" .env
    sed -i "s|LANGFUSE_INIT_PROJECT_SECRET_KEY=.*|LANGFUSE_INIT_PROJECT_SECRET_KEY=${PROJECT_SECRET_KEY}|" .env
    sed -i "s|LANGFUSE_INIT_USER_EMAIL=.*|LANGFUSE_INIT_USER_EMAIL=${USER_EMAIL}|" .env
    sed -i "s|LANGFUSE_INIT_USER_NAME=.*|LANGFUSE_INIT_USER_NAME=${USER_NAME}|" .env
    sed -i "s|LANGFUSE_INIT_USER_PASSWORD=.*|LANGFUSE_INIT_USER_PASSWORD=${USER_PASSWORD}|" .env
    sed -i "s|LANGFUSE_INIT_ORG_NAME=.*|LANGFUSE_INIT_ORG_NAME=${ORG_NAME}|" .env
fi

echo -e "${GREEN}✓ Generated .env file successfully${NC}"
echo ""
echo "====================================="
echo "Credentials Summary"
echo "====================================="
echo ""
echo "Langfuse Web UI:"
echo "  URL: http://localhost:3050"
echo "  Email: $USER_EMAIL"
echo "  Password: $USER_PASSWORD"
echo ""
echo "API Keys (for Claude Code hook):"
echo "  Public Key: pk-lf-local-claude-code"
echo "  Secret Key: $PROJECT_SECRET_KEY"
echo ""
echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
echo "The .env file is git-ignored and won't be committed."
echo ""
echo "Next steps:"
echo "  1. Start Langfuse: docker compose up -d"
echo "  2. Install hook: ./scripts/install-hook.sh"
echo "  3. Access UI: http://localhost:3050"
echo ""
