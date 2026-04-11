# hangout — spec

Implementation target. The blog post defines the product vision;
this doc is how to build it.

## System architecture

One Phoenix application. No separate IRC daemon. The Phoenix
process is the IRCd. It accepts two kinds of connections:

1. **Raw TCP** on port 6667 — standard IRC wire protocol
   (RFC 2812). For bots, traditional IRC clients (WeeChat,
   irssi, HexChat), and any process that speaks IRC.
2. **WebSocket** on port 4000 — Phoenix Channels, driven by
   LiveView. For the browser client.

Both connection types converge on the same in-memory channel
state. A message sent by a bot over TCP appears in the LiveView
client. A message sent in the browser appears on the IRC
connection. The bridge is internal to the Phoenix process, not a
separate service.

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
                  │  Phoenix Channel          │
                  │       ↑                   │
 WebSocket :4000 ┤  LiveView                 │
                  └──────────────────────────┘
```

### Process model

Each channel is a named `GenServer` registered via
`Registry`. Process name: `{:channel, channel_name}`.

```elixir
# Registry lookup
{:via, Registry, {Hangout.ChannelRegistry, "#calc-study"}}
```

**ChannelServer** holds:
- `name` — channel name (string, e.g. `"#calc-study"`)
- `members` — MapSet of `{pid, nick, connection_type}` tuples
- `buffer` — bounded list of `{nick, text, timestamp}` tuples
- `created_at` — DateTime
- `ttl` — integer seconds or `nil` (no TTL)
- `creator_token` — random 128-bit hex string (capability URL secret)
- `locked` — boolean, default `false`

When `members` becomes empty of human participants (see Bots
below), the GenServer terminates and the channel is gone.

### Supervision

```
Application
└── Supervisor
    ├── Registry (Hangout.ChannelRegistry)
    ├── DynamicSupervisor (Hangout.ChannelSupervisor)
    │   └── ChannelServer (one per active channel)
    ├── IRC.Listener (Ranch TCP acceptor)
    └── Endpoint (Phoenix HTTP/WS)
