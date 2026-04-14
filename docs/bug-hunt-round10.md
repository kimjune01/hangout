# Bug Hunt Round 10

Scope read: current agent participation, LiveView, voice, IRC, and registry paths. Findings below exclude R1-R9 and the deferred items.

## Voice participation bugs

### 1. Any joined user can force voice signaling to non-voice participants

- File and function: `lib/hangout_web/live/room_live.ex:373` in `handle_event("voice_signal", ...)`, `lib/hangout/channel_server.ex:405` in `handle_call({:voice_signal, ...})`, and `assets/js/hooks.js:550` in the incoming `voice:signal` handler
- Category: privacy / authorization
- Severity: high
- What's wrong: voice signaling is relayed to any room member by nick. The server does not require the sender to be in `voice_participants`, does not require the target to be in `voice_participants`, and does not validate that the signal corresponds to an active voice session. The browser hook accepts an incoming `offer` by calling `getLocalStream()`, which can prompt for microphone access and create an answer even if the target never clicked Join voice.
- Impact: a malicious joined browser can craft a LiveView `voice_signal` event to any room participant and force an unexpected microphone permission prompt or peer-connection attempt. If the target previously granted microphone permission, the offer path can acquire the mic without a fresh user gesture.
- How to fix it: reject `voice_signal` unless both `from` and `to` are current `voice_participants`, and ideally track allowed peer pairs created by `voice_join`. The client should also ignore `voice:signal` unless it is currently in voice or the signal is part of an explicitly accepted join flow.

### 2. Server-side voice removal does not stop the removed user's microphone

- File and function: `lib/hangout/channel_server.ex:691` in `remove_member/2`, `lib/hangout_web/live/room_live.ex:862` in `apply_event({:voice_left, ...})`, and `assets/js/hooks.js:530` / `assets/js/hooks.js:541`
- Category: privacy / resource cleanup
- Severity: high
- What's wrong: when a voice participant is removed by kick, disconnect, room reset, or another server-side member removal path, `ChannelServer.remove_member/2` broadcasts `{:voice_left, ..., nick}`. `RoomLive.apply_event/2` always pushes the browser event `voice:peer_left`, even when `nick == socket.assigns.nick`; it only flips `in_voice?` server-side. The JavaScript hook tears down the local microphone only on `voice:left`, while `voice:peer_left` merely closes a peer connection and removes remote audio.
- Impact: a user removed from the room while in voice can keep their local `MediaStream` and audio context alive in the page after the server has removed them from `voice_participants`. The UI says they are no longer in voice, but browser microphone capture may continue until the page unloads or the hook is destroyed.
- How to fix it: when handling `{:voice_left, ..., nick}` for the current socket nick, push `voice:left` so the hook calls `teardown()`. Keep `voice:peer_left` for other users. Also call the same teardown path when self is kicked, reset out of the room, or the room ends.

### Test run

- Not run. This round was a static bug hunt; the existing environment has repeatedly blocked Mix test startup with `Mix.Sync.PubSub.subscribe/1` socket `:eperm` in prior rounds.
