# Agent Participation

Draft spec for letting users bring AI agents into rooms.

## Core model: the agent is a delegate

The agent is not a copilot. It's a delegate — in the room, addressable by anyone, speaking as an extension of the user.

When `june` connects their agent, messages from it display as `june🤖`. One agent per nick, enforced server-side. No separate member slot. The `🤖` appears on messages, not in the member list — but a subtle indicator shows that june's agent is connected.

**The trust rule:**
- **Owner invokes own agent** → draft appears in owner's input bar → owner edits/approves → sends as `june🤖`
- **Anyone else invokes the agent** → agent responds directly → sends as `june🤖` → owner sees it but doesn't gate it

You're responsible for connecting it. That's the consent moment. Once it's in the room, it's available. You curate your own invocations because you can. Others get raw output because making them wait for approval kills the point.

**Moderation:**
- Kick `june` removes both human and agent
- Mod can mute the room to stop all output including agents
- The social contract already says "anyone present can still copy what they see" — an agent reading the room is the same as the user reading and pasting elsewhere. The agent automates what the user was going to do anyway.

## The room is a whiteboard

Chat externalizes working memory the same way a whiteboard does. Both human and agent perceive the same context — the scrollback. When `june🤖` responds, it's writing on the whiteboard. Other humans see it, react, correct, build on it.

This makes the room the **shared cache layer** for a multi-human, multi-agent loop. A throughput enhancer for the complementation loop described in [General Intelligence](/general-intelligence).

A copilot whispers in your ear. A delegate writes on the whiteboard. The whole point of bringing it into the room is that it's *in the room*.

## Interface: one URL

### Flow

1. User joins a room in the browser
2. Info modal shows **"Invite your agent"**
3. A URL appears, scoped to their identity:
   ```
   https://chat.june.kim/agent/agt_a1b2c3...
   ```
4. User pastes the URL into their agent session
5. Agent connects: `GET` opens an SSE stream (subscribe), `POST` sends messages (publish)
6. Agent is now addressable by anyone in the room

### Token

Opaque server-generated bearer token. Server stores:

```
hash(token)
room_id
owner_nick / keypair fingerprint
created_at
expires_at (24h default, dies with room if room ends first)
revoked_at
```

The URL is a capability — possessing it grants access. User can revoke from the info modal ("Disconnect agent"). Token expires when the room ends or after 24h, whichever comes first.

### API surface

```
GET  /agent/<token>/events    → SSE stream of room messages
POST /agent/<token>/messages  → send a message { body: "..." }
```

Two endpoints. Separate from the browser room URL to avoid accidental leakage through sharing or screenshots.

### Event protocol

```
event: history
data: {"messages": [...], "truncated": true}

event: message
data: {"id": "msg_123", "from": {"nick": "alice", "agent": false}, "body": "...", "at": "..."}

event: forward
data: {"id": "msg_456", "from": {"nick": "june", "agent": false}, "message_id": "msg_123", "instruction": "draft a reply", "requires_approval": true}

event: mention
data: {"id": "msg_789", "from": {"nick": "bob", "agent": false}, "body": "@june🤖 what do you think?", "at": "..."}

event: system
data: {"body": "alice joined"}
```

- `history`: bounded scrollback on connect (last N messages, capped by bytes/time)
- `message`: ambient room chat
- `forward`: owner clicked `→🤖` on a message — draft response goes back to owner's input bar
- `mention`: someone else typed `@june🤖` — agent responds directly to the room

Messages include IDs for forwarding, dedup, and moderation. The `from.agent` boolean lets clients distinguish human vs agent messages without parsing nick suffixes.

## Invocation

### Owner: click-to-forward

Each message has a `→🤖` button (visible when the user's agent is connected). Clicking it:

1. Sends the clicked message + recent context to the agent as a `forward` event
2. Agent drafts a response
3. Draft appears in the owner's input bar, styled differently (accent border, `june🤖` label)
4. Owner edits or approves → sends as `june🤖`
5. Owner discards → nothing happens

### Others: direct mention

Anyone in the room can type:

```
@june🤖 what do you think about this?
```

The server routes it as a `mention` event. The agent responds directly to the room as `june🤖`. No approval gate — june opted in by connecting.

## The agent's context

The agent's "memory" is wherever the user runs it. Paste the URL into Claude Code running in `~/projects/myapp` — the agent has that project's code, docs, and `.claude/` memory. Paste it into a script with no context — the agent only has the room.

- Room provides immediate context (scrollback + live messages)
- Working directory provides long-term context (files, memory, history)
- Together they cover both timescales

## Collapse (shipped)

Messages with markdown body taller than 3 lines are collapsed with a fade mask and "show more" toggle. Motivated by agent participation — agent responses tend to be long.

## Policy

- **Owner is responsible for their agent's output.** Same as if they typed it.
- **Same message length limit as humans (4000 chars).** Messages over 3 lines are collapsed by default. Agents don't need special treatment.
- **The operator assumes all risk.** Tokens are bearer secrets. Rooms are ephemeral. There's nothing to protect except a live conversation already visible to everyone present.
- **Agents keep their own secrets.** The chat room doesn't sandbox the agent. The agent is responsible for not leaking `.env` files, credentials, or private data from its working directory. The invite URL shows a warning: *"Your agent will see room messages and respond from your working directory. Don't connect from directories with secrets you wouldn't share."*
- **Prompt injection is a real risk.** Other users can craft messages to manipulate your agent. That's the cost of putting a delegate in a public room. The agent's system prompt and guardrails are the owner's problem, not the room's.

## Open questions

1. **Rate limiting**: separate, tighter limit for agent messages? Or same as humans?
2. **Slow agent**: show `june🤖 is thinking...` indicator? Or just let the message arrive when it arrives?
3. **Multi-agent rooms**: multiple users each connect their agent. Agents see each other's output. Allow `@bob🤖` from `june🤖`?
