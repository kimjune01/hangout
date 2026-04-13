# Bug Hunt Round 2

## Agent participation bugs

### 1. Draft safety checks crash on non-string JSON bodies

- File and function: `lib/hangout_web/controllers/agent_controller.ex:99` in `drafts/2`
- Category: crash
- Severity: high
- What's wrong: the `/drafts` fix added `byte_size(body)` and `SecretFilter.check(body)` after `body = params["body"] || ""`, but it does not verify that `body` is a binary. A valid agent token can POST JSON like `{"body":{"text":"hi"}}`; `byte_size/1` raises `ArgumentError` before the controller can return the JSON error envelope. The `/messages` path handles this class of input through `ChannelServer.validate_body/1`.
- Impact: a malformed or buggy agent can turn `/drafts` into a 500 instead of a controlled `message_too_large` or `invalid_json` response.
- How to fix it: normalize with `body = params["body"]` only when `is_binary(body)`, otherwise return `422` with `message_too_large` or `400` with `invalid_json`. Then run size and secret checks once on the validated binary.

### 2. Existing-token LiveViews show forwarding controls but cannot forward

- File and function: `lib/hangout_web/live/room_live.ex:288` in `handle_event("generate_agent_token", ...)`, `lib/hangout_web/live/room_live.ex:318` in `handle_event("forward_to_agent", ...)`, and `lib/hangout_web/live/info_modal.ex:36` in `info_modal/1`
- Category: state
- Severity: high
- What's wrong: when `AgentToken.create/3` returns `{:error, :active_token_exists}`, the LiveView sets `agent_connected?: true` but leaves `agent_token` and `agent_token_url` nil. That makes the UI show the agent as active and display the forward buttons, but `forward_to_agent` requires `socket.assigns.agent_token` to be a binary before it can compute the agent PubSub topic. The click therefore silently does nothing.
- Impact: after a reload, duplicate invite click, or any state loss while a token remains active, the owner can see controls for an active agent but cannot forward messages to it from that LiveView session.
- How to fix it: do not set `agent_connected?: true` unless the LiveView has enough routing state to operate. Either store and return a non-secret token hash/routing id for active-token lookups, or keep the UI in an "invite already active" state with only a disconnect/regenerate action.

### 3. Mod succession promotes server-side but LiveView never becomes moderator

- File and function: `lib/hangout/channel_server.ex:698` in `maybe_promote_successor/2`, and `lib/hangout_web/live/room_live.ex:818` in `apply_event/2`
- Category: integration
- Severity: high
- What's wrong: the new succession path updates the chosen participant's `:o` mode and broadcasts `{:user_mode_changed, ...}`, but `RoomLive.apply_event/2` has no handler for that event. The promoted user's socket keeps `moderator?: false`, and its participant list does not show the new op mode. The LiveView moderation actions also guard on `socket.assigns.moderator?`, so crafted LiveView events from the promoted user are ignored before reaching `ChannelServer.authorized?/3`.
- Impact: when the last visible operator leaves, the server has a successor, but the successor cannot use room controls from the browser. The room can appear effectively unmoderated.
- How to fix it: handle `:user_mode_changed` in LiveView by updating the affected participant's modes and recomputing `moderator?` for the current nick. Alternatively broadcast the existing `:modes_changed` event after succession, but the current user still needs `moderator?` refreshed.

### 4. Some generated agent invite URLs are not redacted

- File and function: `lib/hangout/secret_filter.ex:58` in the agent invite URL pattern, and `lib/hangout/agent_token.ex:177` in token generation
- Category: security
- Severity: medium
- What's wrong: generated tokens use unpadded base64url, so the random part can contain `-` and `_`. The redaction regex is `~r/\/agent\/agt_[a-zA-Z0-9]+/`, which requires the first random character after `agt_` to be alphanumeric. Tokens whose encoded body starts with `-` or `_` do not match at all.
- Impact: roughly 1 in 32 valid invite URLs can be pasted into chat without triggering the documented agent invite URL secret filter, leaking a live bearer token into room history.
- How to fix it: allow the full base64url alphabet and require a token-length-shaped suffix, for example `~r/\/agent\/agt_[A-Za-z0-9_-]{40,}/`.

### 5. Duplicate retries consume rate-limit budget before deduplication

- File and function: `lib/hangout_web/controllers/agent_controller.ex:52` in `messages/2`, and `lib/hangout/agent_token.ex:111` in `check_rate_limit/2`
- Category: reliability
- Severity: medium
- What's wrong: `/messages` checks the rate limit before checking `client_msg_id` deduplication. Retrying the same already-accepted message therefore appends another timestamp to the per-token rate bucket before returning `duplicate`. Enough duplicate retries can cause the next real message to return `rate_limited`, even though no additional message was published.
- Impact: normal HTTP retry behavior can throttle an agent spuriously and make a later legitimate response fail.
- How to fix it: check for an existing `client_msg_id` before consuming rate-limit budget. For cleaner idempotency, store dedup records after successful publication and retain enough response metadata to return the original success for exact retries.

### Test run

- Command: `mix test`
- Result: blocked before tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
- Retry: `MIX_NO_SYNC=1 mix test`
- Result: same Mix PubSub startup failure before project tests ran.
