defmodule HangoutWeb.RoomLive do
  use HangoutWeb, :live_view

  alias Hangout.{ChannelServer, NickRegistry, Participant}

  @adjectives ~w(quiet green bright calm swift bold dark warm cool soft)
  @nouns ~w(fox lamp river cloud storm wind leaf spark wave flame)

  # --- Mount & Lifecycle ---

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    channel_name = "##{slug}"
    mod_token = Map.get(params, "mod")
    ttl_seconds = parse_ttl(Map.get(params, "ttl"))

    socket =
      assign(socket,
        channel_slug: slug,
        channel_name: channel_name,
        nick: nil,
        default_nick: generate_nick(),
        public_key: nil,
        joined?: false,
        participants: [],
        messages: [],
        topic: nil,
        modes: %{},
        moderator?: false,
        mod_token: mod_token,
        mod_capability_url: nil,
        notifications_enabled?: false,
        connection_status: :connected,
        expires_at: nil,
        ttl_seconds: ttl_seconds,
        mobile_members_open?: false,
        confirm_end?: false,
        page_title: "##{slug}"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:joined?] do
      ChannelServer.part(socket.assigns.channel_name, socket.assigns.nick, "left")
      NickRegistry.unregister(socket.assigns.nick)
    end

    :ok
  end

  # --- Events from browser ---

  @impl true
  def handle_event("choose_nick", %{"nick" => nick}, socket) do
    nick = String.trim(nick)

    cond do
      nick == "" ->
        {:noreply, put_flash(socket, :error, "Nick cannot be empty")}

      not NickRegistry.valid?(nick) ->
        {:noreply, put_flash(socket, :error, "Invalid nick. Use 1-16 chars starting with a letter.")}

      true ->
        case join_channel(socket, nick) do
          {:ok, socket} -> {:noreply, socket}
          {:error, reason, socket} -> {:noreply, put_flash(socket, :error, human_error(reason))}
        end
    end
  end

  def handle_event("send_message", %{"body" => body}, socket) do
    body = String.trim(body || "")

    if body == "" or not socket.assigns.joined? do
      {:noreply, socket}
    else
      {kind, text} =
        if String.starts_with?(body, "/me ") do
          {:action, String.trim_leading(body, "/me ")}
        else
          {:privmsg, body}
        end

      case ChannelServer.message(socket.assigns.channel_name, socket.assigns.nick, kind, text) do
        {:ok, _msg} -> {:noreply, socket}
        {:error, reason} -> {:noreply, put_flash(socket, :error, human_error(reason))}
      end
    end
  end

  def handle_event("change_nick", %{"nick" => new_nick}, socket) do
    new_nick = NickRegistry.normalize(new_nick)

    with true <- NickRegistry.valid?(new_nick),
         :ok <- NickRegistry.change(socket.assigns.nick, new_nick, %{transport: :liveview}),
         :ok <- ChannelServer.change_nick(socket.assigns.channel_name, socket.assigns.nick, new_nick) do
      {:noreply, assign(socket, nick: new_nick)}
    else
      false -> {:noreply, put_flash(socket, :error, "Invalid nick")}
      {:error, :in_use} -> {:noreply, put_flash(socket, :error, "Nick already in use")}
      _ -> {:noreply, put_flash(socket, :error, "Could not change nick")}
    end
  end

  def handle_event("set_topic", %{"topic" => topic}, socket) do
    if socket.assigns.joined? do
      ChannelServer.set_topic(socket.assigns.channel_name, socket.assigns.nick, topic, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("kick_user", %{"nick" => target_nick}, socket) do
    if socket.assigns.moderator? do
      ChannelServer.kick(socket.assigns.channel_name, socket.assigns.nick, target_nick, "kicked", socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("lock_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "+", :i, nil, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("unlock_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "-", :i, nil, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("mute_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "+", :m, nil, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("unmute_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "-", :m, nil, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("clear_buffer", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.clear(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.mod_token)
    end

    {:noreply, socket}
  end

  def handle_event("end_room", _params, socket) do
    if socket.assigns.confirm_end? do
      if socket.assigns.moderator? do
        ChannelServer.end_room(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.mod_token)
      end

      {:noreply, assign(socket, confirm_end?: false)}
    else
      {:noreply, assign(socket, confirm_end?: true)}
    end
  end

  def handle_event("cancel_end", _params, socket) do
    {:noreply, assign(socket, confirm_end?: false)}
  end

  def handle_event("toggle_members", _params, socket) do
    {:noreply, assign(socket, mobile_members_open?: not socket.assigns.mobile_members_open?)}
  end

  def handle_event("enable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: true)}
  end

  def handle_event("disable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: false)}
  end

  def handle_event("identity_ready", %{"publicKey" => pk}, socket) do
    {:noreply, assign(socket, public_key: pk)}
  end

  # --- PubSub messages ---

  @impl true
  def handle_info({:hangout_event, event}, socket) do
    {:noreply, apply_event(socket, event)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <div id="identity-hook" phx-hook="Identity" style="display:none" data-channel={@channel_slug}></div>

      <%= if not @joined? do %>
        <%= if @connection_status in [:room_ended, :room_expired] do %>
          <div class="room-ended">
            <h2>Room ended</h2>
            <p style="color: var(--muted); margin-top: 1rem;">This room no longer exists.</p>
            <a href="/" style="margin-top: 1rem; display: inline-block;">Create a new room</a>
          </div>
        <% else %>
          <div class="nick-prompt">
            <div class="room-name">{@channel_name}</div>

            <%= if f = @flash["error"] do %>
              <div class="flash error" style="max-width: 20rem; margin: 0 auto 1rem;">{f}</div>
            <% end %>

            <form phx-submit="choose_nick">
              <input
                type="text"
                name="nick"
                value={@default_nick}
                placeholder="Pick a nick"
                autocomplete="off"
                autofocus
              />
              <button type="submit">Step in</button>
            </form>
            <div class="social-contract">
              <p>The room disappears when everyone leaves.</p>
              <p>Anyone present can still copy what they see.</p>
            </div>
          </div>
        <% end %>
      <% else %>
        <%= if f = @flash["error"] do %>
          <div class="flash error">{f}</div>
        <% end %>

        <div class="header">
          <div style="display: flex; align-items: baseline; min-width: 0; overflow: hidden;">
            <h1>{@channel_name}</h1>
            <%= if @topic do %>
              <span class="topic">{@topic}</span>
            <% end %>
          </div>
          <div class="badges">
            <%= if @modes[:i] do %>
              <span class="lock-badge" title="Room is locked">locked</span>
            <% end %>
            <%= if @modes[:m] do %>
              <span title="Room is muted">muted</span>
            <% end %>
            <%= if @expires_at do %>
              <span class="ttl-badge" id="ttl-countdown" phx-hook="TTLCountdown" data-expires-at={DateTime.to_iso8601(@expires_at)}>
                expires {DateTime.to_iso8601(@expires_at)}
              </span>
            <% end %>
            <button class="mobile-member-toggle" phx-click="toggle_members">
              {length(@participants)} in room
            </button>
            <span class="desktop-count member-count">{length(@participants)} in room</span>
          </div>
        </div>

        <%= if @moderator? and @mod_capability_url do %>
          <div class="mod-link-banner">
            <span class="label">Mod link (save this):</span>
            <code>{@mod_capability_url}</code>
          </div>
        <% end %>

        <div class="room-layout">
          <div class="messages-panel">
            <div class="messages" id="messages" phx-hook="Scroll">
              <%= for msg <- @messages do %>
                <div class={"message #{message_class(msg)}"} id={"msg-#{msg.id}"}>
                  <span class="time">{format_time(msg.at)}</span>
                  <%= case msg.kind do %>
                    <% :privmsg -> %>
                      <span class="nick" style={"color: #{nick_color(msg.from)}"}>{msg.from}:</span> {msg.body}
                    <% :action -> %>
                      * <span class="nick" style={"color: #{nick_color(msg.from)}"}>{msg.from}</span> {msg.body}
                    <% :notice -> %>
                      -<span class="nick">{msg.from}</span>- {msg.body}
                    <% :system -> %>
                      {msg.body}
                    <% _ -> %>
                      <span class="nick" style={"color: #{nick_color(msg.from)}"}>{msg.from}:</span> {msg.body}
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="input-bar">
              <span class="nick-label">{@nick}</span>
              <form phx-submit="send_message" style="display: flex; flex: 1;">
                <input
                  type="text"
                  name="body"
                  placeholder="Type a message..."
                  autocomplete="off"
                  autofocus
                  maxlength="400"
                  id="message-input"
                  phx-hook="Notifications"
                />
                <button type="submit">Send</button>
              </form>
            </div>

            <%= if @moderator? do %>
              <details class="mod-controls">
                <summary></summary>
                <div class="mod-buttons">
                  <%= if @modes[:i] do %>
                    <button phx-click="unlock_room">Unlock</button>
                  <% else %>
                    <button phx-click="lock_room">Lock</button>
                  <% end %>
                  <%= if @modes[:m] do %>
                    <button phx-click="unmute_room">Unmute</button>
                  <% else %>
                    <button phx-click="mute_room">Mute</button>
                  <% end %>
                  <button phx-click="clear_buffer">Clear</button>
                  <%= if @confirm_end? do %>
                    <button class="danger" phx-click="end_room">Confirm end</button>
                    <button phx-click="cancel_end">Cancel</button>
                  <% else %>
                    <button class="danger" phx-click="end_room">End room</button>
                  <% end %>
                </div>
              </details>
            <% end %>
          </div>

          <div class={"sidebar#{if @mobile_members_open?, do: " mobile-open", else: ""}"}>
            <h3>Members ({length(@participants)})</h3>
            <%= for member <- @participants do %>
              <div class="nick-entry">
                <%= if :o in (member.modes || []) do %>
                  <span class="op-badge">@</span>
                <% end %>
                <span style={"color: #{nick_color(member.nick)}"}>{member.nick}</span>
                <%= if member.bot? do %>
                  <span class="bot-badge">[bot]</span>
                <% end %>
                <%= if @moderator? and member.nick != @nick do %>
                  <button class="kick-btn" phx-click="kick_user" phx-value-nick={member.nick} title="Kick">x</button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Private: join ---

  defp join_channel(socket, nick) do
    channel_name = socket.assigns.channel_name
    ttl_seconds = socket.assigns.ttl_seconds
    mod_token = socket.assigns.mod_token

    nick = ensure_unique_nick(nick)

    case NickRegistry.register(nick, %{transport: :liveview}) do
      :ok ->
        participant = %Participant{
          nick: nick,
          user: nick,
          realname: nick,
          public_key: socket.assigns.public_key,
          transport: :liveview,
          pid: self()
        }

        join_opts =
          [mod_token: mod_token] ++
            if(ttl_seconds, do: [ttl: ttl_seconds], else: [])

        case ChannelServer.join(channel_name, participant, join_opts) do
          {:ok, snapshot, token} ->
            Phoenix.PubSub.subscribe(Hangout.PubSub, ChannelServer.topic_name(channel_name))

            moderator? =
              token != nil or
                (mod_token != nil and ChannelServer.validate_mod(channel_name, mod_token) == true)

            mod_url = if token, do: "/#{socket.assigns.channel_slug}?mod=#{token}"

            socket =
              assign(socket,
                nick: nick,
                joined?: true,
                participants: snapshot.members,
                messages: snapshot.buffer,
                topic: snapshot.topic,
                modes: snapshot.modes,
                expires_at: snapshot[:expires_at],
                moderator?: moderator?,
                mod_token: mod_token || token,
                mod_capability_url: mod_url
              )

            {:ok, socket}

          {:error, reason} ->
            NickRegistry.unregister(nick)
            {:error, reason, socket}
        end

      {:error, :nick_in_use} ->
        {:error, :nick_in_use, socket}
    end
  end

  defp ensure_unique_nick(nick) do
    nick = NickRegistry.normalize(nick)

    if NickRegistry.valid?(nick) and NickRegistry.lookup(nick) == :error do
      nick
    else
      "guest-#{:rand.uniform(99_999)}"
    end
  end

  # --- Private: event dispatch ---

  defp apply_event(socket, {:message, _channel, msg}) do
    messages = append_message(socket.assigns.messages, msg)

    socket
    |> assign(messages: messages)
    |> push_event("hangout:message", %{from: msg.from, body: msg.body, channel: msg.target})
  end

  defp apply_event(socket, {:notice, channel, from, body}) do
    msg = %Hangout.Message{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(),
      from: from,
      target: channel,
      kind: :notice,
      body: body
    }

    assign(socket, messages: append_message(socket.assigns.messages, msg))
  end

  defp apply_event(socket, {:user_joined, _channel, member}) do
    assign(socket, participants: upsert_member(socket.assigns.participants, member))
  end

  defp apply_event(socket, {:user_parted, _channel, member, _reason}) do
    assign(socket, participants: reject_member(socket.assigns.participants, member.nick))
  end

  defp apply_event(socket, {:user_kicked, _channel, _actor, member, reason}) do
    socket = assign(socket, participants: reject_member(socket.assigns.participants, member.nick))

    if member.nick == socket.assigns.nick do
      NickRegistry.unregister(socket.assigns.nick)
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, ChannelServer.topic_name(socket.assigns.channel_name))
      assign(socket, joined?: false, connection_status: :kicked)
      |> put_flash(:error, "You were kicked: #{reason}")
    else
      socket
    end
  end

  defp apply_event(socket, {:nick_changed, _channel, old, new}) do
    participants =
      Enum.map(socket.assigns.participants, fn member ->
        if member.nick == old, do: %{member | nick: new}, else: member
      end)

    assign(socket, participants: participants)
  end

  defp apply_event(socket, {:topic_changed, _channel, _nick, topic}) do
    assign(socket, topic: topic)
  end

  defp apply_event(socket, {:modes_changed, _channel, modes, _member_modes}) do
    assign(socket, modes: modes)
  end

  defp apply_event(socket, {:buffer_cleared, _channel, _actor}) do
    socket
    |> assign(messages: [])
    |> push_event("hangout:buffer_cleared", %{})
  end

  defp apply_event(socket, {:room_ended, _channel, _actor}) do
    if socket.assigns.nick, do: NickRegistry.unregister(socket.assigns.nick)
    Phoenix.PubSub.unsubscribe(Hangout.PubSub, ChannelServer.topic_name(socket.assigns.channel_name))
    assign(socket, joined?: false, participants: [], connection_status: :room_ended)
  end

  defp apply_event(socket, {:room_expired, _channel}) do
    if socket.assigns.nick, do: NickRegistry.unregister(socket.assigns.nick)
    Phoenix.PubSub.unsubscribe(Hangout.PubSub, ChannelServer.topic_name(socket.assigns.channel_name))
    assign(socket, joined?: false, participants: [], connection_status: :room_expired)
  end

  defp apply_event(socket, {:ttl_changed, _channel, expires_at}) do
    assign(socket, expires_at: expires_at)
  end

  defp apply_event(socket, _event), do: socket

  # --- Private: helpers ---

  defp append_message(messages, msg) do
    messages = messages ++ [msg]
    if length(messages) > 200, do: Enum.drop(messages, length(messages) - 200), else: messages
  end

  defp upsert_member(members, member) do
    [member | reject_member(members, member.nick)] |> Enum.sort_by(& &1.nick)
  end

  defp reject_member(members, nick) do
    Enum.reject(members, &(&1.nick == nick))
  end

  defp generate_nick do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj}-#{noun}"
  end

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp format_time(_), do: ""

  defp message_class(%{kind: :system}), do: "system"
  defp message_class(%{kind: :action}), do: "action"
  defp message_class(%{kind: :notice}), do: "notice"
  defp message_class(_), do: ""

  # Nick color palette — 12 hues readable on dark backgrounds
  @nick_colors [
    "#7cc7b2", "#e0b15d", "#c78dea", "#6cb4ee",
    "#e88b72", "#8dd99b", "#dda0c5", "#b0c862",
    "#7ab8d4", "#d4a76a", "#a0b4e0", "#c9c270"
  ]

  defp nick_color(nick) do
    hash = :erlang.phash2(nick, length(@nick_colors))
    Enum.at(@nick_colors, hash)
  end

  defp human_error(:nick_in_use), do: "Nick already in use"
  defp human_error(:in_use), do: "Nick already in use"
  defp human_error(:channel_full), do: "Room is full"
  defp human_error(:invite_only), do: "Room is locked"
  defp human_error(:too_many_channels), do: "Too many active rooms"
  defp human_error(:body_too_long), do: "Message is too long"
  defp human_error(:rate_limited), do: "Slow down"
  defp human_error(:not_operator), do: "Moderator permission required"
  defp human_error(:moderated), do: "Room is moderated"
  defp human_error(:bot_needs_human), do: "A human must create the room first"
  defp human_error(reason), do: "Could not complete action: #{inspect(reason)}"

  defp parse_ttl(nil), do: nil
  defp parse_ttl("none"), do: nil

  defp parse_ttl(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
end
