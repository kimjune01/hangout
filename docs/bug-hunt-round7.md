# Bug Hunt Round 7

Scope read: agent participation code paths in `lib/`, `assets/js/hooks.js`, and the agent-related tests/docs. Previously reported and intentionally deferred issues were excluded.

## Agent participation bugs

### 1. Muted rooms still accept agent drafts

- File and function: `lib/hangout_web/controllers/agent_controller.ex:120` in `drafts/2`, and `lib/hangout/channel_server.ex:525` in `can_agent_send?/1`
- Category: moderation
- Severity: medium
- What's wrong: `/messages` goes through `ChannelServer.agent_message/3`, which calls `can_agent_send?/1` and returns `agent_muted` when the room has mode `+m`. `/drafts` validates body shape, size, secrets, dedup, and rate limit, then broadcasts directly to the owner's draft topic without checking the room's mute state. The agent participation spec says muting the room stops all agent output, and `agent_muted` is part of the defined agent POST error set.
- Impact: a moderator can mute the room and stop public agent messages, but a connected agent can still keep writing output into the owner's input bar through `/drafts`. That leaves one agent output path active during a moderation action intended to stop agents.
- How to fix it: apply the same mute check to `/drafts` before broadcasting. A small shared helper for accepted agent output would reduce the chance that `/messages` and `/drafts` drift again.

### 2. Even-length backtick code spans/fences can still route mentions

- File and function: `lib/hangout/channel_server.ex:756` and `lib/hangout/channel_server.ex:789` in mention routing
- Category: invocation correctness
- Severity: low
- What's wrong: mention routing strips code by toggling `in_code?` for every individual backtick byte. That only suppresses content when the opener has an odd number of backticks. Markdown code spans and fences can use two, four, or more backticks, so text like ```` ``@june🤖`` ```` or a four-backtick fence leaves `@june🤖` outside the toggled code state and routes a `mention` event anyway. The existing test only covers a one-backtick span.
- Impact: users can paste Markdown/code that visually marks an agent mention as code, but the server may still invoke the agent. That violates the mention rule that code mentions are ignored and can cause accidental agent responses from quoted examples or pasted snippets.
- How to fix it: replace the byte-toggle stripper with a Markdown-aware code span/fence pass, or at least consume full runs of backticks and treat matching runs as code delimiters rather than flipping state per character. Add tests for double-backtick spans and even-length fenced blocks.

## Test run

- Command: `MIX_ENV=test mix test test/hangout/mention_detection_test.exs test/hangout_web/controllers/agent_controller_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
