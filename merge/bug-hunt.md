# Hangout bug hunt

Scope read: every requested file under `lib/` and `test/`.

## Findings

### 1. IRC `TOPIC` on a missing room crashes the connection

- File and line: `lib/hangout/irc/connection.ex:496` and `lib/hangout/irc/connection.ex:514`
- Category: crash
- Severity: high
- What's wrong: `ChannelServer.topic/1` and `ChannelServer.set_topic/3` return `{:error, :no_such_channel}` when the room does not exist. These `case` expressions only match `{:ok, ...}`, `:ok`, `{:error, :chanop_needed}`, and an unreachable `{:error, :not_in_channel}` atom. The `catch :exit` clauses do not help because no exit is raised.
- How to fix it: add `{:error, :no_such_channel}` branches that send numeric `403`, and replace `:not_in_channel` with the actual `:not_on_channel` atom if membership checks are added.

### 2. IRC `KICK` can crash on valid error returns

- File and line: `lib/hangout/irc/connection.ex:531`
- Category: crash
- Severity: high
- What's wrong: `ChannelServer.kick/5` returns `{:error, :not_on_channel}` when the target is missing and `{:error, :no_such_channel}` when the room is missing. The IRC handler matches `{:error, :not_in_channel}` instead, so normal errors fall through to `CaseClauseError`.
- How to fix it: handle `{:error, :not_on_channel}` with numeric `441`, handle `{:error, :no_such_channel}` with numeric `403`, and remove or rename the unreachable `:not_in_channel` branch.

### 3. IRC `WHO` crashes because member modes are lists, not MapSets

- File and line: `lib/hangout/irc/connection.ex:587`
- Category: crash
- Severity: high
- What's wrong: `ChannelServer.who/1` builds `modes: MapSet.to_list(p.modes)` at `lib/hangout/channel_server.ex:336`, but the IRC handler calls `MapSet.member?(entry.modes, :o)`. `MapSet.member?/2` expects a MapSet struct.
- How to fix it: change the check to `if :o in entry.modes, do: "@", else: ""`, or return the original MapSet from `ChannelServer.who/1` and keep public serialization separate.

### 4. Dead connections are removed from ChannelServer but not from clients

- File and line: `lib/hangout/channel_server.ex:376`, `lib/hangout/irc/connection.ex:235`, `lib/hangout_web/live/room_live.ex:532`
- Category: state
- Severity: high
- What's wrong: when a monitored participant process dies, `ChannelServer` broadcasts `{:user_quit, ...}`. Neither IRC connections nor LiveView handle that event, so other clients keep stale members in their NAMES/sidebar state and IRC clients receive no QUIT/PART style update.
- How to fix it: add handlers for `{:user_quit, channel, participant, reason}`. In LiveView, remove the member like `:user_parted`. In IRC, send `Parser.quit(participant.nick, reason)` or a channel `PART` event, then keep local state consistent if the quitting user is self.

### 5. `PART` events with reasons are formatted as invalid IRC

- File and line: `lib/hangout/irc/connection.ex:163`
- Category: protocol
- Severity: high
- What's wrong: the handler builds `"#{channel} :#{reason}"` and passes it as one parameter to `Parser.user_cmd/4`. Because the single parameter contains spaces, `Parser.line/3` prefixes it with another colon, producing a malformed line like `:nick!nick@hangout PART :#room :bye`.
- How to fix it: use the existing `Parser.part(participant.nick, channel, reason)` formatter, or add a multi-param user command formatter and call `line(prefix, "PART", [channel, reason])`.

### 6. Moderated channel sends are silently ignored over IRC

- File and line: `lib/hangout/channel_server.ex:426`, `lib/hangout/irc/connection.ex:454`
- Category: protocol
- Severity: medium
- What's wrong: `ChannelServer.message/4` returns `{:error, :moderated}` for `+m`, but the IRC handler checks for `{:error, :cannot_send}`. IRC clients get no `404 ERR_CANNOTSENDTOCHAN` and the send appears to vanish.
- How to fix it: replace the `:cannot_send` branch with `:moderated`, or standardize the channel server return atom.

