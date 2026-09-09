# AFZ LLM Worker Routing Addendum

Status: ACTIVE

This addendum applies when an AFZ worker needs LLM inference. It does not replace worker scheduling, Direct Fabric, Control Hub, GitHub coordination, or project-specific safety gates.

## Required entry point

Windows model-backed worker jobs should use:

`afz-openai-agent/Invoke-Hermes-ModelRouter.ps1`

Runtime implementation on Windows-main:

`C:\Projects\HermesRouter\hermes_route.py`

Do not call a raw OpenRouter model directly from routine worker scripts unless a project explicitly pins that provider/model for reproducibility.

## Lane selection

- routine/general -> `default`
- bulk/background/economy -> `cheap`
- code/build/repair -> `coding`
- difficult recovery/architecture/reasoning -> `complex`
- Qwen-specific experiment -> `qwen`
- client/private/confidential -> set `Privacy=client|private|sensitive`
- offline/local-only -> `local`

## Privacy invariant

Any client/private/sensitive request is forced to the sensitive lane:

1. GPT-5.6 Sol via OpenAI OAuth
2. local Ollama fallback

OpenRouter is never attempted for these privacy values.

## Output validation

Machine-consumed responses should specify a validator:

- JSON: `json`
- bare unified diff: `diff`
- exact non-empty line count: `lines:N`

A validation failure is treated as a model failure and the router escalates to the next route.

## Timeouts/failover

- Qwen3.8 Flash is capped at 60 seconds because benchmark behavior was highly variable.
- GLM 5.3 Flash is the normal OpenRouter worker.
- GLM 5.3 is the stronger escalation model.
- DeepSeek V4 Flash 0731 is the economy/background lane.
- Local fallback uses direct loopback Ollama to avoid Hermes system-prompt overhead.

Muse Contributor is excluded from production routing.
