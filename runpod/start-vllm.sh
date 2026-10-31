#!/usr/bin/env bash
# Start an OpenAI-compatible vLLM server for an abliterated model on a RunPod
# GPU pod. Run this inside the pod's terminal (Jupyter "Web Terminal" or SSH).
#
#   MODEL=huihui-ai/Huihui-Qwen3-8B-abliterated-v2 bash start-vllm.sh
#   PORT=8000 MAX_LEN=40960 UTIL=0.92 bash start-vllm.sh
#
# Then point dsh at it:
#   RUNPOD_LLM_BASE_URL=https://<POD_ID>-8000.proxy.runpod.net/v1
#   RUNPOD_LLM_API_KEY=<the key you pass here as API_KEY>
#
# Notes:
#  - The official vLLM image ships vllm; this script installs nothing else.
#  - `--enable-auto-tool-choice` + a tool parser is what lets the harness's
#    agent loop actually call tools (bash, fs, MCP). Without it the model can
#    only produce plain text.
#  - Qwen3 emits tool calls in Hermes-style JSON, so use `hermes`.
set -euo pipefail

MODEL="${MODEL:-huihui-ai/Huihui-Qwen3-8B-abliterated-v2}"
PORT="${PORT:-8000}"
MAX_LEN="${MAX_LEN:-40960}"        # full Qwen3 context is 40,960
UTIL="${UTIL:-0.92}"               # fraction of VRAM vLLM may use
BATCH="${BATCH:-32}"               # max concurrent sequences
API_KEY="${API_KEY:-sk-local-$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')}"
TOOL_PARSER="${TOOL_PARSER:-hermes}"
HF_TOKEN="${HF_TOKEN:-}"

command -v vllm >/dev/null || { echo "vllm not found -- use a RunPod vLLM template/image" >&2; exit 1; }

echo "model      : $MODEL"
echo "listen     : 0.0.0.0:$PORT"
echo "max tokens : $MAX_LEN   gpu util: $UTIL   batch: $BATCH"
echo "api key    : $API_KEY   <-- copy this into .env as RUNPOD_LLM_API_KEY"
echo

args=(
  "$MODEL"
  --host 0.0.0.0
  --port "$PORT"
  --served-model-name "$MODEL"
  --max-model-len "$MAX_LEN"
  --gpu-memory-utilization "$UTIL"
  --max-num-seqs "$BATCH"
  --enable-auto-tool-choice
  --tool-call-parser "$TOOL_PARSER"
  --enable-prefix-caching
)

# Only send a key if you want one; RunPod's proxy URL is public, so set one.
[[ -n "$API_KEY" ]] && args+=(--api-key "$API_KEY")
[[ -n "$HF_TOKEN" ]] && export HF_TOKEN

exec vllm serve "${args[@]}"
