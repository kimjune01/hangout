defmodule HangoutWeb.RoomLive do
  use Phoenix.LiveView

  alias Hangout.{ChannelServer, ChannelSupervisor, NickRegistry, Participant, Message}

  @adjectives ~w(quiet green bright calm swift bold dark warm cool soft)
  @nouns ~w(fox lamp river cloud storm wind leaf spark wave flame)

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
        participants: %{},
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
        page_title: "##{slug}"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # --- Events from browser ---

  @impl true
  def handle_event("choose_nick", %{"nick" => nick}, socket) do
    nick = String.trim(nick)

    cond do
      nick == "" ->
        {:noreply, put_flash(socket, :error, "Nick cannot be empty")}

      not Hangout.IRC.Parser.valid_nick?(nick) ->
        {:noreply, put_flash(socket, :error, "Invalid nick. Use 1-16 chars starting with a letter.")}

      true ->
        case join_channel(socket, nick) do
          {:ok, socket} -> {:noreply, socket}
          {:error, reason, socket} -> {:noreply, put_flash(socket, :error, format_error(reason))}
        end
    end
  end

  def handle_event("send_message", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" or not socket.assigns.joined? do
      {:noreply, socket}
    else
      # Handle /me commands
      case body do
        "/me " <> action_text ->
          ChannelServer.send_action(socket.assigns.channel_name, socket.assigns.nick, action_text)

        _ ->
          ChannelServer.send_message(socket.assigns.channel_name, socket.assigns.nick, body)
      end

      {:noreply, socket}
    end
  end

  def handle_event("change_nick", %{"nick" => new_nick}, socket) do
    new_nick = String.trim(new_nick)

    cond do
      new_nick == "" or new_nick == socket.assigns.nick ->
        {:noreply, socket}

      not Hangout.IRC.Parser.valid_nick?(new_nick) ->
        {:noreply, put_flash(socket, :error, "Invalid nick")}

      true ->
        case NickRegistry.change(socket.assigns.nick, new_nick, self()) do
          :ok ->
            ChannelServer.change_nick(socket.assigns.channel_name, socket.assigns.nick, new_nick)
            {:noreply, assign(socket, nick: new_nick)}

          {:error, :nick_in_use} ->
            {:noreply, put_flash(socket, :error, "Nick already in use")}
        end
    end
  end

  def handle_event("set_topic", %{"topic" => topic}, socket) do
    if socket.assigns.joined? do
      ChannelServer.set_topic(socket.assigns.channel_name, socket.assigns.nick, topic)
    end

    {:noreply, socket}
  end

  def handle_event("kick_user", %{"nick" => target_nick}, socket) do
    if socket.assigns.moderator? do
      ChannelServer.kick(socket.assigns.channel_name, socket.assigns.nick, target_nick)
    end

    {:noreply, socket}
  end

  def handle_event("lock_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.set_mode(socket.assigns.channel_name, socket.assigns.nick, :i, true)
    end

    {:noreply, socket}
  end

  def handle_event("unlock_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.set_mode(socket.assigns.channel_name, socket.assigns.nick, :i, false)
    end

    {:noreply, socket}
  end

  def handle_event("mute_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.set_mode(socket.assigns.channel_name, socket.assigns.nick, :m, true)
    end

    {:noreply, socket}
  end

  def handle_event("unmute_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.set_mode(socket.assigns.channel_name, socket.assigns.nick, :m, false)
    end

    {:noreply, socket}
  end

  def handle_event("end_room", _params, socket) do
    if socket.assigns.moderator? do
      ChannelServer.end_channel(socket.assigns.channel_name, socket.assigns.nick)
    end

    {:noreply, socket}
  end

  def handle_event("set_public_key", %{"public_key" => pk}, socket) do
    {:noreply, assign(socket, public_key: pk)}
  end

  def handle_event("enable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: true)}
  end

  def handle_event("disable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: false)}
  end

  # --- PubSub messages ---

  @impl true
  def handle_info({:new_message, msg}, socket) do
    messages = socket.assigns.messages ++ [msg]
    # Keep client-side buffer bounded
    messages = if length(messages) > 200, do: Enum.drop(messages, length(messages) - 200), else: messages
    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:user_joined, nick, _channel}, socket) do
    case ChannelServer.get_members(socket.assigns.channel_name) do
      {:ok, members} ->
        sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{nick} joined")
        messages = socket.assigns.messages ++ [sys_msg]
        {:noreply, assign(socket, participants: members, messages: messages)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:user_parted, nick, _channel, _message}, socket) do
    case ChannelServer.get_members(socket.assigns.channel_name) do
      {:ok, members} ->
        sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{nick} left")
        messages = socket.assigns.messages ++ [sys_msg]
        {:noreply, assign(socket, participants: members, messages: messages)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:user_quit, nick, _channel, _reason}, socket) do
    case ChannelServer.get_members(socket.assigns.channel_name) do
      {:ok, members} ->
        sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{nick} quit")
        messages = socket.assigns.messages ++ [sys_msg]
        {:noreply, assign(socket, participants: members, messages: messages)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:user_kicked, _kicker, target, _channel, reason}, socket) do
    sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{target} was kicked: #{reason}")
    messages = socket.assigns.messages ++ [sys_msg]

    if target == socket.assigns.nick do
      NickRegistry.unregister(socket.assigns.nick)
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{socket.assigns.channel_name}")
      {:noreply, assign(socket, joined?: false, participants: %{}, messages: messages)}
    else
      case ChannelServer.get_members(socket.assigns.channel_name) do
        {:ok, members} -> {:noreply, assign(socket, participants: members, messages: messages)}
        _ -> {:noreply, assign(socket, messages: messages)}
      end
    end
  end

  def handle_info({:nick_changed, old_nick, new_nick, _channel}, socket) do
    case ChannelServer.get_members(socket.assigns.channel_name) do
      {:ok, members} ->
        sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{old_nick} is now #{new_nick}")
        messages = socket.assigns.messages ++ [sys_msg]
        {:noreply, assign(socket, participants: members, messages: messages)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:topic_changed, nick, _channel, topic}, socket) do
    sys_msg = Message.new("*", socket.assigns.channel_name, :system, "#{nick} set the topic to: #{topic}")
    messages = socket.assigns.messages ++ [sys_msg]
    {:noreply, assign(socket, topic: topic, messages: messages)}
  end

  def handle_info({:modes_changed, _nick, _channel, mode, value}, socket) do
    modes = Map.put(socket.assigns.modes, mode, value)
    {:noreply, assign(socket, modes: modes)}
  end

  def handle_info({:user_mode_changed, _setter, _target, _channel, _mode, _value}, socket) do
    case ChannelServer.get_members(socket.assigns.channel_name) do
      {:ok, members} -> {:noreply, assign(socket, participants: members)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:room_ended, _channel, reason}, socket) do
    sys_msg = Message.new("*", socket.assigns.channel_name, :system, reason)
    messages = socket.assigns.messages ++ [sys_msg]

    if socket.assigns.nick do
      NickRegistry.unregister(socket.assigns.nick)
    end

    Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{socket.assigns.channel_name}")
    {:noreply, assign(socket, joined?: false, participants: %{}, messages: messages, connection_status: :room_ended)}
  end

  def handle_info({:room_expired, _channel}, socket) do
    if socket.assigns.nick do
      NickRegistry.unregister(socket.assigns.nick)
    end

    Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{socket.assigns.channel_name}")
    {:noreply, assign(socket, joined?: false, participants: %{}, connection_status: :room_expired)}
  end

  def handle_info({:buffer_cleared, _nick, _channel}, socket) do
    {:noreply, assign(socket, messages: [])}
  end

  def handle_info({:ttl_set, _nick, _channel, expires_at}, socket) do
    {:noreply, assign(socket, expires_at: expires_at)}
  end

  def handle_info({:channel_created, _channel, token}, socket) do
    # Store the capability URL for the creator
    {:noreply, assign(socket, mod_capability_url: "/#{socket.assigns.channel_slug}?mod=#{token}")}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <%= if not @joined? do %>
        <%= if @connection_status == :room_ended do %>
          <div class="nick-prompt">
            <h2>Room ended</h2>
            <p style="color: #8b949e; margin-top: 1rem;">This room no longer exists.</p>
            <a href="/" style="color: #58a6ff; margin-top: 1rem; display: inline-block;">Create a new room</a>
          </div>
        <% else %>
          <div class="nick-prompt">
            <h2>{@channel_name}</h2>
            <form phx-submit="choose_nick">
              <input
                type="text"
                name="nick"
                value={@default_nick}
                placeholder="Choose a nick"
                autocomplete="off"
                autofocus
              />
              <button type="submit">Join</button>
            </form>
            <div class="social-contract">
              <p>The room disappears from this server when everyone leaves.</p>
              <p>Anyone in the room can still copy or record what they see.</p>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="header">
          <h1>{@channel_name}</h1>
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
            <span>{map_size(@participants)} in room</span>
          </div>
        </div>

        <%= if @moderator? and @mod_capability_url do %>
          <div style="background: #1c2128; padding: 0.5rem; border-radius: 4px; margin-bottom: 0.5rem; font-size: 0.8rem;">
            <span style="color: #f0883e;">Mod link:</span>
            <code style="color: #58a6ff; word-break: break-all;">{@mod_capability_url}</code>
          </div>
        <% end %>

        <div class="room-layout">
          <div class="messages-panel">
            <div class="messages" id="messages" phx-hook="Scroll" phx-update="append">
              <%= for msg <- @messages do %>
                <div class={"message #{message_class(msg)}"} id={"msg-#{msg.id}"}>
                  <span class="time">{format_time(msg.at)}</span>
                  <%= case msg.kind do %>
                    <% :privmsg -> %>
                      <span class="nick">{msg.from}:</span> {msg.body}
                    <% :action -> %>
                      * <span class="nick">{msg.from}</span> {msg.body}
                    <% :notice -> %>
                      -<span class="nick">{msg.from}</span>- {msg.body}
                    <% :system -> %>
                      {msg.body}
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="input-bar">
              <span style="color: #8b949e; padding: 0.5rem 0; font-size: 0.85rem;">{@nick}</span>
              <form phx-submit="send_message" style="display: flex; flex: 1; gap: 0.5rem;">
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
              <div class="mod-controls">
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
                <button class="danger" phx-click="end_room" data-confirm="End this room? Everyone will be disconnected.">End room</button>
              </div>
            <% end %>
          </div>

          <div class="sidebar">
            <h3>Members ({map_size(@participants)})</h3>
            <%= for {nick, participant} <- @participants do %>
              <div class="nick-entry">
                <%= if Hangout.Participant.operator?(participant) do %>
                  <span class="op-badge">@</span>
                <% end %>
                <span>{nick}</span>
                <%= if participant.bot? do %>
                  <span class="bot-badge">[bot]</span>
                <% end %>
                <%= if @moderator? and nick != @nick do %>
                  <button class="kick-btn" phx-click="kick_user" phx-value-nick={nick} title="Kick">x</button>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>

    <div id="identity-hook" phx-hook="Identity" style="display:none"
      data-channel={@channel_slug}
    ></div>
    """
  end

  # --- Private ---

  defp join_channel(socket, nick) do
    channel_name = socket.assigns.channel_name
    ttl_seconds = socket.assigns.ttl_seconds

    # Register nick globally
    case NickRegistry.register(nick, self()) do
      :ok ->
        # Ensure channel exists
        opts = if ttl_seconds, do: [ttl_seconds: ttl_seconds], else: []

        case ChannelSupervisor.ensure_channel(channel_name, opts) do
          {:ok, _pid} ->
            # Subscribe to PubSub before joining
            Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel_name}")

            participant = Participant.new(nick, :liveview, self(),
              public_key: socket.assigns.public_key
            )

            case ChannelServer.join(channel_name, participant) do
              {:ok, info} ->
                # Check if mod token is valid
                moderator? =
                  if socket.assigns.mod_token do
                    case ChannelServer.mod_auth(channel_name, nick, socket.assigns.mod_token) do
                      :ok -> true
                      _ -> false
                    end
                  else
                    false
                  end

                socket =
                  assign(socket,
                    nick: nick,
                    joined?: true,
                    participants: rebuild_participants(channel_name),
                    messages: info.buffer,
                    topic: info.topic,
                    modes: info.modes,
                    moderator?: moderator?
                  )

                {:ok, socket}

              {:error, reason} ->
                NickRegistry.unregister(nick)
                Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel_name}")
                {:error, reason, socket}
            end

          {:error, reason} ->
            NickRegistry.unregister(nick)
            {:error, reason, socket}
        end

      {:error, :nick_in_use} ->
        {:error, :nick_in_use, socket}
    end
  end

  defp rebuild_participants(channel_name) do
    case ChannelServer.get_members(channel_name) do
      {:ok, members} -> members
      _ -> %{}
    end
  end

  defp generate_nick do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj}-#{noun}"
  end

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp format_time(_), do: ""

  defp message_class(%{kind: :system}), do: "system"
  defp message_class(%{kind: :action}), do: "action"
  defp message_class(_), do: ""

  defp format_error(:nick_in_use), do: "Nick already in use"
  defp format_error(:channel_full), do: "Room is full"
  defp format_error(:invite_only), do: "Room is locked"
  defp format_error(:too_many_channels), do: "Too many active rooms"
  defp format_error(_), do: "Could not join"

  defp parse_ttl(nil), do: nil
  defp parse_ttl("none"), do: nil

  defp parse_ttl(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
end
