# Troubleshooting

## "The response was blocked by the provider's content filter"

You switch a profile to a Claude model, send a message, and after half a minute of apparent work
the turn ends with a red box and no answer:

```
The response was blocked by the provider's content filter
▣  Sisyphus - Ultraworker · Claude Fable 5 · 55.8s
```

Then the next message fails the same way. And the one after that, even if it is one harmless word.

This is not the widget, and it is not your config. It is worth writing down anyway, because the
message names neither the provider nor the reason, and the obvious readings of it are all wrong.

### What it actually means

opencode raises this whenever a turn finishes with the reason `content-filter`. On the **anthropic**
provider exactly one thing produces that value — the API answered `HTTP 200` with
`stop_reason: "refusal"`:

```js
if (reason === "end_turn" || reason === "stop_sequence") return "stop"
if (reason === "max_tokens")                            return "length"
if (reason === "tool_use")                              return "tool-calls"
if (reason === "refusal")                               return "content-filter"
```

So a refusal is a *successful response*, not an error. Anthropic's streaming classifiers stopped the
model mid-generation and threw away what it had written. That is why the timer shows 30–60 seconds:
the model really was working, and you are billed for the part that streamed before the refusal.

The response carries a `stop_details.category` saying which policy area fired:

| category | what it means |
|---|---|
| `cyber` | could enable cyber harm. **Benign security work also triggers this.** |
| `bio` | could enable biological harm. Beneficial life-sciences work also triggers it. |
| `frontier_llm` | could assist development of competing AI models |
| `reasoning_extraction` | asks the model to reproduce its internal reasoning as output text |
| `general_harms` | a policy area not named above. Benign work sometimes triggers it. |

opencode does not surface that category today, which is why the box tells you nothing. That is a
known upstream gap — [opencode#34835](https://github.com/anomalyco/opencode/issues/34835).

### Why the *next* message fails too

Because the refused turn is still in the conversation. Anthropic is explicit about this:

> When you receive `stop_reason: refusal`, you **must reset the conversation context** before
> continuing. […] Attempting to continue without resetting will result in continued refusals.

opencode does not reset anything — it marks the turn as failed and moves on, leaving the refused
exchange in the history, which the next request sends straight back. The one-word follow-up is not
being judged on its own merits; the whole thread is. **A new turn in the same session is not a
reset. You need a new session.**

### Why it looks like the model's fault

Often it is. Anthropic ships classifiers on some models that decline more readily than others, and
their own guidance for a refusal is to *send the same request to a different Claude model*. So if
one model refuses a prompt and another answers it, that is the documented behaviour rather than
evidence that something is broken locally.

Reported in the wild on a benign frontend task, with **no plugins at all**, by a user on an
OpenCode Zen subscription — [opencode#32029](https://github.com/anomalyco/opencode/issues/32029),
closed with:

> the content filters aren't enforced by us so we cant do anything about that, they can be
> encountered regardless of where model is hosted: vertex, bedrock, anthropic direct

### Careful: the same box, a different cause

The message is hardcoded once in opencode, but several providers map onto it, so it is **not** proof
that a refusal happened. On `google-vertex`, three unrelated failures are indistinguishable
([opencode#35736](https://github.com/anomalyco/opencode/issues/35736)):

| what really happened | what you see |
|---|---|
| `HTTP 404 NOT_FOUND` — model not served in that region | "blocked by the provider's content filter" |
| dropped socket / connection reset | the same |
| a genuine `stop_reason: refusal` | the same |

Gemini maps its `SAFETY`, `RECITATION`, `PROHIBITED_CONTENT` and `SPII` reasons onto it too. So
before concluding anything, find out which provider actually served the turn:

```bash
grep -o '"anthropic":{"type":"[a-z]*"' ~/.local/share/opencode/auth.json
```

`oauth` or `api` means you are talking to Anthropic directly and a refusal is the only explanation.
No match means the model came from somewhere else — a relay, Zen, Bedrock or Vertex — and the box
may be standing in for a 404 or a dead connection.

### What to do

1. **Start a new session.** Not a new message — a new session. This is the step Anthropic requires,
   and it is the one that explains why everything after the first refusal also fails.
2. **Switch the profile to another Claude model.** This is Anthropic's own recommended recovery, not
   a workaround. If it succeeds, the refusal was model-specific and nothing local is at fault.
3. **Let Anthropic retry for you.** Setting `fallbacks` makes the API re-run a declined request on
   another model server-side and hand you a normal answer, so the red box never reaches you:

   ```json
   {
     "provider": {
       "anthropic": {
         "options": { "fallbacks": "default" }
       }
     }
   }
   ```

   opencode adds the required beta header itself when it sees `"default"`. Two caveats: Anthropic
   documents this as beta on the Claude API, so it is untested against subscription OAuth
   credentials, and for a refusal category with no recommended fallback the refusal still stands.

A profile switch will not disturb any of this. This widget claims only `model`, `small_model` and
`agent` (`bin/oc-profiles`), so a `provider` block you add by hand comes back untouched after every
switch — the same guarantee described in [Switching, safely](../README.md#switching-safely).

### What it is not

- **Not running out of tokens, context or reasoning effort.** Those finish as `max_tokens` or
  `model_context_window_exceeded`, both of which map to `length`, never to `content-filter`.
- **Not a crash or a malformed request.** A bad request comes back as an HTTP 400 and never reaches
  the code that produces this message.
- **Not necessarily caused by a plugin.** An auth or agent plugin can change *what the classifier
  reads* — several rewrite the system prompt before it is sent — but the same failure is reported
  with no plugins installed. Check the provider first, then bisect plugins, in that order.

### Related

- [Handle streaming refusals](https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/handle-streaming-refusals) — the context-reset requirement
- [Refusals and fallback](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback) — categories, response shape, server-side fallback
- [opencode#35475](https://github.com/anomalyco/opencode/issues/35475) — a false positive, billed for output nobody received