```

## Wire protocol — IRC

Subset of RFC 2812. The server implements only the commands
needed for ephemeral chat. Unsupported commands receive
`ERR_UNKNOWNCOMMAND (421)`.

### Supported commands

| Command | Direction | Behavior |
|---------|-----------|----------|
| `NICK <nick>` | C→S | Set or change nick. Nick rules: 1-16 chars, `[a-zA-Z][a-zA-Z0-9_\-\[\]{}\\|^` ]+`. Collision → `ERR_NICKNAMEINUSE (433)`. |
| `USER <user> <mode> * :<realname>` | C→S | Required for connection registration. Stored but not displayed. |
| `JOIN #<channel>` | C→S | Join a channel. Creates it if it doesn't exist. Server responds with `JOIN`, `RPL_TOPIC (332)` (empty), `RPL_NAMREPLY (353)`, `RPL_ENDOFNAMES (366)`. |
| `PART #<channel> [:<message>]` | C→S | Leave channel. If last human, channel dies. |
| `PRIVMSG #<channel> :<text>` | C→S | Send message to channel. No DMs — `PRIVMSG <nick>` returns `ERR_NOSUCHNICK (401)`. |
| `PRIVMSG #<channel> :<text>` | S→C | Relay message from another participant. Standard `:nick!user@host PRIVMSG #channel :text` format. |
| `QUIT [:<message>]` | C→S | Disconnect. Implicit PART from all channels. |
| `PING <token>` | C→S | Client keepalive. Server replies `PONG :<token>`. |
| `PONG <token>` | S→C | Server keepalive response. |
| `PING :<token>` | S→C | Server keepalive. Client must reply `PONG :<token>`. |
| `NAMES #<channel>` | C→S | List nicks in channel. |
| `TOPIC #<channel>` | C→S | Get channel topic. Topics are ephemeral, set by creator or ops. |
| `TOPIC #<channel> :<text>` | C→S | Set channel topic. Only creator (capability URL holder). |
| `KICK #<channel> <nick> [:<reason>]` | C→S | Only via capability URL session (see Moderation). |
| `MODE #<channel> +i` / `-i` | C→S | Lock/unlock channel. Only via capability URL session. `+i` = invite-only (no new joins). `-i` = open. |

### Not supported

`LIST`, `WHOIS`, `WHO`, `INVITE`, `OPER`, `AWAY`, `USERHOST`,
`NOTICE`, `CONNECT`, `SQUIT`, `LINKS`, `STATS`, server-to-server
linking, services, DCC, CTCP (except `ACTION`). These return 421.

`CTCP ACTION` (`\x01ACTION text\x01` inside PRIVMSG) is supported
and rendered as `/me text` in the LiveView client.

### Connection registration sequence

```
Client: NICK mynick
Client: USER mynick 0 * :My Name
Server: :hangout 001 mynick :Welcome to hangout
Server: :hangout 002 mynick :Your host is hangout
Server: :hangout 003 mynick :This server was created <date>
Server: :hangout 004 mynick hangout 0.1.0 o o
```

No PASS required. No SASL. No CAP negotiation (CAP commands are
silently ignored for compatibility with clients that send them).

### Message format

Standard RFC 2812 wire format. Lines terminated by `\r\n`.
Max line length: 512 bytes including `\r\n` (per RFC). Messages
exceeding this are truncated at 510 bytes + `\r\n`.

## Channel lifecycle

### Creation

A channel is created when the first participant sends `JOIN
#<name>`. In the LiveView client, visiting `hangout.site/calc-
study` sends `JOIN #calc-study` implicitly.

The creating participant's session receives a capability URL:

```
https://hangout.site/calc-study?mod=<128-bit-hex-token>
```

This URL is shown once in the LiveView UI ("Share this link to
moderate") and sent as a server `NOTICE` to IRC clients. The
token is not stored anywhere except the ChannelServer process
memory.

Channel names: `#[a-z0-9\-]{1,48}`. Lowercase, digits, hyphens.
No leading hyphen. The `#` prefix is implicit in URLs — the URL
path `calc-study` maps to IRC channel `#calc-study`.

### Optional TTL

Set at creation time. In the LiveView client, a dropdown:
"Room expires: never / 1 hour / 2 hours / 4 hours / 1 day".

In IRC, set via a custom command during the JOIN:

```
JOIN #calc-study
TOPIC #calc-study :TTL=7200
```

Or via the LiveView room creation form before entering. The TTL
is stored as `created_at + ttl_seconds` in the ChannelServer.

When TTL expires:
1. Server broadcasts `:hangout NOTICE #channel :Room expired`
2. Server sends `PART` to all participants
3. ChannelServer terminates

A scheduled `Process.send_after(self(), :ttl_expired,
ttl_ms)` in the ChannelServer handles this.

### Decay and destruction

The channel dies when:

1. **Last human leaves.** The ChannelServer checks
   `members` after every PART/QUIT. If no human members
   remain (only bots or empty), it broadcasts a final
   NOTICE and terminates.
2. **TTL expires.** See above.
3. **Creator ends room.** Via capability URL (see Moderation).

On termination: all connected clients receive PART, all TCP
connections for bots in that channel receive PART, the
GenServer exits normally, the DynamicSupervisor removes it.
No data is written anywhere. The process memory is freed.

**Bots alone do not keep a room alive.** The ChannelServer
distinguishes human from bot connections by a flag set during
connection registration (see Bots section).

## Identity model

### Nick rules

Standard IRC: 1-16 characters, must start with a letter,
`[a-zA-Z][a-zA-Z0-9_\-\[\]{}\\|^` ]*`. Nicks are unique
per-server (global, not per-channel). Collision returns
`ERR_NICKNAMEINUSE (433)`.

### Keypair identity

On first visit, the LiveView client generates an ECDSA P-256
keypair using the Web Crypto API and stores it in localStorage:

```javascript
const keyPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,   // extractable
  ["sign", "verify"]
);
localStorage.setItem("hangout_keypair", await exportKeyPair(keyPair));
```

The public key is the persistent identity. It is sent to the
server during WebSocket connection as a custom field in the
join params. The server does not store it persistently — it
exists only in the connection's process state and is used for:

1. **Nick recovery.** If a user reconnects with the same
   public key, the server restores their previous nick
   (displacing any squatter).
2. **Cross-session continuity.** Same pubkey in a different
   room = same identity. Other users see the same key
   fingerprint (last 8 hex chars displayed as a badge).

### Key export

The LiveView UI provides "Export identity" (downloads a JSON
file containing the keypair) and "Import identity" (file
picker). This lets users move between browsers or devices.

### Clearing identity

Clearing localStorage or using the "New identity" button
generates a fresh keypair. The old identity is irrecoverable.
There is no server-side record.

### IRC clients

IRC clients have no keypair. Their identity is their nick,
per session only. No persistence across connections.

## Message handling

### Buffer

The ChannelServer maintains a bounded in-memory ring buffer
of the last **100 messages**. Each entry:

```elixir
%{nick: "alice", text: "hello", ts: ~U[2026-04-11 14:30:00Z]}
```

### Scrollback on join

When a new participant joins, they receive the current buffer
contents as `PRIVMSG` lines (standard IRC playback, with a
`NOTICE` delimiter: `:hangout NOTICE #channel :--- scrollback
---`). This gives late joiners context without persistence.

### Delivery model

- Messages are broadcast to all current members via
  `Phoenix.PubSub`. The PubSub topic is `"channel:#{name}"`.
- IRC TCP connections receive the standard `:nick!user@host
  PRIVMSG #channel :text` line.