### 7. IRC `MODE +l <limit>` cannot work

- File and line: `lib/hangout/irc/connection.ex:612`, `lib/hangout/channel_server.ex:506`
- Category: logic
- Severity: medium
- What's wrong: `handle_channel_mode/3` parses `+l` as a normal boolean mode and calls `ChannelServer.mode(channel, nick, "+", :l)` without the limit argument. `ChannelServer.apply_mode/4` requires the limit in `arg`, so it returns `:bad_mode`.
- How to fix it: add a `mode_atom == :l and adding` branch that reads `List.first(rest)` and calls `ChannelServer.mode(channel_name, state.nick, "+", :l, limit)`. For `-l`, keep passing `nil`.

### 8. IRC mode strings with multiple flags are rejected

- File and line: `lib/hangout/irc/connection.ex:622`
- Category: protocol
- Severity: medium
- What's wrong: RFC-style mode strings such as `+im`, `-it`, or `+ov nick1 nick2` are parsed as one mode name (`"im"`), which maps to `nil` and returns numeric `472`. Real IRC clients often batch modes.
- How to fix it: iterate each mode character in the mode string, consume args for modes that require args (`o`, `v`, `l` when adding), and apply each mode in order.

### 9. NAMES replies are truncated instead of split

- File and line: `lib/hangout/irc/parser.ex:127`
- Category: protocol
- Severity: medium
- What's wrong: `names_reply/3` joins all nicknames into one `353` line and relies on `truncate/1`. Large rooms lose nicknames silently and can truncate in the middle of a nick.
- How to fix it: return a list of `353` lines, chunking nicknames so each line stays under 512 bytes, then send all chunks before `366`.

### 10. Nick validation differs between LiveView/global registry and IRC

- File and line: `lib/hangout/nick_registry.ex:7`, `lib/hangout/irc/parser.ex:208`
- Category: protocol
- Severity: high
- What's wrong: `NickRegistry` accepts spaces inside nicks, but `Parser.valid_nick?/1` rejects them. A LiveView user can choose `Alice Bob`; when bridged to IRC, that nick creates malformed prefixes and command parameters.
- How to fix it: remove the literal space from `@nick_re` in `NickRegistry` and share a single nick validator between `NickRegistry` and `Hangout.IRC.Parser`.

### 11. ChannelServer nick changes can overwrite an existing member

- File and line: `lib/hangout/channel_server.ex:192`
- Category: state
- Severity: high
- What's wrong: `handle_call({:nick, old, new}, ...)` pops `old` and unconditionally `Map.put`s `new`. If `new` is already present in that channel, the existing participant is overwritten and effectively kicked without events.
- How to fix it: before `Map.pop/2` or before `Map.put/3`, reject `new` when `Map.has_key?(state.members, new)` and `old != new`, returning `{:error, :nick_in_use}`.

### 12. LiveView nick changes can leave NickRegistry and ChannelServer out of sync

- File and line: `lib/hangout_web/live/room_live.ex:100`
- Category: state
- Severity: high
- What's wrong: the LiveView handler registers the new nick globally before changing the channel member. If `ChannelServer.change_nick/3` fails, the global nick has already changed while the channel still contains the old nick. The error handler also matches `{:error, :in_use}`, but `NickRegistry.change/3` returns `{:error, :nick_in_use}`.
- How to fix it: guard with `socket.assigns.joined?`, make `ChannelServer.change_nick/3` reject duplicates, and rollback the registry if the channel update fails. Also change the error match to `{:error, :nick_in_use}`.

### 13. IRC nick changes can diverge across multiple joined channels

- File and line: `lib/hangout/irc/connection.ex:296`
- Category: state
- Severity: high
- What's wrong: the handler changes the global `NickRegistry` and local `state.nick` before applying the change to every joined `ChannelServer`. Any channel failure is swallowed with `catch :exit`, so some rooms can still hold the old nick while the connection and registry use the new one.
- How to fix it: validate/apply all channel changes before committing `state.nick`, or add rollback. At minimum, handle `{:error, reason}` returns from `ChannelServer.change_nick/3` and revert `NickRegistry` if any channel fails.

