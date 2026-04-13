# Bug Hunt Round 4

## Agent participation bugs

### 1. Top-level non-object JSON can crash agent POST endpoints

- File and function: `lib/hangout_web/controllers/agent_controller.ex:49` in `messages/2`, `lib/hangout_web/controllers/agent_controller.ex:104` in `drafts/2`, and `lib/hangout_web/controllers/agent_controller.ex:200` in `request_body/1`
- Category: crash
- Severity: high
- What's wrong: `request_body/1` accepts any successfully decoded JSON term from the raw body path. `messages/2` and `drafts/2` then index it as `params["body"]`. If an agent sends valid JSON that is not an object, such as `[]`, `"text"`, or `1`, the controller raises instead of returning the JSON error envelope. This is separate from the prior draft body type check: the body field can be absent because the whole decoded payload is the wrong shape.
- Impact: a malformed or buggy agent with a valid bearer token can turn both `/messages` and `/drafts` into 500s with syntactically valid JSON.
- How to fix it: make the raw-body `request_body/1` branch return `{:ok, params}` only when `is_map(params)`, and return `{:error, :invalid_json}` for all other decoded JSON shapes. Keep the existing map-only clause for Plug-parsed body params.

### 2. Non-string `client_msg_id` values can crash `/messages`

- File and function: `lib/hangout_web/controllers/agent_controller.ex:50` in `messages/2` and `lib/hangout/agent_token.ex:151` in `check_dedup/2`
- Category: crash
- Severity: high
- What's wrong: `messages/2` passes `params["client_msg_id"]` directly into `AgentToken.check_dedup/2`. The fallback clause coerces non-binary IDs with `to_string/1`. JSON objects decode to maps, and `String.Chars` is not implemented for maps, so a payload like `{"body":"hi","client_msg_id":{"id":"x"}}` raises `Protocol.UndefinedError`.
- Impact: a valid agent token can cause a 500 by sending a malformed idempotency key. The endpoint should reject or ignore an invalid `client_msg_id` in-band instead of crashing.
- How to fix it: accept only `nil`, `""`, or binary `client_msg_id` values. Return `400 invalid_json` or `422 invalid_client_msg_id` for other shapes, and remove the broad `to_string/1` fallback.

### 3. SSE streams keep reading after token expiry

- File and function: `lib/hangout_web/controllers/agent_controller.ex:8` in `events/2`, `lib/hangout_web/controllers/agent_controller.ex:210` in `sse_loop/1`, and `lib/hangout/agent_token.ex:230` in `validate_metadata/2`
- Category: security
- Severity: high
- What's wrong: token expiry is checked only when the SSE request starts. After `events/2` enters `sse_loop/1`, there is no timer, revalidation, or expiry broadcast. `AgentToken` broadcasts on explicit revoke and room cleanup, but not when `expires_at` passes. A token that is valid at connect time can therefore keep receiving all room messages after its configured expiry.
- Impact: the documented 24-hour bearer-token lifetime is not enforced for already-connected agents. `/messages` will reject an expired token on each POST, but the read side can remain open indefinitely until the room ends, the user leaves, or someone explicitly revokes the token.
- How to fix it: enforce expiry on active streams. Options include scheduling per-token expiry in `AgentToken` and broadcasting `:agent_revoked`, adding an expiry timeout branch in `sse_loop/1`, or periodically revalidating before emitting channel events.

### 4. The SSE handshake can duplicate a live message in both `history` and `message`

- File and function: `lib/hangout_web/controllers/agent_controller.ex:14` in `events/2`, `lib/hangout_web/controllers/agent_controller.ex:26` in `events/2`, and `lib/hangout_web/controllers/agent_controller.ex:174` in `build_history/1`
- Category: reliability
- Severity: medium
- What's wrong: `events/2` subscribes to the channel topic before building the history snapshot. If a room message is broadcast after the subscription but before `ChannelServer.snapshot/1` returns, that message is queued in the controller mailbox and can also be present in the `history` payload. Once `sse_loop/1` starts, the queued event is emitted again as a live `message`.
- Impact: agents can see the same room message twice during connect and may produce duplicate responses, especially if they trigger on mentions or process history and live events uniformly.
- How to fix it: add a high-water mark to the history payload and drop queued `message` events whose ids are at or below it, or subscribe after snapshot and use a server-side replay/cursor mechanism that closes the missed-message gap without duplication.

### Test run

- Command: `MIX_ENV=test mix test test/hangout_web/controllers/agent_controller_test.exs test/hangout/agent_token_test.exs`
- Result: blocked before project tests ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
