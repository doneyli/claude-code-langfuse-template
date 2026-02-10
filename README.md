# Claude Code + Langfuse: Session Observability Template

Capture every Claude Code conversation — prompts, responses, tool calls, and session grouping — using Langfuse Cloud or a self-hosted instance.

This template provides a complete, production-ready setup for observing your Claude Code sessions using Langfuse. Choose between **Langfuse Cloud** (zero infrastructure) or **self-hosted** (everything runs locally in Docker), with automatic session tracking and incremental state management.

**Read the full story:** [I Built My Own Observability for Claude Code](https://doneyli.substack.com/p/i-built-my-own-observability-for) — why I built this, how it works, and screenshots of the setup in action.

## Choose Your Setup

| | Langfuse Cloud | Self-Hosted |
|---|---|---|
| **Infrastructure** | None (fully managed) | Docker on your machine |
| **Prerequisites** | Python 3.11+ | Python 3.11+, Docker, 4-6GB RAM, 2-5GB disk |
| **Setup time** | ~2 minutes | ~5 minutes |
| **Data location** | Langfuse Cloud (EU or US) | Your machine only |
| **Cost** | Free tier available | Free (self-hosted) |

## Quick Start — Option A: Langfuse Cloud

Use this if you have (or want to create) a [Langfuse Cloud](https://cloud.langfuse.com) account. No Docker required.

**Prerequisites:** Python 3.11+, Claude Code CLI, a Langfuse Cloud account with API keys.

1. **Clone the repository**
   ```bash
   git clone https://github.com/doneyli/claude-code-langfuse-template.git
   cd claude-code-langfuse-template
   ```

2. **Install the hook (cloud mode)**
   ```bash
   ./scripts/install-hook.sh --cloud
   ```
   You'll be prompted for your public key, secret key, and region (EU/US/custom).

3. **Verify the setup**
   ```bash
   ./scripts/validate-setup.sh --cloud --post
   ```
   Then start a Claude Code conversation — traces will appear in your Langfuse Cloud dashboard.

## Quick Start — Option B: Self-Hosted

Use this to run everything locally in Docker. No external accounts needed.

**Prerequisites:** Docker and Docker Compose, Python 3.11+, Claude Code CLI, 4-6GB RAM, 2-5GB disk.

1. **Clone the repository**
   ```bash
   git clone https://github.com/doneyli/claude-code-langfuse-template.git
   cd claude-code-langfuse-template
   ```

   **Optional: Verify prerequisites**
   ```bash
   ./scripts/validate-setup.sh
   ```

2. **Generate credentials**
   ```bash
   cp .env.example .env
   ./scripts/generate-env.sh
   ```
   This will generate secure random credentials and prompt for your email/name.

3. **Start Langfuse**
   ```bash
   docker compose up -d
   ```
   Wait 30-60 seconds for all services to initialize.

4. **Install the hook**
   ```bash
   ./scripts/install-hook.sh
   ```
   This installs the Python package and configures Claude Code to send traces to Langfuse.

5. **Verify the setup**
   - Open http://localhost:3050 in your browser
   - Log in with the credentials from your `.env` file
   - Start a Claude Code conversation
   - Watch traces appear in Langfuse in real-time

   **Optional: Run full validation**
   ```bash
   ./scripts/validate-setup.sh --post
   ```

## What Gets Captured

| Item | Description |
|------|-------------|
| User prompts | Full text of every user message |
| Assistant responses | Complete assistant replies, including reasoning |
| Tool calls | Name, input parameters, and output for every tool invocation |
| Session grouping | All turns in a Claude Code session grouped together |
| Model info | Model name and version used for each response |
| Timing | Duration of each turn and tool call |
| Project context | Project name extracted from workspace path |

## How It Works

The Langfuse hook runs as a Claude Code **Stop hook** — it executes after each assistant response completes.

**Architecture:**

```
┌─────────────┐
│ Claude Code │
│  (Desktop)  │
└──────┬──────┘
       │
       │ Writes transcript after each turn
       ▼
┌─────────────────────┐
│ transcript.jsonl    │
│ ~/.claude/projects/ │
└──────┬──────────────┘
       │
       │ Stop hook triggers
       ▼
┌──────────────────────┐
│ langfuse_hook.py     │
│ - Parses transcript  │
│ - Tracks state       │
│ - Groups by session  │
└──────┬───────────────┘
       │
       │ HTTP POST
       ▼
┌──────────────────────────────┐
│ Langfuse API                 │
│ (localhost:3050 or Cloud)    │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────┐
│ PostgreSQL + ClickHouse  │
│ (traces, analytics)      │
└──────────────────────────┘
```

**Key Features:**

- **Incremental state tracking**: Only processes new messages since last run
- **Session grouping**: All turns in a conversation are linked by session ID
- **Tool call tracking**: Each tool invocation is captured as a span with input/output
- **Graceful failure**: Errors are logged but don't interrupt Claude Code
- **Opt-in by default**: Only runs when `TRACE_TO_LANGFUSE=true`

## Configuration

### Global vs Per-Project

The installation script sets up **global tracing** by default (all Claude Code sessions are captured).

To opt out for a specific project:

1. Create `.claude/settings.local.json` in your project root
2. Add the opt-out configuration:
   ```json
   {
     "env": {
       "TRACE_TO_LANGFUSE": "false"
     }
   }
   ```

See `settings-examples/project-opt-out.json` for a complete example.

### Cloud Settings Example

If you're using Langfuse Cloud and want to see or tweak the generated configuration, see `settings-examples/cloud-settings.json`.

### Environment Variables

All configuration is managed through environment variables in `~/.claude/settings.json`:

- `TRACE_TO_LANGFUSE`: Enable/disable tracing (`true` or `false`)
- `LANGFUSE_PUBLIC_KEY`: Project public key (auto-generated)
- `LANGFUSE_SECRET_KEY`: Project secret key (auto-generated)
- `LANGFUSE_HOST`: Langfuse URL (default: `http://localhost:3050`)
- `CC_LANGFUSE_DEBUG`: Enable debug logging (`true` or `false`)

### Customization

**Change the Langfuse port:**
Edit `docker-compose.yml` and update the `langfuse-web` port mapping:
```yaml
ports:
  - 3051:3000  # Change 3050 to 3051
```

Also update `LANGFUSE_HOST` in your `.env.example` and regenerate credentials.

**Add custom tags:**
Edit `hooks/langfuse_hook.py` and modify the `tags` list in the `create_trace()` function:
```python
tags = ["claude-code", "my-custom-tag"]
```

**Adjust log retention:**
By default, logs are kept indefinitely. To clean up old logs:
```bash
# Clear hook logs older than 7 days
find ~/.claude/state -name "langfuse_hook.log" -mtime +7 -delete
```

## Operations

### Common Commands

**View logs:**
```bash
# Langfuse web logs
docker compose logs -f langfuse-web

# All services
docker compose logs -f

# Hook execution logs
tail -f ~/.claude/state/langfuse_hook.log
```

**Restart services:**
```bash
docker compose restart
```

**Stop services:**
```bash
docker compose down
```

**Stop and remove all data:**
```bash
docker compose down -v
```

**Update Langfuse to latest version:**
```bash
docker compose pull
docker compose up -d
```

**Check service health:**
```bash
docker compose ps
```

**Access the database directly:**
```bash
# PostgreSQL
docker compose exec postgres psql -U postgres

# ClickHouse
docker compose exec clickhouse clickhouse-client
```

### Debugging

**Enable debug logging:**
Edit `~/.claude/settings.json` and add:
```json
{
  "env": {
    "CC_LANGFUSE_DEBUG": "true"
  }
}
```

Then check `~/.claude/state/langfuse_hook.log` for detailed execution logs.

**Verify the hook is running:**
```bash
# Check if hook is registered
cat ~/.claude/settings.json | grep -A 5 "Stop"

# Check hook logs
tail -20 ~/.claude/state/langfuse_hook.log
```

**Test the hook manually:**
```bash
TRACE_TO_LANGFUSE=true \
LANGFUSE_PUBLIC_KEY=pk-lf-local-claude-code \
LANGFUSE_SECRET_KEY=your-secret-key \
LANGFUSE_HOST=http://localhost:3050 \
python3 ~/.claude/hooks/langfuse_hook.py
```

## Troubleshooting

### Docker not running

**Symptom:** `docker compose up -d` fails with connection error

**Solution:**
```bash
# macOS
open -a Docker

# Linux
sudo systemctl start docker
```

### Python version too old

**Symptom:** `install-hook.sh` reports Python 3.11+ required

**Solution:**
```bash
# macOS (Homebrew)
brew install python@3.12

# Ubuntu/Debian
sudo apt install python3.12

# Or use pyenv
pyenv install 3.12
pyenv global 3.12
```

### Port already in use

**Symptom:** Docker fails to start because port 3050 is in use

**Solution:**
```bash
# Find what's using the port
lsof -i :3050

# Either stop that service, or change the Langfuse port in docker-compose.yml
```

### Cloud: API key rejected

**Symptom:** Traces don't appear in Langfuse Cloud, hook logs show 401/403 errors

**Check:**
1. Keys must start with `pk-lf-` (public) and `sk-lf-` (secret)
2. Verify keys match the correct project in your Langfuse Cloud dashboard
3. Ensure `LANGFUSE_HOST` matches your region (`https://cloud.langfuse.com` for EU, `https://us.cloud.langfuse.com` for US)
4. Re-run: `./scripts/install-hook.sh --cloud`

### Cloud: Cannot reach Langfuse Cloud

**Symptom:** `validate-setup.sh --cloud --post` warns that the API is not reachable

**Check:**
1. Verify internet connectivity: `curl https://cloud.langfuse.com/api/public/health`
2. Check for proxy/firewall blocking outbound HTTPS
3. If using a custom URL, verify it's correct

### Traces not appearing

**Symptom:** Langfuse UI shows no traces after conversations

**Check:**
1. Is `TRACE_TO_LANGFUSE=true` in `~/.claude/settings.json`?
2. Are the API keys correct?
3. Check hook logs: `tail -f ~/.claude/state/langfuse_hook.log`
4. **Self-hosted:** Verify Docker services are running: `docker compose ps`
5. **Self-hosted:** Test API: `curl http://localhost:3050/api/public/health`
6. **Cloud:** Test API: `curl https://cloud.langfuse.com/api/public/health`

### Hook runs slowly

**Symptom:** Hook execution takes >3 minutes (warning in logs)

**Solution:**
- Large transcripts can slow processing
- Consider archiving old sessions: move `.jsonl` files from `~/.claude/projects/*/` to a backup location
- Check Docker resource limits (increase CPU/memory allocation)

### Database disk space

**Symptom:** Services crash due to disk space

**Solution:**
```bash
# Check volume sizes
docker system df -v

# Remove old traces (via Langfuse UI or API)
# Or reset everything:
docker compose down -v
docker compose up -d
```

## Resource Usage

**Typical usage:**
- **RAM:** 4-6GB total (PostgreSQL: 500MB, ClickHouse: 2GB, Redis: 100MB, MinIO: 200MB, Langfuse: 1-2GB)
- **Disk:** 2-5GB (depends on trace volume and retention)
- **CPU:** Minimal (spikes during trace ingestion)

**Scaling considerations:**
- For heavy usage (>1000 traces/day), consider increasing PostgreSQL and ClickHouse memory limits
- ClickHouse benefits from SSD storage for analytics queries
- Redis is used for caching and can be scaled vertically if needed

## Architecture Details

### Services

- **langfuse-web**: Main web UI and API (port 3050)
- **langfuse-worker**: Background job processor (handles async tasks)
- **postgres**: Primary data store (traces, users, projects)
- **clickhouse**: Analytics database (aggregations, dashboards)
- **redis**: Cache and job queue
- **minio**: S3-compatible object storage (media uploads, exports)

### Data Flow

1. Claude Code writes each message to `~/.claude/projects/<project>/<session>.jsonl`
2. After assistant response, Stop hook triggers
3. Hook reads new messages since last execution (tracked in state file)
4. Hook groups messages into turns (user → assistant → tools → assistant)
5. Each turn becomes a Langfuse trace with nested spans for tool calls
6. Langfuse API validates and stores in PostgreSQL
7. Background worker processes for ClickHouse analytics

### Security

**Self-hosted:**
- All services run on `localhost` (not exposed to network)
- Credentials are generated randomly on first setup
- `.env` file is git-ignored (never commit credentials)
- No telemetry is sent to external services

**Cloud:**
- Traces are sent to Langfuse Cloud (EU or US region)
- API keys are stored in `~/.claude/settings.json` (not committed to git)
- Review [Langfuse's security & privacy documentation](https://langfuse.com/security) for data handling details

## Customization Ideas

**Add user ID tracking:**
Edit the hook to include your name or machine ID in metadata:
```python
metadata={
    "user": os.environ.get("USER"),
    "hostname": os.uname().nodename,
    "source": "claude-code",
}
```

**Filter sensitive content:**
Add a sanitization function to scrub API keys or passwords before sending:
```python
def sanitize(text: str) -> str:
    # Remove common secret patterns
    text = re.sub(r'sk-[a-zA-Z0-9]{32,}', 'SK-REDACTED', text)
    text = re.sub(r'Bearer [a-zA-Z0-9._-]+', 'Bearer REDACTED', text)
    return text
```

**Add cost tracking:**
Estimate token usage based on text length and add to metadata:
```python
import tiktoken

def estimate_tokens(text: str, model: str = "claude") -> int:
    # Rough estimate: ~4 chars per token
    return len(text) // 4

metadata={
    "estimated_tokens": estimate_tokens(user_text + final_output),
}
```

## Disclaimer

This is a **personal project** and is not affiliated with, sponsored by, or endorsed by ClickHouse, Inc., Anthropic, or any other organization.

This software is provided "as-is" without warranty of any kind. Use at your own risk. The author makes no guarantees about reliability, security, or fitness for any particular purpose.

**No support commitment.** While issues and PRs are welcome, there is no guarantee of response time or resolution. This is a side project maintained in spare time.

By using this template, you accept full responsibility for:
- Securing your deployment
- Backing up your data
- Reviewing the code for your specific security requirements
- Any costs, damages, or issues arising from its use

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly (especially the hook script)
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Credits

- [Langfuse](https://langfuse.com/) - Open-source LLM observability
- [Anthropic Claude](https://claude.ai/) - AI assistant platform

---

**Happy tracing!** If you find this useful, consider starring the repository.
