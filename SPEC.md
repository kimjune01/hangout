# Hangout — Specification

Implementation target. The blog post (`INPUT.md`) defines the product
philosophy: ephemeral IRC for the browser. This document defines how to
build it.

Ambiguity rules:

1. IRC semantics win on protocol behavior.
2. Phoenix conventions win on implementation.
3. Ephemeral defaults win when persistence is optional.

## Product Shape

Hangout is an IRC-compatible chat product built as a single Phoenix
application. It is three things in one runtime:

- An IRC server that accepts raw TCP connections on port 6667 (standard
  IRC wire protocol, RFC 2812). For bots, traditional IRC clients
  (WeeChat, irssi, HexChat), and any process that speaks IRC.
- A Phoenix WebSocket bridge on port 4000 (Phoenix Channels, driven by
  LiveView). For the browser client.
- A Phoenix LiveView web client where visiting a room URL joins the room.

A room is a room, not a workspace. A user clicks a link, picks a nick,
talks, and leaves. When the last human leaves, the room disappears. No
signup, no app install, no durable history by default.

Both connection types converge on the same in-memory channel state. A
message sent by a bot over TCP appears in the LiveView client. A message
sent in the browser appears on the IRC connection. The bridge is internal
to the Phoenix process, not a separate service.

The URL is the room credential:

```
https://hangout.site/<channel>
https://hangout.site/calc-study
```

The path component maps to an IRC channel. The canonical IRC channel name
is `#calc-study`. The public URL omits the leading `#` because URL
fragments already use that character.

## System Architecture

### Runtime

One Phoenix application owns the whole system. No separate IRC daemon.
Phoenix is the IRCd.

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

The application exposes:

- HTTP routes for room pages, capability links, and static assets.
- LiveView routes for the web client.
- Phoenix Channels / LiveView events for browser-side chat transport.
- Raw IRC listener on TCP for bots and traditional IRC clients.
- Internal PubSub for channel message fan-out.
- Supervised GenServers for channel state.

### Process Model

The core process model follows OTP conventions:

- `Hangout.Application` starts the supervision tree.
- `HangoutWeb.Endpoint` serves HTTP, WebSocket, and LiveView.
- `Hangout.IRC.Listener` accepts raw IRC sockets (Ranch TCP acceptor).
- `Hangout.IRC.Connection` is one process per IRC client connection.
- `Hangout.ChannelSupervisor` (DynamicSupervisor) supervises channel
  processes.
- `Hangout.ChannelServer` is one GenServer per live IRC channel.
- `Hangout.ChannelRegistry` maps canonical channel names to PIDs via
  `Registry`.
- `Hangout.NickRegistry` maps active nicks to connection/session PIDs.
- `Hangout.BotSupervisor` supervises first-party bots if enabled.

```elixir
# Registry lookup
{:via, Registry, {Hangout.ChannelRegistry, "#calc-study"}}
```

Room processes are created lazily on first join and terminated when the
room lifecycle says the channel is dead.

### Supervision Tree

```
Application
└── Supervisor
    ├── Registry (Hangout.ChannelRegistry)
    ├── Registry (Hangout.NickRegistry)
    ├── DynamicSupervisor (Hangout.ChannelSupervisor)
    │   └── ChannelServer (one per active channel)
    ├── IRC.Listener (Ranch TCP acceptor)
    ├── BotSupervisor (optional)
    └── Endpoint (Phoenix HTTP/WS)
```

### ChannelServer State

Each ChannelServer GenServer holds:

- `name` -- channel name (string, e.g. `"#calc-study"`)
- `slug` -- URL slug (string, e.g. `"calc-study"`)
- `members` -- map of nick to `%Participant{}`
- `buffer` -- bounded ring buffer of `%Message{}` structs
- `created_at` -- DateTime
- `expires_at` -- DateTime or `nil` (no TTL)
- `creator_public_key` -- string or `nil`
- `mod_capability_hash` -- binary hash of the capability token
- `topic` -- string or `nil`
- `modes` -- map of active channel modes
- `human_count` -- integer
- `bot_count` -- integer

When `human_count` reaches zero, the GenServer terminates and the channel
is gone.

### Storage

Default storage is memory only.

No message table exists. No durable event stream, search index, transcript
table, analytics lake, or chat-history object store is created.

No Ecto. No database driver. No Redis. No external state store.

The server may persist small operational records that are not message
history:

- Abuse-control counters with short TTL.
- Server configuration.

If persistence is introduced for operational records, every item must have
an explicit TTL. Message bodies, private messages, notices, joins, parts,
nick changes, and channel membership history are never persisted.

