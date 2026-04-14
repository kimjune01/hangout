# Bug Hunt Ship

## 1. Called mode still allows unsolicited `/messages` posts

- File and function: `lib/hangout_web/controllers/agent_controller.ex:52` in `messages/2`
- What's wrong: the endpoint only blocks effective modes `:off` and `:draft`. That means an agent in the default effective mode `:called` can POST to `/messages` at any time, without a current `mention` event. The spec's server-enforced routing says unsolicited posts are not allowed, and called mode only permits direct replies when the agent is invoked.
- Impact: the default permission level behaves more like free mode at the API boundary. A buggy or compromised agent can speak directly in the room as `owner🤖` without anyone mentioning it.
- How to fix it: track issued invocation ids with their expected route (`mention` -> `/messages`, `forward` -> `/drafts`) and require `/messages` in `:called` mode to consume a pending mention invocation. Keep unsolicited `/messages` posts limited to effective `:free` and `:unleashed`.

## 2. Forward contract says drafts are optional in called/free/unleashed even though forwards require owner approval

- File and function: `lib/hangout_web/controllers/agent_controller.ex:187` in `build_context/3`, `lib/hangout_web/controllers/agent_controller.ex:301` in `build_mode_event/1`, and `lib/hangout_web/live/room_live.ex:407` in `handle_event("forward_to_agent", ...)`
- What's wrong: forwarded messages are always emitted with `"requires_approval" => true`, and the spec says responses to `forward` events must use `/drafts`. But the SSE contract reports `"owner_forward_requires_draft" => false` for effective modes `:called`, `:free`, and `:unleashed`. `mode_routes/1` still includes `"forward"` for those modes, so an agent following the machine-readable capability field can treat a forward response as direct-postable.
- Impact: owner-invoked agent output can bypass the approval path in every mode above draft, violating the trust rule that owners gate their own invocations.
- How to fix it: make `owner_forward_requires_draft` always true while forwards use the current approval workflow. If free/unleashed are intended to allow a separate unsolicited/direct capability, expose that separately from forward routing and still enforce `/drafts` for forward invocation ids.

## 3. Agent-to-agent mentions route to non-unleashed target agents when the room policy is unleashed

- File and function: `lib/hangout/channel_server.ex:789` and `lib/hangout/channel_server.ex:791` in `route_mentions/2`
- What's wrong: the first clause blocks all agent-authored mentions unless the room policy is `:unleashed`. Once the room policy is unleashed, the per-target filter only rejects effective `:off` and `:draft`. A target agent whose owner mode is merely `:called` or `:free` will still receive mention events caused by another agent, even though its effective contract says `"agent_to_agent_mentions" => false` unless effective mode is `:unleashed`.
- Impact: one moderator setting can opt every called/free agent into agent-to-agent cascades, bypassing the owner's per-agent slider and contradicting each agent's SSE contract.
- How to fix it: when `msg.agent` is true, route only to targets whose effective mode is exactly `:unleashed`. Human-authored mentions can keep the current called/free/unleashed behavior.

## 4. `@nick-bot` routes as a mention even though the spec requires exact `@nick🤖`

- File and function: `lib/hangout/channel_server.ex:820` in `mentions_owner?/2`, and `lib/hangout_web/controllers/agent_controller.ex:262` in `build_instructions/2`
- What's wrong: the mention regex accepts both `🤖` and `-bot` suffixes, while the spec says only exact `@<owner_nick>🤖` should trigger mention routing. The LLM instruction text also tells agents to speak as `owner-bot` and respond to `@owner-bot`, while the structured contract and UI use `owner🤖`.
- Impact: users can invoke agents through an undocumented alias, and agents receive contradictory identity/routing instructions. That makes client behavior drift from the documented protocol and from what humans see in the room.
- How to fix it: remove `-bot` from the server mention regex and update instruction text to consistently use `owner🤖` / `@owner🤖`.

## 5. Active SSE streams do not receive rate-limit changes

- File and function: `lib/hangout/channel_server.ex:438` in `handle_call({:set_agent_rate_limit, ...})` and `lib/hangout_web/controllers/agent_controller.ex:330` in `sse_loop/3`
- What's wrong: changing the room-level agent rate limit broadcasts `{:agent_rate_limit_changed, ...}`, but `sse_loop/3` has no branch for that event. It only emits `mode` updates for owner mode and room policy changes.
- Impact: connected agents keep stale `limits.max_messages_per_minute` from their initial `context` event. A mod lowering the limit can make well-behaved agents unexpectedly hit `rate_limited`, and raising it will not be visible until reconnect.
- How to fix it: handle `:agent_rate_limit_changed` in `sse_loop/3` and emit an updated mode/settings event that includes `limits.max_messages_per_minute`. Consider including the same `limits` block in all mode-change events so the SSE contract stays coherent.

## 6. Presence tracking goes false while an older SSE stream is still attached

- File and function: `lib/hangout/agent_token.ex:145` in `mark_attached/3` and `lib/hangout/agent_token.ex:157` in `mark_detached/3`
- What's wrong: presence is stored as a single `{token_hash, pid}` row. If two SSE streams attach with the same token, the second overwrites the first without broadcasting a new attach. When the second stream detaches, `mark_detached/3` deletes the row and broadcasts `:agent_detached` even if the first stream is still connected.
- Impact: the owner UI can show the agent as disconnected and hide forward controls while an agent stream is still receiving room events. Reconnects or duplicate agent-client processes can make presence flicker or stick incorrectly.
- How to fix it: track a set or reference count of attached PIDs per token. Broadcast `:agent_attached` only on the transition from zero to one streams, and `:agent_detached` only on the transition from one to zero streams.
