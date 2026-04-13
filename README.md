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

## UX

- **Party metaphor.** Entry screen shows a guest list ("Inside now: alice, bob"). "Step in" to join, "Start the room" if empty. The room layout persists through the join transition — content morphs in place.
- **Anchored transition.** Room layout (header, messages, input) stays fixed. Entry content fades out, chat content fades in. No hard cut.
- **Spacing scale.** 8 CSS custom properties (`--sp-1` through `--sp-8`). All structural gaps use tokens.
- **State completeness.** Empty chat ("No messages yet."), inline send errors, reconnecting banner, room ended/expired screens. Voice mic denial handled with error message.
- **Accessibility.** Semantic landmarks (`<header>`, `<main>`), `aria-label` on all controls, `aria-expanded` on member drawer, `:focus-visible` on all interactive elements, `prefers-reduced-motion` respected, 44px minimum touch targets, theme-aware nick colors with light/dark contrast.
- **iOS keyboard.** `visualViewport` API sets `--vvh` so the input bar stays above the keyboard on mobile Safari.
- **Light/dark mode.** Toggle persists in localStorage. Semantic color tokens adapt. Nick colors have separate light/dark palettes.
- **Conveyance.** System messages for join/leave/nick-change. "You joined as {nick}" confirmation. Voice button labeled "voice"/"leave voice" instead of icon-only.

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

The full product and implementation spec is in [docs/SPEC.md](docs/SPEC.md) (1222 lines). It defines:

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

68 tests covering:

- **Acceptance criteria** (20) — room join, cross-client messaging, moderation, TTL, ephemerality
- **IRC wire protocol** (7) — registration, two-client exchange, BOT, MODAUTH, KICK, LIST, QUIT
- **Parser** (24) — line length property (all formatters ≤ 512 bytes), parse edge cases, NAMES splitting
- **Bridge** (8) — PubSub event shapes, IRC wire output, :user_quit
- **E2E smoke** (9) — LiveView flows, cross-protocol IRC ↔ browser

## Configuration

```bash
# Environment variables (set in systemd unit or .env)
SECRET_KEY_BASE=...       # required in prod
PHX_HOST=chat.june.kim    # your domain
PORT=4000                 # HTTP port
IRC_PORT=6667             # IRC TCP port
DEFAULT_ROOM=june         # optional: skip home page, go straight to this room
```

**Single-room mode:** Set `DEFAULT_ROOM` to run as a personal chat page. Visiting `/` redirects to `/<room>`. The home page is still accessible at `/<any-other-slug>`. Useful for embedding a chat button on a blog — visitors land directly in your room.

## Deploy

Deployed to AWS Lightsail ($3.50/mo) with Caddy for TLS.

```bash
# One-time setup on server
bash deploy/setup.sh

# Each deploy
bash deploy/deploy.sh
```

See `deploy/` for Caddyfile, systemd unit, and setup/deploy scripts with lessons learned.

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