### Restart Semantics

Ephemeral state dies on deploy or crash.

A server restart destroys:

- Live rooms.
- In-memory room buffers.
- Membership state.
- Topic state.
- Channel modes.
- Bot context tied to room buffers.
- Capability tokens.

This is correct behavior -- it is the same as every participant leaving
simultaneously. Hangout is not a workspace with recovery semantics.

Single-node deployment. No clustering in the first implementation.

## Channel Lifecycle

### Names

Channel names: `#[a-z0-9-]{3,48}`. Lowercase ASCII letters, digits, and
hyphens. No leading hyphen. No trailing hyphen. No Unicode normalization.
No case folding downstream of request parse.

The `#` prefix is implicit in URLs. The URL path `calc-study` maps to IRC
channel `#calc-study`.

```
/calc-study  -> #calc-study
/event-qna   -> #event-qna
/room-42     -> #room-42
```

Raw IRC clients join `#calc-study` directly. Browser clients visit
`/calc-study`.

IRC channel name semantics apply for protocol behavior. The web slug
grammar is stricter than IRC to keep URLs human-safe.

### Creation

A channel is created when the first participant sends `JOIN #<name>`. In
the LiveView client, visiting `hangout.site/calc-study` sends `JOIN
#calc-study` implicitly.

Creation sources:

- Browser visit to a valid room URL.
- Raw IRC `JOIN #room`.
- Bot connection joining a room (only if a human is already present or
  bot-creation is explicitly configured).

The first human participant becomes the room creator. The server generates
a capability URL at creation time:

```
https://hangout.site/calc-study?mod=<128-bit-hex-token>
```

This URL is shown once in the LiveView UI ("Share this link to moderate")
and sent as a server `NOTICE` to IRC clients. The token is stored only in
the ChannelServer process memory.

### Alive

A channel is alive while at least one human participant is present and the
optional TTL has not expired.

Humans are:

- Browser LiveView sessions.
- Raw IRC connections not marked as bots.

Bots are:

- Connections that send the `BOT` command after registration.
- First-party supervised bot processes.

IRC itself does not distinguish humans and bots. Hangout does so only for
room lifecycle. On the wire, bots are ordinary nicks.

### TTL

A room may have an optional TTL set at creation.

In the LiveView client, a dropdown: "Room expires: never / 1 hour /
2 hours / 4 hours / 1 day".

In IRC, set via the custom `ROOMTTL` command after creation:

```
JOIN #calc-study
ROOMTTL #calc-study 7200
```

The TTL is stored as `expires_at = created_at + ttl_seconds` in the
ChannelServer. A scheduled `Process.send_after(self(), :ttl_expired,
ttl_ms)` handles expiry.

When TTL expires:

1. Server broadcasts `:hangout NOTICE #channel :Room expired`.
2. Server sends `PART` to all participants.
3. ChannelServer terminates.
4. All in-memory state is discarded.

TTL is a ceiling, not a persistence promise. Empty rooms die immediately
even if TTL remains.

Channels without TTL live until the last human leaves.

### Decay and Destruction

The channel dies when:

1. **Last human leaves.** The ChannelServer checks `human_count` after
   every PART/QUIT. If no human members remain, it broadcasts a final
   NOTICE and terminates.
2. **TTL expires.** See above.
3. **Creator ends room.** Via capability URL (see Moderation).

On termination: all connected clients receive PART, all TCP connections
for bots in that channel receive PART, the GenServer exits normally, the
DynamicSupervisor removes it. No data is written anywhere. The process
memory is freed. The slug becomes available again immediately.

Bots alone do not keep a room alive.

### Locking and Ending

Moderators may lock or end a room.

Locking (`MODE #channel +i`):

- Existing participants remain.
- New joins are rejected.
- Raw IRC clients receive `ERR_INVITEONLYCHAN (473)`.
- Browser clients see a "room locked" state.

Unlocking (`MODE #channel -i`):

- Re-opens the channel to new joins.

Ending (`END #channel`, custom command):

- All participants receive a final NOTICE and PART.
- The channel is destroyed immediately.

## Identity Model

### No Accounts

No signup. No email. No OAuth. No password. No global profile. No
NickServ. No services account.

### Nick Rules

