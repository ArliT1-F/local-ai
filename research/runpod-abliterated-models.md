# Step 3 — Best abliterated model to self-host on RunPod, and what it costs

Research date: **31 October 2026**. All prices are RunPod list prices from its
pricing page, last updated **8 October 2026**; all model figures come from the
Hugging Face model cards / API for the exact repos named.

Goal: the most *trusted* abliterated model that is small enough to serve
cheaply, so the DeepSeek Harness can call it over an OpenAI-compatible API
instead of (or alongside) the hosted Abliterated Large Flash.

---

## TL;DR — the top 3

| # | Model | Params | Weights (BF16) | Runs on | Pod cost | Why it made the list |
| - | - | -: | -: | - | -: | - |
| **1** | [`huihui-ai/Huihui-Qwen3-8B-abliterated-v2`](https://huggingface.co/huihui-ai/Huihui-Qwen3-8B-abliterated-v2) | 8.19 B | 16.4 GB | RTX A5000 24 GB | **$0.27/hr** | Best capability-per-dollar that still fits the cheapest 24 GB card. Apache-2.0, ships a native tool-calling template, 40 960 ctx, 26.1 k downloads / 71 likes. |
| **2** | [`huihui-ai/Huihui-Qwen3-14B-abliterated-v2`](https://huggingface.co/huihui-ai/Huihui-Qwen3-14B-abliterated-v2) | 14 B | ~28 GB (or ~9 GB AWQ) | A40 48 GB, or 24 GB with AWQ/FP8 | **$0.59/hr** ($0.27 with AWQ) | Noticeably stronger reasoning than the 8B for ~2× the hourly price. Same org, same recipe, apache-2.0. Its GGUF quants alone pull ~66 k downloads, which is the trust signal. |
| **3** | [`huihui-ai/Qwen2.5-7B-Instruct-abliterated-v2`](https://huggingface.co/huihui-ai/Qwen2.5-7B-Instruct-abliterated-v2) | 7.6 B | ~15 GB | RTX A5000 24 GB | **$0.27/hr** | The most *documented* one: the card publishes IFEval 77.8, MMLU-Pro 42.0, TruthfulQA 57.8, BBH 53.0, GPQA 32.2 next to the un-abliterated base, so you can see what the surgery cost. Mature Qwen2.5 tool calling. |

**Pick #1 unless you have a reason not to.** It is the cheapest thing that is
still genuinely useful as an agentic model, and it is the one wired into
`runpod/start-vllm.sh` and the `runpod` provider route in
`dsh/cordis.patch.yml`.

---

## What each option actually costs

### RunPod list prices (8 Oct 2026)

24 GB class — where 8B models live:

| GPU | VRAM | Pod $/hr | Serverless $/hr |
| - | -: | -: | -: |
| RTX A5000 | 24 GB | **0.27** | 0.75 (L4/A5000/3090 pool) |
| RTX 3090 | 24 GB | 0.50 | 0.75 |
| L4 | 24 GB | 0.59 | 0.75 |
| RTX 4090 | 24 GB | 0.89 | 1.34 |

48 GB class — where a 14B in BF16 lives:

| GPU | VRAM | Pod $/hr | Serverless $/hr |
| - | -: | -: | -: |
| A40 / RTX A6000 | 48 GB | **0.59** | 1.22 |
| L40 | 48 GB | 0.82 | 1.75 |
| L40S / RTX 6000 Ada | 48 GB | 1.09 / 0.99 | 1.75 |

Storage (matters more than people expect for self-hosting):

| Type | $/GB/mo |
| - | -: |
| Container disk | 0.10 |
| Volume disk — running / **idle** | 0.10 / **0.20** |
| Network storage — <1 TB | 0.07 |

A 30 GB volume holding the model costs **$6/mo idle**, more than a few hours of
GPU time. Budget it.

### Monthly totals

| Scenario | Setup | $/month |
| - | - | -: |
| Hobby, few hours a week | A5000 pod, 20 h | **5.40** |
| Agentic dev work | A5000 pod, 8 h/day × 30 | **64.80** |
| Team, business hours | A40 pod (14B), 10 h/day × 22 | 129.80 |
| Always on, 8B | A5000 pod 24/7 | **197.10** |
| Always on, 14B BF16 | A40 pod 24/7 | 430.70 |
| Spiky, no idle cost | Serverless 24 GB, 40 h active | 30.00 + storage |

### The comparison that matters: self-host vs the hosted API

Abliterated Large Flash is **$1.00 / 1M input** and **$2.00 / 1M output**
(cached input $0.10). An 8B on an A5000:

| Utilization | Effective output throughput | Cost per 1M output tokens |
| - | -: | -: |
| One stream, ~50 tok/s | 50 tok/s | ≈ **$1.50** |
| 8 concurrent streams, batched | ~400 tok/s | ≈ **$0.19** |

So: **at low utilization the hosted Flash is roughly the same price and much
smarter.** Self-hosting only wins when you keep the batch full, need the
weights locally, or want no third-party policy layer. That is the honest
answer to "as cheap as possible" — the cheapest correct setup for occasional
use is the API you already have.

---

## Why these three, and not the loudest ones on the Hub

Sorted results on Hugging Face are dominated by GGUF repos of 27B–35B MoE
models (`SC117/Qwen3.8-Flash-…`, `huihui-ai/Huihui-Qwen3.8-27B-abliterated`,
`0bserverx/Qwen3.8-27B-Heretic-…`). Great models, wrong shape for this job:
27B-class weights need 48–96 GB in BF16, or llama.cpp with heavy quantization,
which is neither the cheap path nor the vLLM path the harness wants.

Criteria I used, in order:

1. **Verifiable provenance** — a known abliteration org (`huihui-ai` is the
   most prolific and consistent), a clear base model on the card, and an
   open licence you can serve commercially (Apache-2.0 for all three above).
2. **Adoption as a trust proxy** — downloads/likes on the exact repo, not on a
   neighbouring fine-tune. 26 k draws for the 8B v2, 66 k for the 14B's GGUF
   quants, and a published benchmark table for the 7B.
3. **Tool calling** — non-negotiable for an agent harness. All three use
   Qwen chat templates with function calling; vLLM needs
   `--enable-auto-tool-choice --tool-call-parser hermes`.
4. **Fits the cheapest GPU** — ≤16.4 GB BF16 means a $0.27/hr card.

### Runners-up

- **`mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated`** — the most *liked*
  8B abliterated model (218 likes, 6.4 k downloads) and the canonical
  reference implementation of the technique. Falls to 4th on two counts: the
  Llama 3.1 community licence is more restrictive, and it is a 2024-era base
  that is weaker at agentic tool use than Qwen3.
- **`gemma-3-12b-it-abliterated`** — the interesting one if you need vision
  (Flash also takes images). Held back by the Gemma licence and by Gemma's
  weaker tool-calling story in vLLM.
- **`huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-MTP`** — a 3B-active MoE.
  Tokens/sec per dollar is excellent *if* you can feed it ~20 GB of Q4 GGUF on
  llama.cpp. Not the low-effort vLLM path; revisit if you scale up.

---

## Caveats worth knowing before you spend anything

- **Abliteration is a capability trade, not a free unlock.** The Qwen2.5 card
  shows it directly: TruthfulQA drops 62.5 → 57.8 and MMLU-Pro 43.1 → 42.0
  after ablation. Expect a few points of degradation, and re-check anything
  safety-relevant.
- **RunPod proxy URLs are public by default.** Without `--api-key` you are
  running somebody else's free GPU. `runpod/start-vllm.sh` generates one for
  you; put it in `.env`.
- **Prices are per-second on serverless and per-hour on pods**, and the
  community-cloud inventory that makes $0.27/hr possible is not always
  available in every region — the "secure cloud" equivalent is more.
- **Cold starts on serverless** (20–90 s for an 8B) will feel bad in an
  interactive harness; a warm pod does not have that problem but bills idle.

## Sources

- RunPod GPU pricing (pods, serverless, storage), updated 8 Oct 2026 — <https://www.runpod.io/pricing>
- `huihui-ai/Huihui-Qwen3-8B-abliterated-v2` model card + HF API metadata (8.19 B params, BF16, apache-2.0, 26 142 downloads, 71 likes) — <https://huggingface.co/huihui-ai/Huihui-Qwen3-8B-abliterated-v2>
- `huihui-ai/Qwen2.5-7B-Instruct-abliterated-v2` model card with benchmark deltas — <https://huggingface.co/huihui-ai/Qwen2.5-7B-Instruct-abliterated-v2>
- `huihui-ai/Huihui-Qwen3-14B-abliterated-v2` + GGUF quants (mradermacher, 66 200 downloads) — <https://huggingface.co/mradermacher/Huihui-Qwen3-14B-abliterated-v2-GGUF>
- `mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated` (218 likes, 6 442 downloads) — <https://huggingface.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated>
- Abliteration API pricing for the hosted comparison — <https://docs.abliteration.ai/pricing>