- LiveView clients receive a `{:new_message, msg}` event
  pushed via the Phoenix Channel.
- No acknowledgment, no delivery receipts, no read markers.
  Fire and forget.

### No persistence

No database. No files. No logs. The buffer lives in the
GenServer's heap. When the process dies, the messages are gone.
There is no WAL, no crash recovery, no replication. This is
the product promise, not a limitation.

## Bot integration

### How bots join

A bot is any process that opens a TCP connection to port 6667
and completes IRC registration (NICK + USER). The USER command
includes a bot flag:

```
USER botname 0 * :Bot Name
```

Bots self-identify by sending a custom IRC command after
registration:

```
BOT
```

This sets a `bot: true` flag on the connection in the
ChannelServer's member list. The flag affects only one thing:
**bot-only channels die.**

If a process does not send `BOT`, it is counted as human.
Bots that forget to self-identify keep rooms alive — a
tolerable failure mode (room eventually empties when the bot
disconnects).

### Context model

A bot's context is the channel buffer. The bot receives every
`PRIVMSG` in channels it has joined. It has no access to
messages before it joined beyond the scrollback buffer (last
100 messages). When the channel dies, the bot's context from
that channel is gone from the server's perspective. The bot
process may retain its own memory — that is outside the
server's control and outside the server's promise.

### Multiple bots

Multiple bots per channel is the expected configuration. They
see each other's messages. They can talk to each other. The
server does not mediate bot-to-bot communication — it is just
PRIVMSG like everything else.

### Recommended bot framework

[OpenClaw](https://github.com/openclaw/openclaw) bridges LLMs
to IRC. Any IRC library works: `irc-framework` (JS),
`bottom` (Rust), `ExIRC` (Elixir), `irc` (Python).

## Moderation

### Capability URL

The room creator receives a capability URL containing a
128-bit random hex token. This URL grants moderation powers.
No account, no global identity, no role system.

```
https://hangout.site/calc-study?mod=a1b2c3d4...
```

The token is verified against the ChannelServer's stored
`creator_token` on every moderation action.

### Actions

All moderation actions require the `mod` token, sent as a
query parameter (WebSocket join params for LiveView, or as a
custom IRC command for TCP clients).

| Action | Mechanism | Effect |
|--------|-----------|--------|
| **Kick** | `KICK #channel nick :reason` | Target receives PART, is removed from channel. Can rejoin unless locked. |
| **Lock** | `MODE #channel +i` | No new joins. Existing members stay. Bots already in the channel stay. |
| **Unlock** | `MODE #channel -i` | Re-opens the channel to new joins. |
| **End room** | Custom: `END #channel` | All participants receive PART. Channel destroyed immediately. |

### LiveView moderation UI

When a user connects with a valid `mod` token in the URL
params, the LiveView renders additional controls:

- Per-user kick button (icon next to each nick in member list)
- Lock/unlock toggle
- "End room" button (with confirmation dialog)

### IRC moderation

IRC clients authenticate for moderation by sending:

```
MODAUTH <token>
```

after joining. The server validates the token against the
ChannelServer and grants operator status (`@` prefix in
NAMES). Standard `KICK` and `MODE +i/-i` then work. `END` is
a custom command.

### No ban list

There is no ban. Kick removes a user; they can rejoin unless
the room is locked. This is intentional — the room is
ephemeral. A persistent ban list contradicts the no-storage
promise.

## Notifications

Browser Notification API only. No push service, no service
worker, no Firebase, no APNs.

### When notifications fire

- A new message arrives in a joined channel while the tab is
  **not focused** (`document.hidden === true`).
- Notification body: `nick: first 100 chars of message`.
- Notification title: `#channel-name`.
- Clicking the notification focuses the tab.

### Permission flow

1. On first message received, if `Notification.permission ===
   "default"`, the LiveView client calls
   `Notification.requestPermission()`.
2. If denied, no further prompts. A small banner says
   "Notifications blocked — you won't see messages when this
   tab is in the background."
3. If granted, notifications fire on `document.hidden` messages.

### No batching

Each message is one notification. No grouping, no summary, no
badge count. The browser's built-in notification replacement
(same tag) prevents flooding — use `tag: channel_name` so
each channel replaces its previous notification.

```javascript
new Notification(`#${channel}`, {
  body: `${nick}: ${text.slice(0, 100)}`,
  tag: channel,
});
```

## LiveView client

### URL routing

| URL | Behavior |
|-----|----------|
| `hangout.site/` | Landing page. "Create a room" form: room name (optional, auto-generated if blank), TTL dropdown, create button. |
| `hangout.site/<room-name>` | Join the room. If room doesn't exist, create it. The visitor becomes the creator and receives the mod URL. |
| `hangout.site/<room-name>?mod=<token>` | Join with moderation powers. |

Room name in URL maps to IRC channel `#<room-name>`.

