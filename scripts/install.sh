#!/usr/bin/env bash
set -euo pipefail

# Browser Use Skill — Installer
# Installs agent-browser (npm CLI) + browser-use (Python venv) + system deps

WRAPPER="$HOME/.local/bin/browser-use-agent"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
VENV_DIR="${BROWSER_USE_VENV:-$INSTALL_HOME/opt/browser-use}"
UV_BIN=""

echo "=== Browser Use Skill Installer ==="

# --- System dependencies ---
echo "[1/5] Installing system dependencies..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3 python3-venv xvfb \
        libglib2.0-0 libnss3 libnspr4 libdbus-1-3 libatk1.0-0 \
        libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 \
        libxdamage1 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
        libatspi2.0-0 2>/dev/null || true
elif command -v brew &>/dev/null; then
    echo "  macOS detected — Chromium ships with Playwright, skipping system deps"
else
    echo "  WARNING: Unknown package manager. Ensure python3, chromium deps are installed."
fi

# --- agent-browser (npm global CLI) ---
echo "[2/5] Installing agent-browser..."
if command -v agent-browser &>/dev/null; then
    echo "  agent-browser already installed: $(agent-browser --version 2>/dev/null || echo 'unknown')"
else
    npm install -g agent-browser
    echo "  Installed agent-browser"
fi

# Install Playwright + Chromium for agent-browser
echo "[3/5] Installing Playwright browsers..."
agent-browser install --with-deps 2>/dev/null || agent-browser install 2>/dev/null || {
    npx playwright install chromium 2>/dev/null || true
}

# --- browser-use (Python venv) ---
echo "[4/5] Setting up browser-use Python environment (uv)..."

# Install uv as the invoking user to avoid root-owned home directories
if ! command -v uv &>/dev/null; then
    echo "  Installing uv for user: $INSTALL_USER"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$INSTALL_USER" -H bash -c "curl -Ls https://astral.sh/uv/install.sh | sh"
    else
        curl -Ls https://astral.sh/uv/install.sh | sh
    fi
fi

if [ -x "$INSTALL_HOME/.local/bin/uv" ]; then
    UV_BIN="$INSTALL_HOME/.local/bin/uv"
else
    UV_BIN="$(command -v uv)"
fi

if [ -z "$UV_BIN" ]; then
    echo "  ERROR: uv not found after install. Aborting."
    exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
    "$UV_BIN" venv "$VENV_DIR" --python python3
fi

"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -q --upgrade pip
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -q browser-use langchain-anthropic langchain-openai

# Install Playwright in the venv too
"$VENV_DIR/bin/python3" -m playwright install chromium 2>/dev/null || true

# --- Wrapper script ---
echo "[5/5] Creating browser-use-agent wrapper..."
cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# browser-use-agent — Autonomous browser agent wrapper
# Usage: browser-use-agent "task description" [--model MODEL] [--max-steps N]
set -euo pipefail

VENV_DIR="${BROWSER_USE_VENV:-$HOME/opt/browser-use}"
TASK="${1:?Usage: browser-use-agent \"task description\" [--model MODEL] [--max-steps N]}"
shift

MODEL=""
MAX_STEPS=12

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --max-steps) MAX_STEPS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT=$(cat << PYEOF
import asyncio, json, os, sys
from browser_use import Agent

def load_openclaw_config():
    candidates = []
    env_path = os.environ.get("OPENCLAW_CONFIG")
    if env_path:
        candidates.append(env_path)
    candidates.append(os.path.expanduser("~/.openclaw/openclaw.json"))
    if os.path.expanduser("~") != "/root":
        candidates.append("/root/.openclaw/openclaw.json")
    for path in candidates:
        if path and os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f), path
    return {}, None

def resolve_model(config, override):
    default_primary = (
        config.get("agents", {})
        .get("defaults", {})
        .get("model", {})
        .get("primary")
    )
    model = override or default_primary or "gpt-4o-mini"
    if "/" in model:
        provider, model_id = model.split("/", 1)
    else:
        if default_primary and "/" in default_primary:
            provider = default_primary.split("/", 1)[0]
        else:
            provider = "openai"
        model_id = model
    return provider, model_id, model

def build_llm(config, provider, model_id):
    providers = config.get("models", {}).get("providers", {})
    provider_cfg = providers.get(provider, {})
    api_key = provider_cfg.get("apiKey")
    base_url = provider_cfg.get("baseUrl")
    if provider in ("anthropic", "claude"):
        from langchain_anthropic import ChatAnthropic
        if not api_key:
            raise RuntimeError("Missing apiKey for provider 'anthropic' in OpenClaw config.")
        return ChatAnthropic(model=model_id, api_key=api_key)
    else:
        from langchain_openai import ChatOpenAI
        kwargs = {"model": model_id}
        if api_key:
            kwargs["api_key"] = api_key
        if base_url:
            kwargs["base_url"] = base_url
        return ChatOpenAI(**kwargs)

async def run():
    config, config_path = load_openclaw_config()
    if not config:
        raise RuntimeError(
            "OpenClaw config not found. Set OPENCLAW_CONFIG or place openclaw.json under ~/.openclaw/."
        )
    provider, model_id, resolved = resolve_model(config, """$MODEL""")
    llm = build_llm(config, provider, model_id)
    agent = Agent(task="""$TASK""", llm=llm)
    result = await agent.run(max_steps=$MAX_STEPS)
    final = result.final_result()
    if final:
        print(final.extracted_content if hasattr(final, 'extracted_content') else str(final))
    else:
        for r in result.all_results:
            if r.extracted_content:
                print(r.extracted_content)

asyncio.run(run())
PYEOF
)

echo "$SCRIPT" > /tmp/_bu_task.py
xvfb-run "$VENV_DIR/bin/python3" /tmp/_bu_task.py
WRAPPER_EOF

chmod +x "$WRAPPER"

echo ""
echo "=== Installation complete ==="
echo "  agent-browser: $(command -v agent-browser 2>/dev/null || echo 'not found')"
echo "  browser-use:   $VENV_DIR/bin/python3"
echo "  wrapper:       $WRAPPER"
echo ""
echo "Quick test:"
echo "  agent-browser open https://example.com && agent-browser snapshot -i && agent-browser close"
echo "  browser-use-agent \"Describe what you see on example.com\""
