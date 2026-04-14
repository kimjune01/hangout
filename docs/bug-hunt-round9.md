# Bug Hunt Round 9

Scope read: all agent participation code paths in `lib/`, `assets/js/hooks.js`, `assets/js/app.js`, and the agent-related tests/docs. Previously reported and intentionally deferred issues were excluded.

## Agent participation bugs

### 1. Agent dedup and rate-limit ETS state outlives every token lifecycle path

- File and function: `lib/hangout/agent_token.ex:111` in `check_rate_limit/2`, `lib/hangout/agent_token.ex:132` in `check_dedup/2`, `lib/hangout/agent_token.ex:257` in `cleanup_room/1`, and `lib/hangout/channel_server.ex:480` in `terminate/2`
- Category: resource cleanup
- Severity: medium
- What's wrong: accepted agent POSTs write per-token rows into `:agent_msg_dedup` and `:agent_rate_limit`, but token cleanup only updates or deletes rows in `:agent_tokens`. `revoke/1` and `revoke_for_nick/2` mark token metadata revoked without removing auxiliary rows. `cleanup_room/1`, including the room termination path, deletes token metadata but leaves all dedup reservations and fixed-window rate buckets for that token hash behind. Expired tokens also have no pruning path. Because token hashes are random and never reused, those auxiliary rows become unreachable garbage.
- Impact: normal agent use leaks ETS memory over time. A room with active agents can leave up to 100 dedup rows per token plus one rate bucket per active minute, and explicit invite/revoke cycles or expired tokens accumulate token metadata as well. This is separate from the earlier unbounded `client_msg_id` issue: the IDs are now bounded, but their rows still survive after the token and room lifecycle has ended.
- How to fix it: centralize token deletion/revocation cleanup so every terminal token path removes `@dedup_table` entries matching `{token_hash, _}` and `@rate_table` entries matching `{token_hash, _minute}`. Add periodic pruning for expired/revoked metadata, or delete expired tokens when validation finds them expired after broadcasting revocation to any active SSE stream.

## Test run

- Command: `MIX_ENV=test mix test test/hangout_web/controllers/agent_controller_test.exs test/hangout/agent_token_test.exs test/hangout/mention_detection_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
