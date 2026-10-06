# Routing: why the switch is manual

## What this setup does

`cc-local` sends everything to your node. `cc-cloud` sends everything to
Anthropic. You choose at session start, and there is no crossover within a
session — the `"*"` catch-all in `litellm-config.yaml` means even Claude Code's
small background calls stay local under `cc-local`.

Running `/model` inside a `cc-local` session will not reach a Claude model,
because all three tiers are mapped onto `local-coder`.

## The billing constraint

This is the reason for everything below.

Claude Code's usage limits come from a **Pro/Max subscription**. LiteLLM
reaching Anthropic needs a **pay-as-you-go API key** from the Console, which is
separate billing. A subscription cannot be used programmatically by a proxy.

So any automatic routing that sends hard work to Anthropic starts costing
per-token. That is a real tradeoff, not a configuration detail: the quota
pressure that motivated this setup gets solved with money instead.

There is a subtler version of the same problem. Subscription quota is not
graduated — any request reaching Anthropic consumes it. Routing can only change
*what fraction* of requests go cloud-ward, and in an agentic loop one task is
dozens of requests. Per-request escalation makes quota burn less predictable,
not more.

## Enabling automatic failover

Worth doing if you have an API key. This is availability-based failover, not
complexity routing: when the node is unreachable, requests go to Anthropic
instead of erroring mid-task.

1. Put a real key in `~/.config/cc-hybrid/litellm.env`:

   ```
   ANTHROPIC_API_KEY=sk-ant-api03-...
   ```

2. Uncomment the `cloud-sonnet` block in `model_list` in
   `litellm-config.yaml`.

3. Uncomment the `fallbacks` section under `router_settings`:

   ```yaml
   fallbacks:
     - local-coder: ["cloud-sonnet"]
     - "*": ["cloud-sonnet"]
   ```

4. `systemctl --user restart cc-litellm`

## Complexity-based routing

It exists, it is in the tool you already run, and it still does not solve the
problem.

**LiteLLM Auto Router v2** (v1.94.x+, beta — config keys may change between
releases) classifies each request into tiers:

```yaml
model_list:
  - model_name: smart-router
    litellm_params:
      model: auto_router/complexity_router
      complexity_router_config:
        tiers:
          SIMPLE: local-coder
          MEDIUM: local-coder
          COMPLEX: cloud-sonnet
          REASONING: cloud-sonnet
        classifier_type: llm
        classifier_llm_config:
          model: claude-haiku-4-5-20251001
          timeout_ms: 2000
        keyword_tier_rules:
          - keywords: ["refactor", "race condition", "segfault"]
            tier: COMPLEX
        semantic_keyword_matching: true
        session_affinity: true
        classification_mode: user_turn
```

Classification can be heuristic, keyword (literal or semantic), an LLM
classifier, or a custom plugin. Keyword matches escalate to the highest
applicable tier. It works with the `/v1/messages` endpoint.

**Three reasons it is a poor fit for a coding agent:**

1. **The billing wall is unchanged.** The COMPLEX tier has to be a cloud model,
   so you still need the API key.

2. **Agentic loops break the assumptions.** These routers were built for chat:
   one question in, one answer out. Claude Code sends long multi-turn loops
   where most turns are tool results rather than fresh asks. LiteLLM has
   clearly hit this — `classification_mode: user_turn` exists to classify only
   genuine new user asks, and `session_affinity` exists to stop the model
   changing underneath a live conversation. The second one is telling: once a
   session is pinned to one tier for coherence, you have arrived at what
   `cc-local` and `cc-cloud` already do manually. The automation decides the
   tier at session start and nothing more.

3. **The signal is not in the prompt.** "Fix the failing test" is four words
   and is either a typo or a two-hour debug. Difficulty in coding work reveals
   itself a few tool calls in — exactly when a router has already committed.

**Other options considered:**

- **RouteLLM** — unmaintained since August 2024. Its classifiers were trained
  on 80k+ Chatbot Arena preference comparisons, so adapting it would mean your
  own labelled dataset and retraining.
- **Martian, Not Diamond, OpenRouter auto-router** — hosted commercial
  services that route across *their* catalogue. A model on your own node is not
  a destination they can reach.

## What is actually worth automating

**Availability, not difficulty.** A wrapper that runs `cc-status` and picks
`cc-local` when the chain is healthy and `cc-cloud` when it is not. Free, no API
key, no classifier latency.

**Prompt triage with a human in the loop.** Scan your initial prompt for
escalation keywords and *suggest* `cc-cloud` before launching, leaving the
decision to you. You get the triage benefit while the judgement stays where it
belongs.

Neither is implemented here yet.

## References

- [LiteLLM Auto Router v2](https://docs.litellm.ai/blog/autorouter-v2)
- [LiteLLM Auto Routing docs (beta)](https://docs.litellm.ai/docs/proxy/auto_routing)
- [Auto-Router: context size and modality](https://docs.litellm.ai/blog/auto-router-more-routing-configurations)
- [LiteLLM `/v1/messages` endpoint](https://docs.litellm.ai/docs/anthropic_unified)
- [Claude Code LLM gateway docs](https://code.claude.com/docs/en/llm-gateway)
- [Open-source router comparison](https://www.clawrouters.com/blog/best-open-source-llm-router)
