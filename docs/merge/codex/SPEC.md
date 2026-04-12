# Hangout — Specification

Implementation target. The blog-post brief in `INPUT.md` defines the
product philosophy: ephemeral IRC for the browser. This document defines
how to build it.

Ambiguity rules:

1. IRC semantics win on protocol behavior.
2. Phoenix conventions win on implementation.
3. Ephemeral defaults win when persistence is optional.

## Product Shape

Hangout is an IRC-compatible chat product built as a Phoenix application.

It is three things in one runtime:

- An IRC server that accepts raw IRC TCP/TLS clients.
- A Phoenix WebSocket bridge used by the browser client.
- A Phoenix LiveView web client where visiting a room URL joins the room.

A room is a room, not a workspace. A user clicks a link, picks a nick,
talks, and leaves. When the last human leaves, the room disappears. No
signup, no app install, no durable history by default.

The URL is the room credential:

```
https://hangout.example/<channel>
https://hangout.example/calc-study
```

The path component maps to an IRC channel. The canonical IRC channel name
is:

```
#calc-study
```

The public URL omits the leading `#` because URL fragments already use
that character.

## System Architecture

### Runtime

One Phoenix application owns the whole system.

```
Browser LiveView client
        |
        | HTTPS + WebSocket
        v
Phoenix Endpoint
        |
        +-- LiveView process per browser session
        +-- ChannelRegistry
        +-- Presence
        +-- IRC protocol server
        +-- Bot/runtime supervision
        +-- Optional notification fan-out
```

No separate IRC daemon. Phoenix is the IRCd.

The application exposes:

- HTTP routes for room pages, capability links, and static assets.
- LiveView routes for the web client.
- Phoenix Channels or LiveView events for browser-side chat transport.
- Raw IRC listener on TCP/TLS for bots and traditional IRC clients.
- Internal PubSub for channel message fan-out.
- Supervised GenServers for channel state.

### Processes

The core process model follows OTP conventions:

- `Hangout.Application` starts the supervision tree.
- `HangoutWeb.Endpoint` serves HTTP, WebSocket, and LiveView.
- `Hangout.IRC.Listener` accepts raw IRC sockets.
- `Hangout.IRC.Connection` is one process per IRC client connection.
- `Hangout.RoomSupervisor` dynamically supervises room processes.
- `Hangout.Room` is one GenServer per live IRC channel.
- `Hangout.RoomRegistry` maps canonical channel names to room PIDs.
- `Hangout.NickRegistry` maps active nicks to connection/session PIDs.
- `Hangout.BotSupervisor` supervises first-party bots if enabled.
- `Hangout.NotificationSupervisor` handles browser notifications if enabled.

Room processes are created lazily on first join and terminated when the
room lifecycle says the channel is dead.

### Storage

Default storage is memory only.

No message table exists in the default product. No durable event stream,
search index, transcript table, analytics lake, or chat-history object
store is created.

The server may persist small operational records that are not message
history:

- Browser public keys, if an implementation chooses server-side trust
  pinning.
- Room capability hashes, if moderator links need to survive restart.
- Push notification subscriptions, if browser push is later added.
- Abuse-control counters with short TTL.
- Server configuration.

If persistence is introduced for those records, every item must have an
explicit TTL. Message bodies, private messages, notices, joins, parts,
nick changes, and channel membership history are not persisted by default.

### Restart Semantics

Ephemeral state is allowed to die on deploy or crash.

A server restart destroys:

- Live rooms.
- In-memory room buffers.
- Membership state.
- Topic state unless explicitly persisted for a non-default mode.
- Channel modes unless explicitly persisted for a non-default mode.
- Bot context tied to room buffers.

This is acceptable. Hangout is not a workspace with recovery semantics.

If clustering is enabled, rooms should be sharded across nodes through
Phoenix.PubSub, Horde, Swarm, or another OTP-aware registry. The first
implementation should prefer a single-node deployment until product shape
demands clustering.

## Channel Lifecycle

### Names

Public room slugs:

```
channel_slug : [a-z0-9-]{3,32}
```

