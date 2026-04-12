# IRC/Phoenix Reference Research Notes

Date: 2026-04-11

## Search Status

The requested `pageleft.cc` API searches could not be completed from this workspace. All three requested `curl` calls returned no result body at first, and a diagnostic run returned:

```text
curl: (6) Could not resolve host: pageleft.cc
```

The same sandbox DNS issue also affected direct `github.com` access:

```text
curl: (6) Could not resolve host: github.com
```

Because pageleft was unavailable, I used web-indexed public sources as a fallback and treated anything not visible in source as lower-confidence. The only directly relevant Elixir IRC server reference found was ElixIRCd. I did not find a Phoenix-specific IRC server implementation through the available fallback search results.

Requested pageleft queries attempted:

- `phoenix elixir IRC server implementation`
- `ephemeral chat room WebSocket IRC bridge`
- `IRC protocol elixir GenServer ranch TCP`

## Sources Found

### ElixIRCd

- URL: https://www.elixircd.org/
- Source repository: https://github.com/faelgabriel/elixircd
- Title: ElixIRCd
- License: Repository page shows AGPL-3.0; the docs page footer says MIT. Treat this as conflicting source metadata until the repository `LICENSE` file can be fetched directly.
- Relevance: High for Elixir IRC daemon architecture, connection handling, WebSocket IRC transport, IRCv3 support, rate limiting, and testing posture. Medium for Hangout's product because ElixIRCd is a traditional IRCd, not an ephemeral Phoenix room app.

Observed from documentation and repository landing page:

- ElixIRCd is an IRC daemon written in Elixir and targets RFC 1459/RFC 2812 plus IRCv3.
- It supports TCP, TLS, WebSocket, and WebSocket+TLS listeners simultaneously.
- It uses ThousandIsland for TCP/TLS and Bandit for HTTP/WebSocket.
- It stores runtime state in Mnesia/ETS tables via `memento`, including users, channels, user-channel membership, bans, invites, registered nicks/channels, SASL sessions, monitor lists, history, jobs, and metrics.
- It has a central `Dispatcher` module for outbound messages.
- It uses token-bucket rate limiting at connection and message level, with per-command overrides, IP/mask exemptions, violation counters, block windows, and disconnect thresholds.
- It runs a broad test suite with coverage via `mix test --cover`.

Source access limitation: I could view the repository page and docs but could not fetch raw source files because DNS resolution failed in the local sandbox. The notes below therefore avoid claiming exact ElixIRCd implementation details where only docs were available.

## Comparison Against Hangout

### IRC protocol parsing

Hangout hand-rolls IRC line parsing and formatting in `lib/hangout/irc/parser.ex`.

Current behavior:

- `Parser.parse/1` truncates inbound lines to the configured line limit and splits into prefix, command, and parameters.
- `Parser.line/3` centralizes outbound line construction and truncates to 512 bytes including CRLF.
- It handles trailing params with `:` and CTCP ACTION detection.
- It validates Hangout-specific nick and channel grammar.

Code references:

- `lib/hangout/irc/parser.ex:23` parses `{prefix, command, params}`.
- `lib/hangout/irc/parser.ex:76` builds outbound IRC lines.
- `lib/hangout/irc/parser.ex:146` validates nicks.
- `lib/hangout/irc/parser.ex:154` validates Hangout channel names.
- `lib/hangout/irc/parser.ex:183` parses CTCP ACTION.

Reference comparison:

- ElixIRCd appears to implement a much broader IRC and IRCv3 surface. The relevant pattern is not necessarily to import a full IRC library, but to keep parse/format behavior centralized and protocol-tested as the command surface grows.
- Hangout's parser is product-appropriate for the current spec, but parser tests should be expanded with protocol edge cases before more commands are added.

Specific improvements:

