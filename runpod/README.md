# Self-hosting the abliterated model on RunPod

Two ways to get an OpenAI-compatible endpoint, in order of how little you have
to maintain. Both end at the same place: a `baseURL` + key that the `runpod`
provider route in `dsh/cordis.patch.yml` already points at.

| Path | Billing | Cold start | Best for |
| - | - | - | - |
| **Serverless endpoint** (official `runpod/worker-vllm`) | per second, scales to zero | 20–90 s on first request | intermittent/agentic use, the cheap default |
| **GPU pod** (`vllm/vllm-openai`) | per hour, always on | one model load, then always warm | heavy daily use, evals, long sessions |

---

## A. Serverless (recommended if you are cost-sensitive)

1. Console → **Serverless → New Endpoint → Import from GitHub**, use
   `runpod-workers/worker-vllm` (the official vLLM worker), GPU pool
   **24 GB** (L4 / A5000 / 3090 class).
2. Environment variables:

   ```
   MODEL_NAME=huihui-ai/Huihui-Qwen3-8B-abliterated-v2
   MAX_MODEL_LEN=40960
   GPU_MEMORY_UTILIZATION=0.92
   ENABLE_AUTO_TOOL_CHOICE=1
   TOOL_CALL_PARSER=hermes
   MAX_CONCURRENCY=8
   API_KEY=<long random string>
   ```

3. Deploy, then copy the endpoint id. Your OpenAI-compatible base URL is:

   ```
   https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1
   ```

4. In `.env`:

   ```sh
   RUNPOD_LLM_BASE_URL=https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1
   RUNPOD_LLM_API_KEY=<the same API_KEY>
   ```

Add a **network volume** (~30 GB, `$0.07/GB/mo` standard) if you want the
model cached between cold starts; otherwise each cold worker re-downloads it.

---

## B. GPU pod (always warm)

1. Deploy a pod with a **vLLM template** (or the `vllm/vllm-openai` image),
   24 GB GPU for the 8B, 48 GB if you want the 14B in BF16.
2. Add a volume so the HF cache survives pod restarts, and note the HTTP port
   `8000` in the pod's *Connect* panel.
3. In the pod terminal:

   ```sh
   MODEL=huihui-ai/Huihui-Qwen3-8B-abliterated-v2 bash start-vllm.sh
   ```

   The script prints the API key it generated — put it in `.env`.
4. Public URL: `https://<POD_ID>-8000.proxy.runpod.net` → base URL is
   `.../v1`.

**Stop the pod when you are done.** A pod bills for wall-clock uptime; a
serverless endpoint bills only while a request is being served.

---

## Security

- Always set `API_KEY`. A pod's proxy URL is world-reachable and unauthenticated
  by default — an open endpoint is somebody else's free GPU.
- Keep `RUNPOD_LLM_API_KEY` in `.env` (git-ignored), never in the YAML.
- The model output is unfiltered by design. Keep the endpoint private; do not
  front it with a public chat UI you don't control.

---

## Verify it

```sh
set -a; . ./.env; set +a
curl -s https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1/models \
  -H "Authorization: Bearer $RUNPOD_LLM_API_KEY"

curl -s https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1/chat/completions \
  -H "Authorization: Bearer $RUNPOD_LLM_API_KEY" -H 'content-type: application/json' \
  -d '{"model":"huihui-ai/Huihui-Qwen3-8B-abliterated-v2",
       "messages":[{"role":"user","content":"Say ok"}],"max_tokens":16}'
```

Then in the harness: **Settings → Models** should list
*RunPod (self-hosted) → Qwen3-8B abliterated (local)*, and
`bash scripts/verify-all.sh` will exercise the route once
`RUNPOD_LLM_BASE_URL` is set.

Model choice and cost reasoning: [`../research/runpod-abliterated-models.md`](../research/runpod-abliterated-models.md).