Rules:

- Lowercase ASCII letters, digits, and hyphen.
- No leading hyphen.
- No trailing hyphen.
- No empty path segments.
- No Unicode normalization games.
- No case folding downstream of request parse.

Canonical IRC channel name:

```
"#" <> channel_slug
```

Examples:

```
/calc-study  -> #calc-study
/event-qna   -> #event-qna
/room-42     -> #room-42
```

Raw IRC clients may join `#calc-study` directly. Browser clients visit
`/calc-study`.

IRC channel name semantics apply for protocol behavior. The web slug
grammar is stricter than IRC to keep URLs human-safe.

### Creation

A channel is created on first successful `JOIN`.

Creation sources:

- Browser visit to a valid room URL.
- Raw IRC `JOIN #room`.
- Bot connection joining a room.

The first human participant becomes the room creator for web moderation
purposes. The server generates creator capabilities at creation time.

Bots alone may create a room only if explicitly configured to do so. By
default, bot-only creation is rejected for browser-facing public rooms so
bot scans cannot populate the room namespace.

### Alive

A channel is alive while at least one human participant is present and
the optional TTL has not expired.

Humans are:

- Browser LiveView sessions.
- Raw IRC connections not marked as bots.

Bots are:

- Connections authenticated with a bot token.
- First-party supervised bot processes.
- IRC clients configured as bot identities.
- Connections that set a server-recognized bot capability during
  registration.

IRC itself does not distinguish humans and bots. Hangout does so only for
room lifecycle and policy. On the wire, bots are ordinary nicks.

### Empty

When the last human leaves:

1. The server sends normal IRC membership events to remaining clients.
2. Bots receive `PART` or are disconnected from the room.
3. The room buffer is discarded.
4. Room modes, topic, membership, bans, mutes, and capabilities are
   discarded unless a non-default persistent mode was explicitly enabled.
5. The room process terminates.
6. The slug becomes available again.

Bots alone do not keep a room alive.

### TTL

A room may have an optional TTL set at creation.

Examples:

- 2-hour exam room.
- 1-day event backchannel.
- 45-minute classroom discussion.

When TTL expires:

1. The server sends a room-ending notice.
2. The server sends `PART` or `KICK`-equivalent disconnect events to
   participants.
3. The room process terminates.
4. All in-memory state is discarded.

Channels without TTL live until the last human leaves.

TTL is a ceiling, not a persistence promise. Empty rooms die immediately
even if TTL remains.

### Locking And Ending

Moderators may lock or end a room.

Locking means:

- Existing participants remain.
- New joins are rejected.
- Raw IRC clients receive an IRC numeric failure consistent with IRC
  channel join errors.
- Browser clients see a generic unavailable room state.

Ending means:

- Participants receive a final notice.
- The channel is destroyed.
- The room slug becomes available according to implementation policy.
  Default: immediately available.

## Identity Model

### No Accounts

No signup. No email. No OAuth. No password. No global profile.

IRC nick rules are the primary user identity model:

- A participant chooses a nick on connect.
- A participant may change nick with `NICK`.
- Nicks are unique among currently connected users.
- Nick collisions are resolved using IRC semantics.
- When a user disconnects, the nick is released.

### Browser Identity

The browser generates a keypair on first visit and stores it locally.

Storage:

```
localStorage.hangout_identity = {
  public_key: string,
  private_key: string,
  created_at: ISO8601
}
```

The public key is a soft continuity signal across rooms and sessions. It
is not an account.

Uses:

- Reclaiming the same nick during a reconnect grace window.
- Associating moderator capability use with the browser that created the
  room.
- Local trust hints in the UI.
- Optional rate-limit bucketing.

Non-uses:

- No global profile page.
- No friend graph.
- No cross-room presence directory.
- No server-side social graph.
- No durable user record by default.

Clearing browser storage makes the participant a new person.

Exporting the key lets a user move continuity to another browser. This is
a convenience, not account recovery.

### IRC Identity

Raw IRC registration follows standard flow:

