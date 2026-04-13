# Bug Hunt Round 8

Scope read: agent participation code paths in `lib/`, `assets/js/hooks.js`, `assets/js/app.js`, and the agent-related tests/docs. Previously reported and intentionally deferred issues were excluded.

## Agent participation bugs

### 1. `/drafts` can crash if the room ends between token validation and mute check

- File and function: `lib/hangout_web/controllers/agent_controller.ex:123`, `lib/hangout_web/controllers/agent_controller.ex:135`, and `lib/hangout_web/controllers/agent_controller.ex:227`
- Category: crash
- Severity: medium
- What's wrong: `drafts/2` validates the bearer token first, then later calls `check_room_mute/1`. If the room disappears in that gap, `check_room_mute/1` returns `{:error, :no_such_channel}`, but the `with ... else` block has no branch for that return shape and no generic `{:error, reason}` fallback. The result is a `WithClauseError` instead of the defined JSON error envelope. `/messages` already has a `{:error, :no_such_channel}` branch that returns `room_ended`, so the two POST surfaces have drifted again.
- Impact: a normal room teardown race can turn a valid agent `/drafts` request into a 500. Agents should receive a controlled `room_ended` response.
- How to fix it: add a `{:error, :no_such_channel}` branch in `drafts/2` that returns `404` with `{"ok": false, "error": "room_ended"}`. Also add a generic `{:error, reason}` fallback so future shared checks cannot reintroduce a crash-only path.

### 2. `client_msg_id` is accepted as an unbounded ETS key

- File and function: `lib/hangout_web/controllers/agent_controller.ex:54`, `lib/hangout_web/controllers/agent_controller.ex:117`, and `lib/hangout/agent_token.ex:132`
- Category: resource exhaustion
- Severity: medium
- What's wrong: both `/messages` and `/drafts` pass `client_msg_id` directly to `AgentToken.check_dedup/2`. When it is a binary, `check_dedup/2` stores it as part of the ETS key without any length limit or shape validation. Body size is capped, but idempotency keys are not. A valid token can therefore submit very large unique ids and force the server to retain those binaries in `:agent_msg_dedup` until pruning drops entries beyond the last 100 per token.
- Impact: an agent can consume significant memory without sending oversized message bodies. With the default parser/request limits, 100 large ids for one token can pin hundreds of megabytes in ETS, and multiple active tokens multiply the effect. This bypasses the intended 4000-byte agent output cap because the large data lives in metadata, not the message body.
- How to fix it: require `client_msg_id` to be either absent/empty or a bounded binary, for example 1-128 bytes of a conservative printable/id-safe character set. Reject invalid values with a JSON error before calling `check_dedup/2`, and make `AgentToken.check_dedup/2` defensively return an error for invalid ids instead of treating non-binaries as no-id.

## Test run

- Command: `MIX_ENV=test mix test test/hangout_web/controllers/agent_controller_test.exs test/hangout/agent_token_test.exs test/hangout/mention_detection_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