### LiveView module structure

```
lib/hangout_web/live/
  room_live.ex          — main chat room
  home_live.ex          — landing / create room
```

### Room UI

No frontend build step. No React. No bundler. LiveView
renders server-side and patches the DOM over WebSocket.

Layout:
```
┌─────────────────────────────────────┐
│ #calc-study              🔒 ⏱ 1:42 │  ← header: name, lock icon, TTL countdown
├───────────────────────┬─────────────┤
│                       │ alice       │
│ messages              │ bob         │  ← member list (right sidebar)
│ (scrollable)          │ tutor-bot 🤖│
│                       │             │
├───────────────────────┴─────────────┤
│ [nick: alice] [message input] [⏎]  │  ← input bar
└─────────────────────────────────────┘
```

- Messages scroll to bottom on new message (unless user has
  scrolled up — standard chat scroll-lock behavior).
- Nick is editable inline: click to change, Enter to confirm.
  Sends NICK command to server.
- Bot nicks show a robot icon (based on the `bot` flag).
- TTL countdown shows remaining time, updates every second
  via a client-side JS hook. The server sends the expiry
  timestamp; the client counts down locally.
- `/me text` input sends CTCP ACTION.

### Mobile

Responsive. Member list collapses to a top bar showing count
("3 in room") with tap-to-expand drawer. Message input is
fixed to bottom. No install prompt, no PWA manifest.

### Connection lifecycle

1. User visits URL.
2. LiveView mounts, connects WebSocket.
3. On `mount/3`: prompt for nick (modal or inline). Default:
   random adjective-noun (e.g., "quiet-fox"). If keypair
   exists in localStorage, send public key via JS hook on
   connect.
4. Server JOIN to channel. Scrollback delivered as initial
   assigns.
5. On tab close / navigate away: WebSocket disconnects,
   server processes QUIT, member removed from channel.
6. On reconnect (network flap): LiveView reconnects
   automatically. Server re-JOINs with same nick if pubkey
   matches.

### JS hooks

Minimal. Three hooks registered via `phx-hook`:

| Hook | Purpose |
|------|---------|
| `Scroll` | Auto-scroll to bottom on new messages, scroll-lock detection. |
| `Notifications` | Request permission, fire `new Notification()` on `document.hidden`. |
| `Identity` | Read/write keypair from localStorage. Send pubkey on connect. Handle export/import. |

## The social contract

Ephemerality is a social contract, not a technical guarantee.

**The server promises:**
- No database. No log files. No message persistence.
- Messages exist only in GenServer heap memory.
- When the channel process terminates, messages are
  irrecoverable from the server.
- No analytics, no telemetry on message content, no third-
  party scripts.

**The server does not promise:**
- That other participants won't copy, screenshot, or record.
- That bot processes won't retain conversation externally.
- That network intermediaries won't log traffic.
- Encryption in transit beyond TLS. Messages are plaintext
  in server memory.

**The defaults enforce the contract:**
- No export button. No download transcript.
- No search. No message permalinks.
- The UI has no select-all or copy-conversation affordance
  (individual messages can still be copied via browser).

## Configuration

```elixir
# config/config.exs
config :hangout,
  irc_port: 6667,
  max_buffer_size: 100,
  max_nick_length: 16,
  max_channel_name_length: 48,
  default_ttl: nil,                    # nil = no TTL
  max_ttl: 86_400,                     # 24 hours
  capability_token_bytes: 16,          # 128-bit mod tokens
  max_members_per_channel: 200,
  max_channels: 1000
```

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:ranch, "~> 2.1"},       # TCP acceptor for IRC
    {:jason, "~> 1.4"},
    {:bandit, "~> 1.0"},      # HTTP server
    {:heroicons, "~> 0.5"},   # icons
    {:tailwind, "~> 0.2"}     # CSS
  ]
end
```

No Ecto. No database driver. No Redis. No external state store.

## Deployment

Single-node. No clustering. If the server restarts, all
channels are gone. This is correct behavior — it is the same
as every participant leaving simultaneously.

Standard Phoenix release:

```
MIX_ENV=prod mix release
```

Runs behind a reverse proxy (nginx/Caddy) that terminates TLS
and forwards TCP :6667 and WebSocket :4000.

## License

AGPL-3.0, with attribution to
[Kiwi IRC](https://github.com/kiwiirc/kiwiirc) and
[Halloy](https://github.com/squidowl/halloy).