```
NICK alice
USER alice 0 * :Alice
```

Server behavior follows IRC semantics:

- `NICK` sets or changes nickname.
- `USER` provides username and realname fields.
- Registration completes when required fields are present.
- Duplicate nick returns the appropriate IRC numeric.
- Invalid nick returns the appropriate IRC numeric.
- `QUIT` releases nick and removes the user from joined channels.

No NickServ. No services account. No password registration for humans.

### Guest Defaults

Browser clients should generate a default nick when none is chosen:

```
guest-<short-random>
```

The user can edit it before or after joining.

Nick grammar should be compatible with IRC clients while avoiding UI
breakage:

```
nick : [A-Za-z][A-Za-z0-9_\-\[\]\\`^{}]{0,30}
```

The implementation may be stricter than historical IRC, but raw protocol
responses must remain IRC-compatible.

## Message Handling

### Message Types

Core room messages:

- `PRIVMSG #room :text`
- `NOTICE #room :text`
- `ACTION` via CTCP action payload.
- `JOIN`
- `PART`
- `QUIT`
- `NICK`
- `TOPIC`
- `KICK`
- `MODE`

Default product scope is text chat. File upload, image upload, voice
messages, reactions, threads, and replies are out of scope.

### Buffers

Each room has an in-memory buffer.

Default:

```
buffer_max_messages = 100
buffer_max_age      = room lifetime
```

The buffer exists only while the room exists. It is used for:

- Rendering recent messages to a browser participant after LiveView
  reconnect.
- Providing context to bots.
- Giving newly joined participants a small sense of current conversation
  if room policy allows it.

When the room dies, the buffer dies.

No durable scrollback exists by default.

### Join-Time History

Default browser behavior:

- New participants receive the in-memory buffer for the live room.
- The buffer may include messages sent before they joined.
- The buffer is clearly temporary and disappears with the room.

Raw IRC behavior:

- IRC does not define automatic channel history replay.
- To preserve IRC expectations, raw IRC clients do not receive synthetic
  scrollback unless they negotiate a supported capability.

If this difference is unacceptable for a deployment, set:

```
browser_join_history = false
```

Then LiveView clients see only messages sent after joining.

### Sending

Browser send flow:

1. User submits text.
2. LiveView validates length and connection state.
3. Server maps the event to an internal IRC-style message.
4. Room process applies moderation checks.
5. Room process appends to in-memory buffer.
6. Room process broadcasts to Phoenix subscribers.
7. IRC connections receive `PRIVMSG`.
8. Bots receive the same message as every other participant.

Raw IRC send flow:

1. Client sends `PRIVMSG #room :text`.
2. IRC connection parser validates command and target.
3. Room process applies moderation checks.
4. Room process broadcasts to browser, IRC, and bot participants.

### Limits

Defaults:

```
message_max_bytes     = 2048
message_max_chars     = 1000
message_rate_per_user = 5 messages / 10 seconds
message_burst         = 10
```

IRC line length compatibility matters. Raw IRC clients are constrained by
IRC message framing. Browser clients may allow longer input, but the
server should split or reject in a way that does not produce invalid IRC
output.

Default: reject over-limit browser messages with a local validation error.

### Ordering

Ordering is per room process.

The room GenServer serializes:

- Joins.
- Parts.
- Nick changes as observed by the room.
- Messages.
- Kicks.
- Mode changes.
- Room destruction.

Global ordering across rooms is undefined.

### Delivery

Delivery is best-effort real-time.

No offline queue. No inbox. No replay after room death. No guaranteed
delivery to disconnected clients.

If a browser reconnects while the room is still alive, it may receive the
current in-memory buffer. If the room died during disconnect, it receives
room unavailable.

### Private Messages

IRC `PRIVMSG nick :text` is supported for raw IRC compatibility.

Default product position:

- Private messages are ephemeral.
- They are not stored.
- They are not shown in the room UI unless the browser client implements a
  minimal PM pane.
- They do not create a durable DM relationship.
- They do not create a friend list or inbox.