Standard IRC: 1-16 characters, must start with a letter,
`[a-zA-Z][a-zA-Z0-9_\-\[\]{}\\|^` ]*`. Nicks are unique per-server
(global, not per-channel). Collision returns `ERR_NICKNAMEINUSE (433)`.

### Browser Identity (Keypair)

On first visit, the LiveView client generates an ECDSA P-256 keypair
using the Web Crypto API and stores it in localStorage:

```javascript
const keyPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,   // extractable
  ["sign", "verify"]
);
localStorage.setItem("hangout_keypair", await exportKeyPair(keyPair));
```

The public key is sent to the server during WebSocket connection as a
custom field in the join params. The server does not store it persistently
-- it exists only in the connection's process state.

Uses:

- **Nick recovery.** If a user reconnects with the same public key within
  a 60-second grace window, the server restores their previous nick
  (displacing any squatter).
- **Cross-session continuity.** Same pubkey in a different room = same
  identity. Other users see the same key fingerprint (last 8 hex chars
  displayed as a badge).
- **Moderator association.** The UI remembers that this browser created
  the room.
- **Rate-limit bucketing.** Optional per-key rate limiting.

Non-uses:

- No global profile page.
- No friend graph.
- No cross-room presence directory.
- No server-side social graph.
- No durable user record.

### Key Export

The LiveView UI provides "Export identity" (downloads a JSON file
containing the keypair) and "Import identity" (file picker). This lets
users move between browsers or devices.

### Clearing Identity

Clearing localStorage or using the "New identity" button generates a
fresh keypair. The old identity is irrecoverable. There is no server-side
record.

### IRC Identity

IRC clients have no keypair. Their identity is their nick, per session
only. No persistence across connections.

Standard IRC registration:

```
NICK alice
USER alice 0 * :Alice
```

No PASS required. No SASL for human users.

### Guest Defaults

Browser clients generate a default nick when none is chosen:

```
guest-<short-random>
```

The user can edit it before or after joining. Examples: "quiet-fox",
"green-lamp".

## Message Handling

### Message Types

Core room messages:

- `PRIVMSG #room :text`
- `NOTICE #room :text`
- `ACTION` via CTCP action payload (`\x01ACTION text\x01`)
- `JOIN`, `PART`, `QUIT`, `NICK`, `TOPIC`, `KICK`, `MODE`

Default product scope is text chat. File upload, image upload, voice
messages, reactions, threads, and replies are out of scope.

### Buffer

Each ChannelServer maintains a bounded in-memory ring buffer of the last
**100 messages**. Each entry:

```elixir
%Message{
  id: monotonic_integer,
  at: ~U[2026-04-11 14:30:00Z],
  from: "alice",
  target: "#calc-study",
  kind: :privmsg,
  body: "hello"
}
```

The buffer exists only while the room exists. When the room dies, the
buffer dies.

### Scrollback on Join

When a new participant joins, they receive the current buffer contents.

Browser clients receive the buffer as initial LiveView assigns.

IRC clients receive the buffer as `PRIVMSG` lines with a `NOTICE`
delimiter:

```
:hangout NOTICE #channel :--- scrollback ---
```

This gives late joiners context without persistence.

### Sending

Browser send flow:

1. User submits text.
2. LiveView validates length and connection state.
3. Server maps the event to an internal IRC-style message.
4. Room process applies moderation checks and rate limits.
5. Room process appends to in-memory buffer.
6. Room process broadcasts to Phoenix PubSub topic
   `"channel:#{name}"`.
7. IRC connections receive `:nick!user@host PRIVMSG #channel :text`.
8. LiveView clients receive a `{:new_message, msg}` event pushed via
   the Phoenix Channel.

Raw IRC send flow:

1. Client sends `PRIVMSG #room :text`.
2. IRC connection parser validates command and target.
3. Room process applies moderation checks and rate limits.
4. Room process broadcasts to browser, IRC, and bot participants.

### Limits

Defaults:

```
message_body_max_bytes = 400      # body limit at ChannelServer level
irc_line_max_bytes     = 512      # IRC wire limit including \r\n
message_rate_per_user  = 5 messages / 10 seconds
message_burst          = 10
```

The IRC wire limit (512 bytes including `\r\n`) includes prefix framing
(`:nick!user@host PRIVMSG #channel :`), which consumes ~80-100 bytes.
The ChannelServer enforces a body-only limit of 400 bytes, shared across
all transports. IRC connections enforce the 512-byte wire limit and
extract the body. Browser connections enforce the body limit directly.
Messages exceeding the body limit are rejected.

### Ordering

Ordering is per room process. The room GenServer serializes all events:
joins, parts, nick changes, messages, kicks, mode changes, room
destruction. Global ordering across rooms is undefined.

### Delivery

Best-effort real-time. Fire and forget.