- Add direct unit tests for `Hangout.IRC.Parser` round-tripping common IRC lines, malformed prefixes, empty trailing params, multiple spaces, max-length lines, non-CRLF `\n`, CTCP ACTION, and outbound truncation.
- Consider returning `{:ok, parsed}` / `{:error, reason}` from `Parser.parse/1` once malformed input handling matters. Right now bad lines become empty commands or odd params and are handled later as unknown commands.
- Fix the doctest example at `lib/hangout/irc/parser.ex:17`: the sample line includes a prefix, but the expected result says `{nil, ...}`. It should expect the parsed prefix.

### Connection supervision and crash recovery

Hangout's IRC side uses Ranch and one temporary GenServer-ish process per TCP connection.

Current behavior:

- `Hangout.IRC.Listener` creates a Ranch child spec with 10 acceptors and 1000 max connections.
- `Hangout.IRC.Connection` is a Ranch protocol callback and uses `:proc_lib.spawn_link/3` plus `:gen_server.enter_loop/3`.
- The socket runs `active: :once`, `packet: :raw`, and has an internal partial-line buffer.
- On socket close/error the connection process stops normally.
- On connection termination, it parts from joined channels and unregisters the nick.
- `Hangout.ChannelServer` monitors participant PIDs and removes members on `:DOWN`.

Code references:

- `lib/hangout/irc/listener.ex:14` starts Ranch.
- `lib/hangout/irc/connection.ex:37` starts one process per Ranch connection.
- `lib/hangout/irc/connection.ex:47` performs the Ranch handshake and configures TCP options.
- `lib/hangout/irc/connection.ex:68` reads active-once TCP data and splits complete lines.
- `lib/hangout/irc/connection.ex:88` handles `:tcp_closed`.
- `lib/hangout/channel_server.ex:115` monitors participant PIDs.
- `lib/hangout/channel_server.ex:350` handles monitor `:DOWN` cleanup.

Reference comparison:

- ElixIRCd documents the same broad BEAM pattern: one lightweight process per TCP/WebSocket connection, message passing, and supervisor isolation.
- ElixIRCd uses ThousandIsland/Bandit instead of Ranch/Phoenix Endpoint. Ranch is fine here because Hangout already has Phoenix for browser transport and only needs raw TCP for IRC.

Specific improvements:

- Add a connection-level rate limiter before command dispatch, not only message dispatch. ElixIRCd's documented lifecycle rate-limits at accept/connection and message layers.
- Add configurable IP connection caps and connection-rate violation counters. Hangout currently has Ranch `max_connections: 1000`, but no per-IP admission control.
- Cancel `ping_timer` in `Hangout.IRC.Connection.terminate/2`. The process is exiting, so this is not a leak in practice, but explicit cleanup keeps timer behavior clear.
- Consider moving protocol command dispatch out of `Hangout.IRC.Connection` as the command set grows. ElixIRCd's documented central dispatcher suggests a cleaner boundary between connection lifecycle, command handling, and outbound delivery.

### IRC and WebSocket bridge

Hangout bridges IRC and browser clients through `ChannelServer` events and Phoenix PubSub. Browser transport is LiveView rather than a raw IRC-over-WebSocket socket.

Current behavior:

- IRC `JOIN` subscribes the connection to `Phoenix.PubSub` topic `channel:<name>`.
- `ChannelServer.broadcast/2` emits `{:hangout_event, event}` to the same topic.
- IRC connections translate room events into IRC numerics/commands.
- LiveView joins by creating a `Participant` with `transport: :liveview`, subscribes to the same topic, and applies the same events into assigns.

Code references:

- `lib/hangout/irc/connection.ex:99` receives channel events in IRC connections.
- `lib/hangout/irc/connection.ex:370` joins through `ChannelServer.join/3`.
- `lib/hangout/irc/connection.ex:372` subscribes IRC clients to room PubSub.
- `lib/hangout/channel_server.ex:587` broadcasts room events.
- `lib/hangout_web/live/room_live.ex:386` joins browser users through `ChannelServer`.
- `lib/hangout_web/live/room_live.ex:388` subscribes LiveView to room PubSub.
- `lib/hangout_web/live/room_live.ex:434` applies message events to browser state.

Reference comparison:

- ElixIRCd's WebSocket support is IRC-over-WebSocket for browser IRC clients such as KiwiIRC/Gamja. Hangout's browser bridge is not IRC-over-WebSocket; it is app-native LiveView state updates backed by shared room state.
- For Hangout's product, this is a strong fit. It avoids forcing browser UI code to speak IRC while preserving IRC compatibility at the TCP edge.

Specific improvements:

- Document the event contract emitted by `ChannelServer.broadcast/2`. Both IRC and LiveView rely on these tuple shapes, but there is no explicit schema or test module for event compatibility.
- Add integration tests that join one IRC client and one LiveView/browser-side participant, then assert messages, joins, parts, topic changes, kicks, and room-end events cross the bridge both ways.
- If a future requirement is "IRC over WebSocket" for web IRC clients, add it as a separate transport that reuses `Hangout.IRC.Parser` and `Hangout.IRC.Connection`-like command dispatch. Do not replace the LiveView bridge for the first-party app.

### Channel state management

Hangout uses one GenServer per live room. This aligns tightly with the ephemeral product spec.

Current behavior:

- `ChannelServer` is `restart: :temporary`.
- The state holds name, slug, members, bounded queue buffer, topic, modes, human/bot counts, capability hash, TTL timer ref, and next message ID.
- Channels start lazily via `ChannelRegistry.ensure_started/2`.
- A channel stops when the last human leaves.
- Bots cannot create empty rooms and do not keep rooms alive alone.
- Scrollback is bounded with `:queue`.
- Moderator capability tokens are generated only for first human creator and stored as a hash in memory.

Code references:

- `lib/hangout/channel_server.ex:4` marks room processes temporary.
- `lib/hangout/channel_server.ex:14` defines room state.
- `lib/hangout/channel_server.ex:37` lazily ensures a channel exists on join.
- `lib/hangout/channel_server.ex:102` rejects bot-first empty room creation.
- `lib/hangout/channel_server.ex:124` creates the moderator token for the first human.
- `lib/hangout/channel_server.ex:150` parts members and may terminate the room.
- `lib/hangout/channel_server.ex:427` maintains a bounded `:queue` buffer.
- `lib/hangout/channel_server.ex:454` stops when no humans remain.

Reference comparison:

- ElixIRCd uses Mnesia/ETS-style global runtime tables, which is appropriate for a full IRCd but less aligned with Hangout's "room disappears when humans leave" model.
- Hangout's per-room process is simpler and more failure-local. It naturally expresses room lifecycle, TTL, and ephemeral state.

Specific improvements:

- Add race/concurrency tests for simultaneous first joins, simultaneous part/quit, nick changes while messages are in flight, and channel process death during IRC command handling.
- Fix `mark_bot/2`: it sets `participant = %{participant | bot?: true}` and then computes `was_human = !participant.bot?`, which is always false after the update. The human count may not decrement correctly when a joined human marks itself as a bot.
- Consider replacing repeated ad hoc event tuples with small structs such as `%Hangout.Events.Message{}` once the bridge surface grows.

### Rate limiting

Hangout has a simple per-participant token bucket attached to the channel participant state.

Current behavior:

- `RateLimiter.new/3` defaults to `message_rate_limit` and `message_burst`.
- `RateLimiter.check/1` refills by interval and consumes one token.
- `ChannelServer.message/4` checks rate limits before storing and broadcasting.
- Tests verify burst rejection.

Code references:

- `lib/hangout/rate_limiter.ex:29` constructs token buckets.
- `lib/hangout/rate_limiter.ex:49` checks and consumes tokens.
- `lib/hangout/channel_server.ex:164` applies message rate limiting.
- `test/hangout/channel_server_test.exs:260` tests rate-limit rejection.

Reference comparison:

- ElixIRCd's documented rate limiting is more complete: connection-rate token buckets, per-IP connection caps, message-level buckets, per-command overrides, exemptions, disconnect thresholds, and temporary blocks.
- Hangout's current approach is acceptable for the prototype but too narrow for exposed public IRC TCP.

Specific improvements:

- Add connection admission controls in `Hangout.IRC.Listener`/`Hangout.IRC.Connection`: per-IP current connections, connection-rate token bucket, and temporary blocking after repeated violations.
- Add command-level throttles for expensive or abuse-prone commands: `JOIN`, `NICK`, `WHO`, `WHOIS`, `NAMES`, `LIST`, `PRIVMSG`, and custom moderation commands.
- Add a violation counter and disconnect threshold for repeated message floods instead of endlessly returning `NOTICE :Rate limited`.
- Add LiveView-side rate-limit feedback parity. Browser sends currently flow through `ChannelServer.message/4`, but UX and tests should cover the same abuse behavior.

### Testing strategy

Hangout already has useful black-box TCP integration tests and room-state unit tests.

Current behavior:

- `test/hangout/irc_integration_test.exs` opens real TCP sockets, registers IRC clients, joins rooms, exchanges messages, tests nick change, bot marking, moderation, `LIST`, and `QUIT`.
- `test/hangout/channel_server_test.exs` covers bounded buffers, rate limiting, body limits, locked channels, clear, end room, and other room behavior.

Code references:

- `test/hangout/irc_integration_test.exs:6` connects over TCP.
- `test/hangout/irc_integration_test.exs:49` verifies welcome burst.
- `test/hangout/irc_integration_test.exs:61` verifies two IRC clients exchange channel messages.
- `test/hangout/irc_integration_test.exs:117` covers bot lifecycle behavior.
- `test/hangout/irc_integration_test.exs:150` covers IRC moderation.
- `test/hangout/channel_server_test.exs:260` covers message rate limiting.
- `test/hangout/channel_server_test.exs:280` covers body length limits.

Reference comparison:

- ElixIRCd documents running `mix test --cover` and appears to have a larger conformance-oriented test surface because it implements a full IRCd.
- Hangout needs less breadth, but more targeted parser/protocol compliance tests would reduce regressions.

Specific improvements:

- Add parser unit tests and outbound formatter tests independent of TCP.
- Add IRC numeric tests for common error paths: not registered, no nick, nick in use, no such channel, not on channel, invite-only, channel full, moderated room, unknown mode, and insufficient parameters.
- Add fragmentation tests: one IRC command split across multiple TCP packets, multiple commands in one packet, CRLF and LF endings, and overlong lines.
- Add bridge integration tests for IRC-to-LiveView and LiveView-to-IRC event propagation.
- Add property-style tests for line length: every formatter must return at most 512 bytes including CRLF.

## Patterns Worth Adopting

- Centralize outbound dispatch semantics. Hangout already centralizes line formatting in `Parser`, but event-to-wire output is spread across `Hangout.IRC.Connection`. A small outbound adapter module would make IRC numerics and event translation easier to test.
- Add layered rate limiting. Keep the current per-participant message bucket, then add per-IP connection limits and per-command buckets.
- Make protocol compatibility visible. ElixIRCd's docs enumerate supported commands, modes, numerics, and IRCv3 features. Hangout should maintain a small compatibility table in `SPEC.md` or docs as commands are added.
- Keep transport adapters thin. Hangout's core room process is transport-agnostic; IRC and LiveView both converge on `ChannelServer`. Preserve that boundary.

## Things Hangout Already Does Well

- The per-room GenServer model matches the ephemeral product better than a traditional IRCd table model.
- Room shutdown when humans leave is encoded directly in channel lifecycle rather than bolted on externally.
- IRC and browser users share the same room state and PubSub events, so bridge behavior is simple and inspectable.
- Moderator capability tokens are in-memory and hashed, consistent with the no-durable-history philosophy.
- Bounded scrollback uses a queue and explicit max size.
- Tests already exercise real TCP IRC behavior, not only command handler unit tests.

## Highest-Value Next Changes

1. Fix `ChannelServer.mark_bot/2` human-count handling.
2. Add `Hangout.IRC.ParserTest` for parse/format edge cases and line-length guarantees.
3. Add per-IP connection and per-command rate limiting.
4. Extract IRC event/numeric rendering from `Hangout.IRC.Connection` into a testable adapter.
5. Add IRC/LiveView bridge integration tests.