Browser MVP may omit PM UI. The IRC server should still handle the
protocol command correctly for traditional clients and bots.

## IRC Wire Protocol

### Compatibility Target

RFC 2812 is the behavior baseline. RFC 1459 compatibility is acceptable
where common clients expect it.

The server is not required to implement every IRC extension. It should
implement enough for common bots and clients:

- Connection registration.
- Nick management.
- Channel join/part.
- Channel messages.
- Notices.
- Topics.
- Kicks.
- Basic modes.
- Ping/pong.
- Names list.
- Whois with minimal fields.
- Motd or no-motd numeric.
- Capability negotiation for supported extensions.

### Transport

Raw IRC listeners:

```
irc://host:6667
ircs://host:6697
```

Production should prefer TLS on `6697`.

The browser does not speak raw IRC. It speaks Phoenix LiveView/WebSocket
events mapped to the same internal room model.

### Registration

Expected IRC sequence:

```
CAP LS 302
NICK alice
USER alice 0 * :Alice
CAP END
```

The server may support IRCv3 capability negotiation.

Minimum capabilities:

- `server-time` optional.
- `message-tags` optional.
- `echo-message` optional.
- `sasl` only for bots or admin connections, not human accounts.

Human users do not need SASL.

### Core Numerics

The server should return standard numerics where practical:

- `001` welcome.
- `002`, `003`, `004` server info.
- `005` ISUPPORT.
- `221` user mode.
- `315` end of WHO.
- `324` channel mode.
- `331` no topic.
- `332` topic.
- `353` names reply.
- `366` end of names.
- `372` MOTD line or `422` no MOTD.
- `401` no such nick/channel.
- `403` no such channel.
- `404` cannot send to channel.
- `431` no nickname given.
- `432` erroneous nickname.
- `433` nickname in use.
- `441` user not in channel.
- `442` not on channel.
- `443` user already on channel.
- `461` not enough parameters.
- `462` already registered.
- `471` channel is full if capacity limits apply.
- `473` invite-only if locked/private policy applies.
- `475` bad channel key if room key is enabled.
- `482` channel operator privileges needed.

Exact numeric text may vary. Numeric meaning should not.

### Commands

Minimum command set:

```
CAP
NICK
USER
PING
PONG
JOIN
PART
PRIVMSG
NOTICE
QUIT
NAMES
TOPIC
KICK
MODE
WHO
WHOIS
LIST
```

`LIST` must not become a room discovery surface by default. Since Hangout
rooms are URL-as-credential and ephemeral, default `LIST` returns an empty
list or only public rooms explicitly marked listable.

### Channel Modes

Minimum modes:

```
+o operator
+v voice
+m moderated
+i invite-only / locked
+k key-protected
+l user limit
+t topic settable by ops only
+b ban mask
```

Implementation may keep modes in memory only.

Browser moderation controls map to IRC modes where possible:

- Lock room -> `+i`.
- Set room key -> `+k`.
- Mute all except allowed speakers -> `+m`.
- Promote moderator -> `+o`.
- Kick participant -> `KICK`.

### IRC Extensions

Supported extensions should be negotiated through `CAP`, not assumed.

Recommended first extensions:

- `server-time` so modern clients can render timestamps.
- `echo-message` so clients can display their own sent messages
  consistently.
- `message-tags` if bot integrations need structured metadata.

Do not invent nonstandard raw IRC commands for core product behavior when
an IRC semantic already exists.

## LiveView Client

### Route Model

Routes:

```
GET /                  optional create/join page
GET /:channel_slug     room page
GET /:channel_slug/mod moderator capability page or redirect
```

The primary experience starts at the room.

Visiting `/calc-study`:

1. Validates slug.
2. Loads LiveView.
3. Ensures browser identity keypair exists.
4. Prompts for nick if needed.
5. Joins `#calc-study`.
6. Renders current room state.

### LiveView State

Per LiveView socket assigns:

```
channel_slug
channel_name
nick
public_key
joined?
participants
messages
topic
modes
moderator?
notifications_enabled?
connection_status
```