- No acknowledgment, no delivery receipts, no read markers.
- No offline queue. No inbox. No replay after room death.
- If a browser reconnects while the room is still alive, it receives the
  current in-memory buffer. If the room died during disconnect, it
  receives room unavailable.

### Private Messages

IRC `PRIVMSG nick :text` is supported for raw IRC compatibility.

- Private messages are ephemeral and not stored.
- They are not shown in the room UI. Browser MVP omits PM UI.
- They do not create a durable DM relationship or friend list.
- The IRC server handles the protocol command correctly for traditional
  clients and bots.

## IRC Wire Protocol

### Compatibility Target

RFC 2812 is the behavior baseline. The server implements the commands
needed for ephemeral chat. Unsupported commands receive
`ERR_UNKNOWNCOMMAND (421)`.

### Transport

```
irc://host:6667
ircs://host:6697    (production)
```

The browser does not speak raw IRC. It speaks Phoenix LiveView/WebSocket
events mapped to the same internal room model.

### Supported Commands

| Command | Direction | Behavior |
|---------|-----------|----------|
| `NICK <nick>` | C->S | Set or change nick. Collision returns `ERR_NICKNAMEINUSE (433)`. |
| `USER <user> <mode> * :<realname>` | C->S | Required for connection registration. Stored but not displayed. |
| `JOIN #<channel>` | C->S | Join a channel. Creates it if it doesn't exist. Server responds with `JOIN`, `RPL_TOPIC (332)`, `RPL_NAMREPLY (353)`, `RPL_ENDOFNAMES (366)`. |
| `PART #<channel> [:<message>]` | C->S | Leave channel. If last human, channel dies. |
| `PRIVMSG #<channel> :<text>` | C->S | Send message to channel. |
| `PRIVMSG <nick> :<text>` | C->S | Send private message to nick (IRC compat). |
| `PRIVMSG #<channel> :<text>` | S->C | Relay message. Standard `:nick!user@host PRIVMSG #channel :text`. |
| `NOTICE #<channel> :<text>` | Both | Notices. No auto-reply per IRC convention. |
| `QUIT [:<message>]` | C->S | Disconnect. Implicit PART from all channels. |
| `PING <token>` | C->S | Client keepalive. Server replies `PONG :<token>`. |
| `PONG <token>` | C->S | Client keepalive response. |
| `PING :<token>` | S->C | Server keepalive. Client must reply `PONG :<token>`. |
| `NAMES #<channel>` | C->S | List nicks in channel. |
| `TOPIC #<channel>` | C->S | Get channel topic. |
| `TOPIC #<channel> :<text>` | C->S | Set channel topic. Only creator (capability holder) or ops. |
| `KICK #<channel> <nick> [:<reason>]` | C->S | Only via capability URL session (see Moderation). |
| `MODE #<channel> +i` / `-i` | C->S | Lock/unlock channel. Only via capability URL session. |
| `MODE #<channel> +o <nick>` | C->S | Grant operator. Only via capability URL session. |
| `MODE #<channel> +m` / `-m` | C->S | Moderated mode. Only ops can send. |
| `WHO #<channel>` | C->S | Minimal response: nicks and connection info. |
| `WHOIS <nick>` | C->S | Minimal fields: nick, user, host, channels. |
| `LIST` | C->S | Returns empty list (`RPL_LISTEND`). Rooms are non-discoverable by policy (URL-as-credential); LIST is not a discovery surface. |
| `CAP` | C->S | Capability negotiation. Silently handled for client compat. |
| `BOT` | C->S | Custom command. Marks the connection as a bot for lifecycle purposes. |
| `MODAUTH <token>` | C->S | Custom command. Authenticates for moderation (see Moderation). |
| `ROOMTTL #<channel> <seconds>` | C->S | Custom command. Sets room TTL. Only at creation or by mod. |
| `END #<channel>` | C->S | Custom command. Destroys the channel immediately. Requires mod auth. |

### Not Supported

`INVITE`, `OPER`, `AWAY`, `USERHOST`, `CONNECT`, `SQUIT`, `LINKS`,
`STATS`, server-to-server linking, services, DCC, CTCP (except `ACTION`).
These return `ERR_UNKNOWNCOMMAND (421)`.

`CTCP ACTION` (`\x01ACTION text\x01` inside PRIVMSG) is supported and
rendered as `/me text` in the LiveView client.

### Connection Registration Sequence

```
Client: NICK mynick
Client: USER mynick 0 * :My Name
Server: :hangout 001 mynick :Welcome to hangout
Server: :hangout 002 mynick :Your host is hangout
Server: :hangout 003 mynick :This server was created <date>
Server: :hangout 004 mynick hangout 0.1.0 o o
```

