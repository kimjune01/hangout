# Bug Hunt Round 3

## Agent participation bugs

### 1. Tokens can survive room teardown and attach to a later room with the same slug

- File and function: `lib/hangout/channel_server.ex:565` in `maybe_stop_if_empty/2`, `lib/hangout/channel_server.ex:574` in `maybe_stop_noreply/2`, and `lib/hangout/agent_token.ex:210` in `handle_info/2`
- Category: security
- Severity: critical
- What's wrong: `AgentToken` only cleans up room tokens when it receives `:room_ended` or `:room_expired`. The normal ephemeral-room path, where the last human leaves or disconnects, stops the `ChannelServer` after broadcasting only a `:notice`. That leaves the token row in ETS until its 24h expiry. While the room is gone, `validate/2` returns `:room_ended` because `ChannelRegistry.exists?/1` is false; if anyone later recreates the same slug before token expiry, the registry check becomes true again and the old bearer token validates against the new room.
- Impact: a stale invite URL from a previous incarnation of `#room` can read and post in a later, unrelated incarnation of `#room`. Since `ChannelServer.agent_message/3` also does not require the owner nick to be present, the stale agent can publish as the previous owner even if that user is not in the new room.
- How to fix it: make every room termination path revoke or delete room-scoped agent tokens. The empty-room shutdown paths should broadcast a terminal event that `AgentToken` handles, or `ChannelServer.terminate/2` should call a cleanup function for `state.name`. Also consider adding a room incarnation id to token metadata so a same-slug recreation cannot satisfy an old token.

### 2. IRC nick changes leave the old nick's agent token active

- File and function: `lib/hangout/channel_server.ex:215` in `handle_call({:nick, ...})`, `lib/hangout/irc/connection.ex:319` in `dispatch("NICK", ...)`, and `lib/hangout/channel_server.ex:200` in `handle_call({:agent_message, ...})`
- Category: security
- Severity: high
- What's wrong: the LiveView nick-change handler revokes the current agent token after `ChannelServer.change_nick/3`, but the server-side nick-change operation itself does not revoke or migrate agent tokens. IRC nick changes call `ChannelServer.change_nick/3` directly, so an active token for `oldnick` remains valid after the participant becomes `newnick`. `ChannelServer.agent_message/3` only checks room mute state, body size, and secrets; it does not check that `owner_nick` is still a current member.
- Impact: after an IRC user changes nick, their old invite URL can still receive room events, can be invoked with `@oldnick🤖`, and can post messages displayed as `oldnick🤖` even though `oldnick` is no longer in the room. That breaks the one-agent-per-current-nick model and creates misleading attribution.
- How to fix it: move token revocation into `ChannelServer.handle_call({:nick, ...})` so all transports get the same behavior. Revoke `old` before or during the member rename, and optionally reject `agent_message` unless `owner_nick` is present in `state.members`.

### Test run

- Command: `MIX_ENV=test mix run -e '...'`
- Result: blocked before project code ran. Mix 1.19.5 failed to start `Mix.PubSub` because `Mix.Sync.PubSub.subscribe/1` could not open a TCP socket: `:eperm`.