`messages` is the current in-memory room buffer as delivered to this
session. It is not loaded from durable storage.

### Client Events

Browser-to-server events:

```
choose_nick
join
part
send_message
change_nick
set_topic
kick_user
lock_room
unlock_room
end_room
enable_notifications
disable_notifications
```

Server-to-browser events:

```
joined
parted
message
notice
nick_changed
topic_changed
user_joined
user_parted
user_quit
user_kicked
modes_changed
room_locked
room_ended
room_expired
presence_changed
```

These are LiveView events, not a separate JSON API contract for third
party clients. Third party clients should use IRC.

### Reconnects

LiveView reconnect behavior:

- If the room is still alive, rejoin using the same browser public key and
  last nick if available.
- If the nick is still reserved within a short grace window, reclaim it.
- If the nick was taken, prompt for a new nick or append a suffix.
- If the room died, show room unavailable.
- If the room was locked, allow reconnect for existing participants during
  grace but reject new joins.

Recommended reconnect grace:

```
reconnect_grace = 60 seconds
```

### UI Principles

The UI should feel like joining a room, not opening a workspace.

Required qualities:

- No account wall.
- No persistent sidebar of every room ever joined.
- No global inbox.
- No algorithmic feed.
- No friend list.
- No read receipts.
- No typing indicators by default.
- No infinite scrollback.
- No “catch up” affordance after room death.

The browser may show:

- Current participants.
- Current topic.
- Temporary room messages.
- Bot nicks like ordinary nicks.
- A clear note that the server does not retain the room after it empties.

## Bot Integration

### Bot Identity

A bot is an IRC participant.

It joins with:

```
NICK tutor
USER tutor 0 * :AI Tutor
JOIN #calc-study
```

It sends:

```
PRIVMSG #calc-study :Try factoring the numerator first.
```

On the wire, this is ordinary IRC.

The product may visually mark known bots in the browser UI, but protocol
behavior must not depend on a special bot message type.

### First-Party Bots

First-party bots may be supervised inside the Phoenix app or run as
separate processes that connect over IRC.

Preferred architecture for anything nontrivial:

- Separate bot process.
- Connects over IRC/TLS.
- Authenticates as bot if needed.
- Joins configured rooms.
- Reads the same messages other participants read.
- Sends normal `PRIVMSG` or `NOTICE`.

This keeps the bot integration honest: if it works for first-party bots,
it works for user-provided bots.

### Bot Context

Bot context is the room buffer.

When a bot needs recent context, it uses:

- Messages observed since joining.
- Optional IRC history capability if the server exposes one.
- Browser-equivalent in-memory buffer only while the room lives.

When the room dies, bot context dies.

Bots must not write durable transcripts by default if they are presented
as part of the Hangout product. Third-party bots can record anything they
see; the social contract must say this plainly.

### Multiple Bots

Multiple bots per room are expected.

Examples:

- Tutor bot.
- Moderator bot.
- Summarizer bot.
- Translator bot.
- Fact-checker bot.

Bots talk to humans and to each other through the same channel text. No
separate bot API is required for basic behavior.

### Bot Permissions

Default bot permissions:

- Join public URL rooms if they know the URL.
- Read channel messages while present.
- Send channel messages.
- Leave or be kicked like any participant.

Privileged bot permissions require explicit configuration:

- Auto-join all rooms.
- Moderate.
- Lock rooms.
- End rooms.
- See abuse metadata.
- Bypass rate limits.

## Moderation

### Room Creator Capability

The first human creator receives a moderator capability URL.

Example:

```
https://hangout.example/calc-study?mod=<capability>
```

The capability is random, high entropy, and stored only as a hash if
persisted.

Default capability powers:

- Kick participant.
- Lock room.
- Unlock room.
- End room.
- Set topic.
- Mute participant.
- Clear current in-memory buffer.

The capability is not an account. Whoever has the moderator URL can
moderate.

If the browser identity keypair is available, the UI may remember that
this browser created the room and hide the raw capability after first
display. The URL remains the authority.

### IRC Operators

Raw IRC channel operators map to the same moderation model.