No PASS required. No SASL for humans. CAP commands are silently accepted
for compatibility with clients that send them.

Optional IRCv3 capabilities:

- `server-time` -- timestamps on messages for modern clients.
- `echo-message` -- clients see their own sent messages.
- `message-tags` -- structured metadata for bot integrations.

### Core Numerics

Standard numerics returned where practical:

- `001` welcome, `002`-`004` server info.
- `005` ISUPPORT.
- `332` topic, `331` no topic.
- `353` names reply, `366` end of names.
- `372` MOTD line or `422` no MOTD.
- `401` no such nick/channel.
- `403` no such channel.
- `404` cannot send to channel.
- `421` unknown command.
- `431` no nickname given.
- `432` erroneous nickname.
- `433` nickname in use.
- `441` user not in channel.
- `442` not on channel.
- `461` not enough parameters.
- `462` already registered.
- `471` channel full.
- `473` invite-only (locked).
- `482` channel operator privileges needed.

### Message Format

Standard RFC 2812 wire format. Lines terminated by `\r\n`. Max wire
line: 512 bytes including `\r\n`. The ChannelServer enforces a body-only
limit of 400 bytes (see Limits). IRC lines exceeding 512 bytes are
truncated at 510 bytes + `\r\n`.

### Channel Modes

Supported modes:

```
+o  operator
+v  voice
+m  moderated (only ops/voiced can send)
+i  invite-only / locked
+t  topic settable by ops only
+l  user limit
```

Modes are in-memory only and die with the room.

Browser moderation controls map to IRC modes:

- Lock room -> `+i`
- Mute all except allowed speakers -> `+m`
- Promote moderator -> `+o`
- Kick participant -> `KICK`

## LiveView Client

### URL Routing

| URL | Behavior |
|-----|----------|
| `hangout.site/` | Landing page. "Create a room" form: room name (optional, auto-generated if blank), TTL dropdown, create button. |
| `hangout.site/<room-name>` | Join the room. If room doesn't exist, create it. The visitor becomes the creator and receives the mod URL. |
| `hangout.site/<room-name>?mod=<token>` | Join with moderation powers. Invalid tokens join as normal participant. |

### LiveView Module Structure

```
lib/hangout_web/live/
  room_live.ex          -- main chat room
  home_live.ex          -- landing / create room
```

### LiveView State

Per LiveView socket assigns:

```elixir
%{
  channel_slug: "calc-study",
  channel_name: "#calc-study",
  nick: "alice",
  public_key: "...",
  joined?: true,
  participants: [...],
  messages: [...],
  topic: "Calc study group",
  modes: %{},
  moderator?: false,
  notifications_enabled?: false,
  connection_status: :connected
}
```

`messages` is the current in-memory room buffer. It is not loaded from
durable storage.

### Client Events

Browser-to-server:

```
choose_nick, join, part, send_message, change_nick, set_topic,
kick_user, lock_room, unlock_room, end_room,
enable_notifications, disable_notifications
```

Server-to-browser:

```
joined, parted, message, notice, nick_changed, topic_changed,
user_joined, user_parted, user_quit, user_kicked,
modes_changed, room_locked, room_ended, room_expired,
presence_changed, buffer_cleared
```

These are LiveView events, not a stable public API. Third-party clients
use IRC.

### Room UI

No frontend build step. No React. No bundler. LiveView renders
server-side and patches the DOM over WebSocket.

```
┌─────────────────────────────────────┐
│ #calc-study              🔒 ⏱ 1:42 │  <- header: name, lock, TTL
├───────────────────────┬─────────────┤
│                       │ alice       │
│ messages              │ bob         │  <- member list (sidebar)
│ (scrollable)          │ tutor-bot   │
│                       │             │
├───────────────────────┴─────────────┤
│ [nick: alice] [message input] [->]  │  <- input bar
└─────────────────────────────────────┘
```

- Messages scroll to bottom on new message (unless user has scrolled up).
- Nick is editable inline: click to change, Enter to confirm.
- Bot nicks show a robot icon (based on the `bot` flag).
- TTL countdown updates every second via a client-side JS hook. The
  server sends the expiry timestamp; the client counts down locally.
- `/me text` input sends CTCP ACTION.

### Mobile