### 14. ChannelServer retains monitors after PART/KICK

- File and line: `lib/hangout/channel_server.ex:115`, `lib/hangout/channel_server.ex:150`, `lib/hangout/channel_server.ex:233`
- Category: state
- Severity: medium
- What's wrong: joins call `Process.monitor(participant.pid)` but the monitor ref is never stored or demonitorized. Users who PART or are KICKed while their connection process stays alive leave monitor refs in the room process until the connection eventually exits.
- How to fix it: store the monitor ref in `Participant` or a parallel `monitor_refs` map, then call `Process.demonitor(ref, [:flush])` when removing a member.

### 15. Repeated `BOT` commands corrupt bot counts

- File and line: `lib/hangout/channel_server.ex:308`
- Category: state
- Severity: medium
- What's wrong: `mark_bot/2` increments `bot_count` every time, even if the participant is already a bot. Repeated `BOT` commands drift `bot_count` above the real member count.
- How to fix it: only increment `bot_count` when `was_human` is true, or call `refresh_counts/1` after updating the participant.

### 16. The IRC input buffer is unbounded for clients that never send a newline

- File and line: `lib/hangout/irc/connection.ex:83`, `lib/hangout/irc/connection.ex:819`
- Category: security
- Severity: high
- What's wrong: `state.buffer <> data` is kept until a newline arrives. A client can stream data without `\r\n` and grow the per-connection binary indefinitely. The parser's 512-byte truncation only happens after a complete line is split.
- How to fix it: after appending data, close with an ERROR or discard once `byte_size(rest) > 510`/configured max. Prefer enforcing IRC's 512-byte line limit before buffering more data.

### 17. Ping keepalive runs only once and accepts any PONG

- File and line: `lib/hangout/irc/connection.ex:121`, `lib/hangout/irc/connection.ex:362`
- Category: logic
- Severity: medium
- What's wrong: registration schedules one `:send_ping`; `handle_info(:send_ping, ...)` does not schedule the next ping, so idle connections are checked once. `PONG` cancels the timeout without validating the token.
- How to fix it: schedule the next `:send_ping` after a valid PONG or after each ping cycle, store the expected token, and only cancel the timeout when the PONG token matches.

### 18. `ChannelRegistry.valid?/1` can raise instead of returning false

- File and line: `lib/hangout/channel_registry.ex:72`, `lib/hangout/channel_registry.ex:78`
- Category: crash
- Severity: medium
- What's wrong: `valid?/1` calls `canonical!/1`, and `canonical!("<<" <> _)` raises. A validator should not crash on malformed input.
- How to fix it: make `valid?/1` use a non-raising canonicalization path, e.g. `with {:ok, canonical} <- canonical(name), do: Regex.match?(..., canonical), else: _ -> false`.

### 19. `ChannelRegistry.lookup/1` and callers can raise on invalid names

- File and line: `lib/hangout/channel_registry.ex:23`, `lib/hangout/channel_server.ex:399`
- Category: crash
- Severity: medium
- What's wrong: `lookup/1` also calls `canonical!/1`. Public APIs such as `ChannelServer.topic/1`, `snapshot/1`, and `part/3` can raise for malformed channel names rather than returning `{:error, :no_such_channel}` or `{:error, :bad_channel}`.
- How to fix it: add safe `canonical/1` and have `lookup/1` return `:error` for invalid input. Keep `canonical!/1` only for places that truly want exceptions.

### 20. `IPLimiter` is not a real supervised worker

- File and line: `lib/hangout/ip_limiter.ex:15`
- Category: state
- Severity: high
- What's wrong: `start_link/0` creates an ETS table and returns `{:ok, self()}` without spawning or linking a child process. The supervisor records the caller's pid as the child, and the ETS owner is not an IPLimiter process. This breaks OTP ownership/restart semantics and makes limiter state lifecycle surprising.
- How to fix it: implement `IPLimiter` as a GenServer that creates the ETS table in `init/1` and returns a real child pid from `GenServer.start_link(__MODULE__, [], name: __MODULE__)`.