The room creator receives `+o` for IRC purposes. Users with `+o` may use
IRC-native commands:

```
KICK #room nick :reason
MODE #room +m
MODE #room +i
TOPIC #room :New topic
```

Browser moderators use UI controls that produce the same internal room
actions.

### Kicks And Bans

Kick:

- Removes a participant from the room.
- Broadcasts a normal IRC `KICK`.
- Browser client transitions to kicked state.

Ban:

- Uses IRC-style masks where practical.
- For browser users, ban may target active connection ID, public key,
  nick mask, or IP-derived short-lived token.
- Bans are in-memory by default and die with the room.

Default ban persistence:

```
room lifetime only
```

### Rate Limiting

Per-room and per-connection limits exist to keep rooms usable.

Default controls:

- Message rate limit.
- Join/part churn limit.
- Nick-change rate limit.
- Identical-message suppression.
- Maximum participants per room.
- Maximum bots per room unless room moderator allows more.

Rate-limit failures are local and ephemeral. They do not create durable
reputation.

### Abuse Handling

Hangout cannot promise abuse prevention without identity.

Default abuse stance:

- Moderators can kick, lock, and end.
- Participants can leave.
- Rooms die when empty.
- The server avoids retaining content that would create a moderation
  review queue.
- Edge-level rate limits mitigate floods.
- No global trust system is built by default.

A deployment that needs stronger safety can add persistence, reporting,
and identity, but that is a different product mode and must be explicit.

## Notifications

### Browser Notifications

Default notification model uses the Browser Notification API for messages
while the tab is open but backgrounded.

No push service. No service worker. No account-bound notification channel.

Flow:

1. User joins a room.
2. UI asks permission only after meaningful engagement.
3. If permission is granted, background tabs may show local notifications
   for new messages, mentions, or moderator events.
4. Clicking the notification focuses the existing tab.

The notification payload is local to the browser session. The server does
not store notification subscriptions by default.

### Mention Notifications

Default notification trigger:

- Message arrives while tab is backgrounded and contains the user's nick.
- Direct private message arrives.
- Moderator action affects the user.

Optional trigger:

- Any message in a backgrounded room.

No offline notification is sent after the browser disconnects.

### Why No Push By Default

Web Push requires a service worker and stored subscriptions. That creates
state outside the room's live presence. Hangout's default is synchronous:
you are in the room or you are not.

A deployment may add Web Push for event/classroom use, but it must be
explicitly labeled as an extension and all subscriptions must expire with
the room TTL.

## Social Contract

Ephemerality is a server promise, not a physics guarantee.

The server promises:

- It does not durably store room messages by default.
- It does not build a searchable archive.
- It does not create accounts or a social graph.
- It destroys room state when the last human leaves.
- Bots alone do not keep rooms alive.
- Logs do not contain message bodies.
- Debugging data is content-free and short-retention.

The server cannot promise:

- Other participants will not screenshot.
- Other participants will not copy text.
- Other participants will not run logging IRC clients.
- Bots will not retain what they see.
- Browser extensions will not observe the page.
- Network or infrastructure providers have no metadata.
- A malicious deployment operator cannot change the code.

The UI must say this plainly:

```
The room disappears from this server when everyone leaves.
Anyone in the room can still copy or record what they see.
```

This sentence, or equivalent, belongs near room entry and any bot
disclosure.

## Logging And Observability

Default logs must be content-free.

Allowed:

- Process crashes without message payloads.
- Aggregate counts.
- Duration metrics.
- Room process start/stop counts without room names, or with hashed room
  names only if needed.
- IRC command error classes without parameters.
- Rate-limit counters.

Disallowed by default:

- Message text.
- Private message text.
- Room slugs in plaintext logs.
- Nicknames in plaintext logs.
- IP plus room plus nick correlation logs.
- Full IRC lines.
- Browser event payloads.
- Analytics scripts.
- Session replay tools.

Production debugging is intentionally harder than in a persistent chat
product. That is part of the product.

## HTTP And Web Routes

### `GET /`