Responsive. Member list collapses to a top bar showing count ("3 in
room") with tap-to-expand drawer. Message input is fixed to bottom. No
install prompt, no PWA manifest.

### Connection Lifecycle

1. User visits URL.
2. LiveView mounts, connects WebSocket.
3. On `mount/3`: prompt for nick (modal or inline). Default: random
   adjective-noun. If keypair exists in localStorage, send public key
   via JS hook on connect.
4. Server JOINs channel. Scrollback delivered as initial assigns.
5. On tab close / navigate away: WebSocket disconnects, server processes
   QUIT, member removed from channel.
6. On reconnect (network flap): LiveView reconnects automatically. If
   room is alive and nick is available within 60-second grace window,
   reclaim it via pubkey match. If nick was taken, prompt for new nick.
   If room died, show room unavailable.

### JS Hooks

Three hooks registered via `phx-hook`:

| Hook | Purpose |
|------|---------|
| `Scroll` | Auto-scroll to bottom on new messages, scroll-lock detection. |
| `Notifications` | Request permission, fire `new Notification()` on `document.hidden`. |
| `Identity` | Read/write keypair from localStorage. Send pubkey on connect. Handle export/import. |

### UI Principles

The UI should feel like joining a room, not opening a workspace.

- No account wall.
- No persistent sidebar of every room ever joined.
- No global inbox.
- No algorithmic feed.
- No friend list.
- No read receipts.
- No typing indicators.
- No infinite scrollback.
- No "catch up" affordance after room death.
- A clear note that the server does not retain the room after it empties.

## Bot Integration

### How Bots Join

A bot is any process that opens a TCP connection to port 6667 and
completes IRC registration (NICK + USER). It joins channels with standard
`JOIN`.

```
NICK tutor
USER tutor 0 * :AI Tutor
BOT
JOIN #calc-study
```

The `BOT` command sets a `bot: true` flag on the connection. This flag
affects only one thing: **bot-only channels die.** On the wire, bots are
ordinary nicks.

If a process does not send `BOT`, it is counted as human. Bots that
forget to self-identify keep rooms alive -- a tolerable failure mode (room
eventually empties when the bot disconnects).

### Bot Context

A bot's context is the channel buffer. The bot receives every `PRIVMSG`
in channels it has joined. It has no access to messages before it joined
beyond the scrollback buffer (last 100 messages). When the channel dies,
the bot's context from that channel is gone from the server's perspective.

Bots presented as part of the Hangout product do not write durable
transcripts. Third-party bots can record anything they see; the social
contract says this plainly.

### Multiple Bots

Multiple bots per channel is the expected configuration. They see each
other's messages. They talk to each other and to humans through the same
channel text. No separate bot API is required.

Examples: tutor bot, moderator bot, summarizer bot, translator bot,
fact-checker bot.

### Bot Permissions

Default bot permissions:

- Join public URL rooms if they know the URL.
- Read channel messages while present.
- Send channel messages.
- Leave or be kicked like any participant.

Privileged bot permissions require explicit configuration:

- Auto-join all rooms.
- Moderate (requires `MODAUTH`).
- Bypass rate limits.

### Recommended Bot Libraries

Any IRC library works: [OpenClaw](https://github.com/openclaw/openclaw)
(LLM-to-IRC bridge), `irc-framework` (JS), `bottom` (Rust), `ExIRC`
(Elixir), `irc` (Python).

## Moderation

### Capability URL

The room creator receives a capability URL containing a 128-bit random
hex token. This URL grants moderation powers. No account, no global
identity, no role system.

```
https://hangout.site/calc-study?mod=a1b2c3d4...
```

The token is verified by hashing and comparing against the ChannelServer's
stored `mod_capability_hash`. The raw token is never retained in server
memory after the capability URL is issued. Whoever has the URL can moderate.

If the browser identity keypair is available, the UI remembers that this
browser created the room and hides the raw capability after first display.
The URL remains the authority.

### Moderation Actions

All moderation actions require the `mod` token (query parameter for
LiveView, `MODAUTH` for IRC).

| Action | Mechanism | Effect |
|--------|-----------|--------|
| **Kick** | `KICK #channel nick :reason` | Target receives PART, is removed. Can rejoin unless locked. |
| **Lock** | `MODE #channel +i` | No new joins. Existing members stay. |
| **Unlock** | `MODE #channel -i` | Re-opens channel to new joins. |
| **Mute** | `MODE #channel +m` | Only ops and voiced users can send. |
| **Set topic** | `TOPIC #channel :text` | Sets the channel topic. |
| **Clear buffer** | Custom: `CLEAR #channel` | Wipes the server-side scrollback buffer. LiveView clients receive a `buffer_cleared` event and remove rendered messages from the DOM. IRC clients receive a `NOTICE` ("scrollback cleared") — already-delivered lines cannot be erased from terminal output. |
| **End room** | Custom: `END #channel` | All participants receive PART. Channel destroyed immediately. |

### LiveView Moderation UI

When a user connects with a valid `mod` token in the URL params, the
LiveView renders additional controls:

- Per-user kick button (icon next to each nick in member list).
- Lock/unlock toggle.
- Mute/unmute toggle.
- "End room" button (with confirmation dialog).

### IRC Moderation

IRC clients authenticate for moderation by sending:

```
MODAUTH <token>
```

after joining. The server hashes the token and compares against the
ChannelServer's `mod_capability_hash`, then grants operator status (`@` prefix in NAMES). Standard `KICK`,
`MODE`, and `TOPIC` then work. `END` and `CLEAR` are custom commands.

### No Persistent Bans

There is no persistent ban. Kick removes a user; they can rejoin unless
the room is locked. Bans (if implemented) use IRC-style masks, are
in-memory only, and die with the room.

```
ban persistence = room lifetime only
```

A persistent ban list contradicts the no-storage promise.

### Rate Limiting

Per-room and per-connection limits keep rooms usable.

Default controls:

- Message rate limit (5 messages / 10 seconds, burst of 10).
- Join/part churn limit.
- Nick-change rate limit.
- Identical-message suppression.
- Maximum participants per room (200).
- Maximum bots per room unless moderator allows more.

Rate-limit failures are local and ephemeral. They do not create durable
reputation.

### Abuse Handling

Hangout cannot promise abuse prevention without identity.

Default abuse stance:

- Moderators can kick, lock, and end.
- Participants can leave.
- Rooms die when empty.
- Edge-level rate limits mitigate floods.
- No global trust system.
- The server avoids retaining content that would create a moderation
  review queue.

## Notifications

Browser Notification API only. No push service, no service worker, no
Firebase, no APNs.

### When Notifications Fire

- A new message arrives in a joined channel while the tab is **not
  focused** (`document.hidden === true`).
- Notification body: `nick: first 100 chars of message`.
- Notification title: `#channel-name`.
- Clicking the notification focuses the tab.

Additional trigger: message contains the user's nick (mention).

### Permission Flow

1. On first message received, if `Notification.permission === "default"`,
   the LiveView client calls `Notification.requestPermission()`.
2. If denied, no further prompts. A small banner says "Notifications
   blocked -- you won't see messages when this tab is in the background."
3. If granted, notifications fire on `document.hidden` messages.

### No Batching

Each message is one notification. No grouping, no summary, no badge
count. The browser's built-in notification replacement (same tag) prevents
flooding:

```javascript
new Notification(`#${channel}`, {
  body: `${nick}: ${text.slice(0, 100)}`,
  tag: channel,
});
```

### Why No Push

Web Push requires a service worker and stored subscriptions. That creates
state outside the room's live presence. Hangout's default is synchronous:
you are in the room or you are not. No offline notification is sent after
the browser disconnects.

## Social Contract

Ephemerality is a social contract, not a technical guarantee.

**The server promises:**

- No database. No log files. No message persistence.
- Messages exist only in GenServer heap memory.
- When the channel process terminates, messages are irrecoverable from
  the server.
- Bots alone do not keep rooms alive.
- No analytics, no telemetry on message content, no third-party scripts.
- Logs do not contain message bodies.
- Debugging data is content-free and short-retention.

**The server does not promise:**

- That other participants won't copy, screenshot, or record.
- That bot processes won't retain conversation externally.
- That network intermediaries won't log traffic.
- That browser extensions won't observe the page.
- Encryption in transit beyond TLS. Messages are plaintext in server
  memory.

**The defaults enforce the contract:**

- No export button. No download transcript.
- No search. No message permalinks.
- The UI has no select-all or copy-conversation affordance (individual
  messages can still be copied via browser).

**The UI states this plainly near room entry:**

```
The room disappears from this server when everyone leaves.
Anyone in the room can still copy or record what they see.
```

## Logging and Observability

Default logs are content-free.

Allowed:

- Process crashes without message payloads.
- Aggregate counts.
- Duration metrics.
- Room process start/stop counts (with hashed room names only if needed).
- IRC command error classes without parameters.
- Rate-limit counters.

Disallowed:

- Message text.
- Private message text.
- Room slugs in plaintext logs.
- Nicknames in plaintext logs.
- IP + room + nick correlation logs.
- Full IRC lines.
- Browser event payloads.
- Analytics scripts.
- Session replay tools.

Production debugging is intentionally harder than in a persistent chat
product. That is part of the product.

## HTTP and Web Routes

### `GET /`

Landing page. "Create a room" form. The product does not require this
page -- a room URL is sufficient to use Hangout.

### `GET /<channel_slug>`

Room entry. Returns 200 with the LiveView room shell. The room may not
exist before LiveView joins; loading the page does not need a separate
REST probe.

### `GET /<channel_slug>?mod=<capability>`

Room entry with moderator capability. The capability is checked after
LiveView mount. Invalid capabilities do not reveal extra room state; the
user joins as a normal participant.

## Data Model

### Room

```elixir
%Hangout.ChannelServer{
  channel_name:       "#calc-study",
  slug:               "calc-study",
  created_at:         ~U[2026-04-11 14:00:00Z],
  expires_at:         ~U[2026-04-11 16:00:00Z],  # or nil
  creator_public_key: "base64...",                # or nil
  mod_capability_hash: <<...>>,                   # hash of capability token
  topic:              "Calc study group",
  modes:              %{i: false, m: false, t: true},
  members:            %{"alice" => %Participant{}, ...},
  buffer:             [...],                      # ring, max 100
  human_count:        2,
  bot_count:          1
}
```

### Participant

```elixir
%Hangout.Participant{
  nick:             "alice",
  user:             "alice",
  realname:         "Alice",
  public_key:       "base64...",        # nil for IRC clients
  transport:        :liveview,          # :liveview | :irc
  bot?:             false,              # set by BOT command; lifecycle only
  pid:              #PID<0.123.0>,
  joined_at:        ~U[2026-04-11 14:05:00Z],
  last_seen_at:     ~U[2026-04-11 14:30:00Z],
  modes:            MapSet.new([:o]),   # operator, voice, etc.
  rate_limit_state: %{}
}
```

### Message

```elixir
%Hangout.Message{
  id:     1,                            # monotonic integer
  at:     ~U[2026-04-11 14:30:00Z],
  from:   "alice",
  target: "#calc-study",
  kind:   :privmsg,                     # :privmsg | :notice | :action | :system
  body:   "hello"
}
```

`Message` is never written to durable storage.

## Acceptance Criteria

A first implementation is complete when:

1. A user can visit `/calc-study`, choose a nick, and join.
2. A second browser can visit the same URL and join the same room.
3. Messages sent from either browser appear in both browsers.
4. A raw IRC client can connect, join `#calc-study`, and exchange
   messages with browser users.
