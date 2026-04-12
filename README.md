# Hangout

Ephemeral IRC-compatible chat for the browser. No signup, no history, no persistence.

A room is a room — you click a link, pick a nick, talk, and leave. When the last human leaves, the room disappears. Bots don't keep rooms alive.

## What it is

A single Phoenix application that is three things in one runtime:

- **IRC server** on port 6667 (RFC 2812 subset) — for bots, WeeChat, irssi, HexChat
- **WebSocket bridge** on port 4000 (Phoenix Channels/LiveView) — for browsers
- **Web client** — visit a room URL, join immediately

Both transports converge on the same in-memory channel state. A message sent by a bot over TCP appears in the browser. A message sent in the browser appears on the IRC connection.

## Quick start

```bash
mix deps.get
mix phx.server
```

- Browser: http://localhost:4000
- IRC: `irc://localhost:6667`

```
# IRC client
NICK alice
USER alice 0 * :Alice
JOIN #calc-study
PRIVMSG #calc-study :hello
```

## Design decisions

- **No accounts.** Browser identity is a localStorage ECDSA P-256 keypair. IRC identity is nick-per-session.
- **No database.** No Ecto, no Redis, no external state. Messages exist in GenServer heap memory.
- **Ephemeral by default.** Room dies when the last human leaves. Optional TTL.
- **Capability URL moderation.** Room creator gets a `?mod=<token>` URL. No global admin.
- **IRC on day one.** Not "maybe later." Any IRC library works as a bot client.
- **Browser Notification API.** No push service, no service worker.
- **AGPL-3.0.**

## Architecture

```
                  ┌──────────────────────────┐
                  │     Phoenix application   │
                  │                           │
 IRC TCP :6667 ──┤  Ranch acceptor           │
                  │       ↓                   │
                  │  IRC protocol parser      │
                  │       ↓                   │
                  │  ChannelServer (GenServer) ◄── shared state
                  │       ↑                   │
                  │  Phoenix PubSub           │
                  │       ↑                   │
 WebSocket :4000 ┤  LiveView                 │
                  └──────────────────────────┘
```

One GenServer per live room. `restart: :temporary` — when it stops, it's gone.

## Spec

The full product and implementation spec is in [SPEC.md](SPEC.md) (1222 lines). It defines:

- Channel lifecycle (creation, alive, TTL, decay, destruction)
- IRC wire protocol (23 supported commands + 4 custom)
- LiveView client (room UI, mobile responsive, JS hooks)
- Identity model (browser keypair, nick rules, guest defaults)
- Moderation (capability URL, kick, lock, mute, end room)
- Bot integration (BOT command, lifecycle semantics)
- Social contract (what the server promises and doesn't)
- Rate limiting (message, join/part churn, nick change, per-IP connection cap)

## Tests

```bash
mix test
```

58 tests covering:

- **Acceptance criteria** (20) — room join, cross-client messaging, moderation, TTL, ephemerality
- **IRC wire protocol** (7) — registration, two-client exchange, BOT, MODAUTH, KICK, LIST, QUIT
- **Parser** (24) — line length property (all formatters ≤ 512 bytes), parse edge cases, validation
- **Bridge** (7) — PubSub event shapes, IRC wire output from channel events

## IRC commands

| Command | Notes |
|---------|-------|
| NICK, USER | Registration. No PASS required. |
| JOIN, PART, QUIT | Standard. Room created on first JOIN. |
| PRIVMSG, NOTICE | Channel and private messages. |
| TOPIC, KICK, MODE | Moderation (requires capability token via MODAUTH). |
| NAMES, WHO, WHOIS | Presence queries. |
| LIST | Returns empty (rooms are non-discoverable by policy). |
| PING, PONG | Keepalive. |
| CAP | Silently accepted for client compatibility. |
| BOT | Custom. Marks connection for lifecycle (bots don't keep rooms alive). |
| MODAUTH | Custom. Authenticates with capability token. |
| ROOMTTL | Custom. Sets room time-to-live in seconds. |
| END | Custom. Destroys room immediately. |
| CLEAR | Custom. Wipes scrollback buffer. |

## License

AGPL-3.0