Optional landing or create/join page.

The product should not require this page. A room URL must be sufficient to
use Hangout.

### `GET /<channel_slug>`

Room entry.

Responses:

```
200 LiveView room shell
404 invalid slug or unavailable static route
```

The room may not exist before the LiveView joins. Loading the page does
not need a separate REST probe.

### `GET /<channel_slug>?mod=<capability>`

Room entry with moderator capability.

The capability is checked after LiveView mount. Invalid capabilities do
not reveal extra room state. The user simply joins as a normal participant
or sees unavailable state, depending on room state.

### Internal LiveView Events

LiveView is the browser protocol. Event names are internal application
API, not a stable public API.

Representative payloads:

```
send_message:
  {
    body: string
  }

choose_nick:
  {
    nick: string,
    public_key: string
  }

kick_user:
  {
    nick: string,
    reason: string | null,
    mod_capability: string | null
  }

lock_room:
  {
    mod_capability: string | null
  }

end_room:
  {
    mod_capability: string | null
  }
```

Server responses are LiveView state updates and pushed events.

## Data Model

Default in-memory room state:

```
Room {
  channel_name        : string
  slug                : string
  created_at          : DateTime
  expires_at          : DateTime | nil
  creator_public_key  : string | nil
  mod_capability_hash : binary | nil
  topic               : string | nil
  modes               : map
  participants        : map nick -> Participant
  bans                : list Ban
  buffer              : ring Message
  bot_count           : int
  human_count         : int
}
```

Participant:

```
Participant {
  nick              : string
  user              : string | nil
  realname          : string | nil
  public_key        : string | nil
  transport         : :liveview | :irc | :bot
  pid               : pid
  joined_at         : DateTime
  last_seen_at      : DateTime
  modes             : set
  rate_limit_state  : struct
}
```

Message:

```
Message {
  id          : monotonic integer
  at          : DateTime
  from        : nick
  target      : channel | nick
  kind        : :privmsg | :notice | :action | :system
  body        : string
}
```

`Message` is never written to durable storage in default mode.

## What Not To Build

- Accounts.
- Password login.
- OAuth.
- Email invites.
- Friend lists.
- User profiles.
- Global presence.
- Durable room history.
- Search.
- Infinite scrollback.
- Read receipts.
- Typing indicators by default.
- Threads.
- Reactions.
- File upload.
- Voice/video chat.
- Message editing.
- Message deletion as a durable moderation workflow.
- Moderation review queues.
- Report inboxes.
- Analytics dashboards.
- Public room directory by default.
- Offline push by default.
- Service worker by default.
- Bot-only rooms that live forever.
- Bots that invisibly observe rooms.
- A separate IRC daemon.
- A separate React SPA.
- A frontend build step unless Phoenix asset defaults require one.
- A proprietary bot API for normal chat behavior.
- Persistent bans by default.
- Namespace reservation.
- NickServ.
- ChanServ.
- Server-side social graph.
- Anything that turns a room into a backlog.

## Implementation Notes

Phoenix conventions win.

Use:

- Phoenix Endpoint for HTTP/WebSocket.
- LiveView for the browser UI.
- PubSub for fan-out.
- DynamicSupervisor for room processes.
- Registry for room and nick lookup.
- GenServer for serialized room state.
- Ranch or Thousand Island for raw TCP IRC listener if needed.
- Telemetry for content-free metrics.

Avoid:

- Database-first design.
- Ecto schemas for messages in default mode.
- Oban jobs for room cleanup.
- Durable queues for chat delivery.
- Client-side state machines that disagree with room process state.

The room process is the source of truth while it exists. When it exits,
the truth is gone.

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
11. Browser notifications work only for active/backgrounded sessions.
12. No message text is written to durable storage or logs.
13. Invalid or expired room states do not expose historical content.
14. The UI clearly states the ephemerality social contract.

## License

AGPL-3.0.

Attribution should acknowledge Kiwi IRC and Halloy as prior art for IRC
web/client experience, while Hangout remains a Phoenix-native IRC server
and LiveView product.

---
