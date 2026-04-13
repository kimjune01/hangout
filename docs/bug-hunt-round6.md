# Bug Hunt Round 6

Scope read: all agent participation code paths in `lib/`, `assets/js/hooks.js`, `assets/js/app.js`, and the agent-related tests. Previously reported and intentionally deferred issues were excluded.

## Agent participation bugs

### 1. Concurrent retries with the same `client_msg_id` can publish duplicates

- File and function: `lib/hangout_web/controllers/agent_controller.ex:57` and `lib/hangout_web/controllers/agent_controller.ex:60` in `messages/2`, `lib/hangout_web/controllers/agent_controller.ex:121` and `lib/hangout_web/controllers/agent_controller.ex:131` in `drafts/2`, and `lib/hangout/agent_token.ex:135` / `lib/hangout/agent_token.ex:150` in `check_dedup/2` and `record_dedup/2`
- Category: reliability
- Severity: high
- What's wrong: idempotency is a non-atomic check-then-record sequence. Two concurrent requests with the same token and `client_msg_id` can both see no ETS dedup entry, both publish or broadcast, and only then both record the same dedup key. This is distinct from round 5's failure-poisoning bug: recording after success avoids poisoning, but it no longer reserves the key before side effects.
- Impact: normal agent retry behavior can still create duplicate room messages or duplicate owner drafts under network timeouts or parallel retries. The API contract says agents may deduplicate on `(token, client_msg_id)`, so duplicates should not depend on request timing.
- How to fix it: make dedup reservation atomic before the side effect, then commit success or release the reservation on failure. Options include routing dedup operations through the `AgentToken` GenServer, using an ETS operation that atomically inserts only when absent, or storing an in-flight/result state for each key and returning the prior result for exact retries.

### 2. Parallel agent POSTs can bypass the six-per-minute rate limit

- File and function: `lib/hangout/agent_token.ex:111` in `check_rate_limit/2`, called by `lib/hangout_web/controllers/agent_controller.ex:58` and `lib/hangout_web/controllers/agent_controller.ex:122`
- Category: abuse prevention
- Severity: medium
- What's wrong: rate limiting is also a non-atomic ETS read-modify-write. Parallel requests can all read the same timestamp list before any request writes its update, each decide the token is below the limit, and each return `:ok`. The final ETS value may even lose timestamps from other requests because later inserts overwrite earlier inserts with their own stale `recent` list.
- Impact: a bursty or buggy agent can exceed the documented 6 messages/minute output limit by issuing concurrent `/messages` or `/drafts` requests. This weakens the moderation and anti-spam contract specifically added for agent participation.
- How to fix it: serialize rate-limit mutation per token or use an atomic counter/window representation. A GenServer-owned token state is the simplest fit for the current module; an ETS-based fix needs compare-and-swap-style retry logic or atomic update primitives that cannot lose concurrent writes.

## Test run

- Command: `mix test test/hangout/mention_detection_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