### 21. `set_topic` can be called by non-members when `+t` is disabled

- File and line: `lib/hangout/channel_server.ex:213`
- Category: logic
- Severity: medium
- What's wrong: when topic protection is disabled, the condition `authorized?(...) or !state.modes[:t]` allows any caller-provided nick, even one not in the room, to set the topic.
- How to fix it: require membership separately: first check `Map.has_key?(state.members, nick)`, then allow either `!state.modes[:t]` or authorization.

### 22. IRC error numerics are wrong for message length

- File and line: `lib/hangout/irc/connection.ex:432`, `lib/hangout/irc/connection.ex:451`
- Category: protocol
- Severity: low
- What's wrong: overlong messages receive numeric `404 ERR_CANNOTSENDTOCHAN`. The command was syntactically accepted but the text is too long; `417 ERR_INPUTTOOLONG` or a server NOTICE is more accurate.
- How to fix it: send `Parser.numeric(417, state.nick, "Input line was too long")` if targeting RFC-compatible clients, or use a NOTICE consistently.

### 23. `KICK` with too few parameters returns unknown command

- File and line: `lib/hangout/irc/connection.ex:531`, `lib/hangout/irc/connection.ex:754`
- Category: protocol
- Severity: low
- What's wrong: there is no `dispatch("KICK", _params, state)` fallback. `KICK #room` falls to generic `421 Unknown command` instead of `461 KICK :Not enough parameters`.
- How to fix it: add a `dispatch("KICK", _params, state)` clause before the generic clause that sends numeric `461`.

## Test gaps

### 24. MODAUTH integration test does not prove MODAUTH grants privileges

- File and line: `test/hangout/irc_integration_test.exs:150`
- Category: test
- Severity: medium
- What's wrong: the test authenticates the room creator, but the creator is already an operator from first join. The later `KICK` would pass even if `MODAUTH` did nothing.
- How to fix it: have a non-op second client run `MODAUTH <token>` and then successfully `KICK` or `MODE`, while asserting the same action fails before MODAUTH.

### 25. IRC nick-change test passes without checking state propagation

- File and line: `test/hangout/irc_integration_test.exs:100`
- Category: test
- Severity: medium
- What's wrong: `assert output =~ "NICK" or output =~ "newname-irc"` passes on very weak output and does not verify ChannelServer membership, old nick removal, other clients receiving the nick change, or PRIVMSG after the nick change.
- How to fix it: connect a second client in the same room, assert it receives `:old!old@hangout NICK :new`, assert `NAMES` no longer includes the old nick, and send a message from the new nick.

### 26. Parser line-length tests miss semantic truncation bugs

- File and line: `test/hangout/irc/parser_test.exs:47`
- Category: test
- Severity: medium
- What's wrong: the NAMES test only asserts `byte_size <= 512`, so the current implementation can drop nicknames silently and still pass.
- How to fix it: add tests that `names_reply` returns multiple `353` lines, all input nicks appear exactly once across those lines, and each line ends with CRLF and stays within 512 bytes.

### 27. Bridge tests do not cover `:user_quit`

- File and line: `test/hangout/bridge_test.exs:70`
- Category: test
- Severity: low
- What's wrong: bridge tests cover join/part/nick/message shapes, but not the `:user_quit` event emitted by ChannelServer on monitored process death. That gap hides the stale-member bug in both IRC and LiveView clients.
- How to fix it: add a ChannelServer event-shape test for `{:user_quit, ...}` and an IRC wire test asserting a dead participant produces a QUIT/PART line for other clients.

### 28. ChannelServer topic test accidentally tests operator mode, not token auth

- File and line: `test/hangout/channel_server_test.exs:103`
- Category: test
- Severity: low
- What's wrong: the test binds `token` but calls `ChannelServer.set_topic/3` without passing it. It passes because the first joiner is an operator, not because token authorization works.
- How to fix it: either remove the unused token and assert operator-topic behavior explicitly, or use a non-op member plus `ChannelServer.set_topic(channel, nick, topic, token)` to test token auth.
