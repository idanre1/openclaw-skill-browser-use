#!/bin/bash
# browser-use-agent.sh — Standalone wrapper (same as installed /usr/local/bin/browser-use-agent)
# Can be run directly from the skill directory without global install.
# Usage: ./browser-use-agent.sh "task description" [--model MODEL] [--max-steps N]
set -euo pipefail

VENV_DIR="${BROWSER_USE_VENV:-/opt/browser-use}"
TASK="${1:?Usage: $0 \"task description\" [--model MODEL] [--max-steps N]}"
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

cat > /tmp/_bu_task.py << PYEOF
import asyncio, json, os
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

xvfb-run "$VENV_DIR/bin/python3" /tmp/_bu_task.py