5. A bot that speaks IRC can join as a normal nick and send/receive
   `PRIVMSG`.
6. Nick changes, joins, parts, quits, topics, and kicks behave according
   to IRC expectations.
7. The first human creator can kick, lock, unlock, and end the room using
   a capability URL.
8. When the last human leaves, the room process terminates and its buffer
   is discarded.
9. Bots alone do not keep the room alive.
10. A room TTL, when set, destroys the room at expiry.
11. Browser notifications work for active/backgrounded sessions.
12. No message text is written to durable storage or logs.
13. Invalid or expired room states do not expose historical content.
14. The UI clearly states the ephemerality social contract.

## What Not To Build

- Accounts, password login, OAuth, email invites.
- Friend lists, user profiles, global presence.
- Durable room history, search, infinite scrollback.
- Read receipts, typing indicators, threads, reactions.
- File upload, voice/video chat.
- Message editing, message deletion as a durable workflow.
- Moderation review queues, report inboxes.
- Analytics dashboards.
- Public room directory.
- Offline push, service worker.
- Bot-only rooms that live forever.
- Bots that invisibly observe rooms.
- A separate IRC daemon.
- A separate React SPA or frontend build step.
- A proprietary bot API for normal chat behavior.
- Persistent bans, namespace reservation.
- NickServ, ChanServ.
- Server-side social graph.
- Anything that turns a room into a backlog.

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
  max_channels: 1000,
  reconnect_grace_seconds: 60,
  message_body_max_bytes: 400,         # body limit at ChannelServer
  irc_line_max_bytes: 512,             # IRC wire limit including \r\n
  message_rate_limit: {5, 10_000},     # 5 messages per 10 seconds
  message_burst: 10
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

Single-node. No clustering. If the server restarts, all channels are
gone. This is correct behavior.

Standard Phoenix release:

```
MIX_ENV=prod mix release
```

Runs behind a reverse proxy (nginx/Caddy) that terminates TLS and
forwards TCP :6667 (or :6697 for IRC TLS) and WebSocket :4000.

## License

AGPL-3.0, with attribution to
[Kiwi IRC](https://github.com/kiwiirc/kiwiirc) and
[Halloy](https://github.com/squidowl/halloy).
