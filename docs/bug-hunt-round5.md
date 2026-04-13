# Bug Hunt Round 5

Scope read: all agent participation code paths in `lib/`, `assets/js/hooks.js`, and the agent-related tests.

## Agent participation bugs

### 1. Failed `/messages` attempts poison idempotency keys

- File and function: `lib/hangout_web/controllers/agent_controller.ex:56` in `messages/2`, and `lib/hangout/agent_token.ex:135` in `check_dedup/2`
- Category: reliability
- Severity: medium
- What's wrong: `/messages` records `client_msg_id` before checking the rate limit and before publishing succeeds. If a request with a new idempotency key fails after `check_dedup/2`, such as `rate_limited`, `agent_muted`, `message_too_large`, `secret_detected`, or `room_ended`, the id remains in ETS. A later retry with the same `client_msg_id` returns `duplicate` even though no message was ever accepted.
- Impact: normal agent retry behavior can permanently lose a response. The worst case is a transient failure: an agent sends while muted or rate-limited, waits, retries the same logical message as intended, and the server rejects the retry as a duplicate.
- How to fix it: reserve or commit dedup records only for successful publishes, or store the full result for each `client_msg_id` and return the same result on exact retries. If pre-reservation is needed for concurrency, remove the reservation when later checks fail.

### 2. `/drafts` bypasses the agent idempotency and rate-limit contract

- File and function: `lib/hangout_web/controllers/agent_controller.ex:103` in `drafts/2`
- Category: reliability
- Severity: medium
- What's wrong: the draft endpoint validates token, JSON shape, size, and secrets, then broadcasts directly to the owner's draft topic. It never reads `client_msg_id`, never calls `AgentToken.check_dedup/2`, and never calls `AgentToken.check_rate_limit/2`. The spec defines idempotency for POST bodies generally and the MVP rate limit as 6 messages/minute per agent.
- Impact: an agent that retries `/drafts` can overwrite the owner's input repeatedly with duplicate drafts, and a buggy agent can spam draft events without hitting the same per-agent output throttle enforced on `/messages`.
- How to fix it: apply the same idempotency and rate-limit path to accepted draft writes. Prefer sharing a small helper so `/messages` and `/drafts` cannot drift again.

### 3. Missing or JSON-false message bodies publish empty agent messages

- File and function: `lib/hangout_web/controllers/agent_controller.ex:53` in `messages/2`
- Category: input validation
- Severity: low
- What's wrong: `/messages` normalizes `params["body"] || ""`. Because `nil` and `false` become `""`, payloads like `{}`, `{"body": null}`, and `{"body": false}` pass validation and publish an empty agent message. The `/drafts` path already rejects non-string or missing bodies.
- Impact: malformed agent requests can create blank `owner🤖` messages in the room instead of receiving a controlled input error. This is especially confusing because human sends ignore empty text.
- How to fix it: require `body` to be a binary and non-empty after the same trim policy used for human sends, returning `400 invalid_json` or a specific validation error for missing and non-string bodies.

## Test run

- Command: `MIX_ENV=test mix test test/hangout_web/controllers/agent_controller_test.exs test/hangout/agent_token_test.exs test/hangout/mention_detection_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
