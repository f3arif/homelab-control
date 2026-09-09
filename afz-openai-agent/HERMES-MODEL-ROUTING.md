# Hermes Model Routing — AFZ

Benchmark-informed routing policy for Windows-main.

## Lanes

| Lane | Order |
| --- | --- |
| default | GLM 5.3 Flash -> GLM 5.3 -> GPT-5.6 Sol -> local Qwen |
| cheap | DeepSeek V4 Flash 0731 -> GLM 5.3 Flash -> local Qwen |
| coding | GLM 5.3 Flash -> GLM 5.3 -> GPT-5.6 Sol -> local Qwen |
| complex | GLM 5.3 -> GPT-5.6 Sol -> GLM 5.3 Flash -> local Qwen |
| qwen | Qwen3.8 Flash (60 s cap) -> GLM 5.3 Flash -> GLM 5.3 -> local Qwen |
| sensitive | GPT-5.6 Sol through OpenAI OAuth -> local Ollama only |
| local | local Ollama only |

## Privacy

Any call using `--privacy private`, `--privacy sensitive`, or `--privacy client` is forced to the `sensitive` lane. OpenRouter is not attempted in this lane.

The Meta Muse Contributor endpoint remains excluded from production routing because it is a data-training tier.

## Validation

The router can reject malformed model output and continue to the next model:

- `--validator json`
- `--validator diff`
- `--validator lines:N`

## Windows-main runtime

Installed runtime:
`C:\Projects\HermesRouter\hermes_route.py`

Command:
`hermes-route.cmd --lane coding --prompt "..." `

Sensitive example:
`hermes-route.cmd --privacy client --prompt-file request.txt`

The local emergency fallback uses Ollama directly with `qwen3.5:4b-hermes96k`, `num_ctx=32768`, and no Hermes agent-system prompt overhead.

## Benchmark basis

Two sequential benchmark suites were run through the real Windows-main/Hermes/OpenRouter path:

- engineering/general: Python merge repair, HVAC arithmetic, Ontario client content
- project/non-engineering: FamilyPTT routing, Stremio/Radarr logic, homelab recovery, Radio Hilal segmentation

Observed pattern: GLM 5.3 Flash provided the best overall cost/performance; GLM 5.3 was the strongest fast escalation; DeepSeek was the economy lane; Qwen3.8 Flash was inconsistent enough to require a 60-second cap.
