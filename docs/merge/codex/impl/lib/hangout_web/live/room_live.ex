defmodule HangoutWeb.RoomLive do
  use HangoutWeb, :live_view

  alias Hangout.{ChannelServer, NickRegistry, Participant}

  @impl true
  def mount(%{"room" => slug} = params, _session, socket) do
    channel = "#" <> slug

    socket =
      socket
      |> assign(:channel_slug, slug)
      |> assign(:channel_name, channel)
      |> assign(:nick, default_nick())
      |> assign(:public_key, nil)
      |> assign(:joined?, false)
      |> assign(:participants, [])
      |> assign(:messages, [])
      |> assign(:topic, nil)
      |> assign(:modes, %{})
      |> assign(:moderator?, false)
      |> assign(:mod_token, params["mod"])
      |> assign(:creator_mod_url, nil)
      |> assign(:notifications_enabled?, false)
      |> assign(:connection_status, :connected)
      |> assign(:error, nil)

    socket =
      if connected?(socket) and Hangout.ChannelRegistry.valid?(channel) do
        Phoenix.PubSub.subscribe(Hangout.PubSub, ChannelServer.topic_name(channel))
        join_room(socket, params)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:joined?] do
      ChannelServer.part(socket.assigns.channel_name, socket.assigns.nick, "left")
      NickRegistry.unregister(socket.assigns.nick)
    end

    :ok
  end

  @impl true
  def handle_event("identity_ready", %{"publicKey" => public_key}, socket) do
    {:noreply, assign(socket, public_key: public_key)}
  end

  def handle_event("choose_nick", %{"nick" => nick}, socket), do: change_nick(socket, nick)
  def handle_event("change_nick", %{"nick" => nick}, socket), do: change_nick(socket, nick)
  def handle_event("change_nick", %{"value" => nick}, socket), do: change_nick(socket, nick)

  def handle_event("send_message", %{"body" => body}, socket) do
    body = String.trim(body || "")

    if body != "" do
      {kind, body} =
        if String.starts_with?(body, "/me ") do
          {:action, String.trim_leading(body, "/me ")}
        else
          {:privmsg, body}
        end

      case ChannelServer.message(socket.assigns.channel_name, socket.assigns.nick, kind, body) do
        {:ok, _msg} -> {:noreply, socket}
        {:error, reason} -> {:noreply, assign(socket, error: human_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_topic", %{"topic" => topic}, socket) do
    case ChannelServer.set_topic(socket.assigns.channel_name, socket.assigns.nick, topic, socket.assigns.mod_token) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, error: human_error(reason))}
    end
  end

  def handle_event("kick_user", %{"nick" => nick}, socket) do
    ChannelServer.kick(socket.assigns.channel_name, socket.assigns.nick, nick, "kicked", socket.assigns.mod_token)
    {:noreply, socket}
  end

  def handle_event("lock_room", _params, socket) do
    ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "+", :i, nil, socket.assigns.mod_token)
    {:noreply, socket}
  end

  def handle_event("unlock_room", _params, socket) do
    ChannelServer.mode(socket.assigns.channel_name, socket.assigns.nick, "-", :i, nil, socket.assigns.mod_token)
    {:noreply, socket}
  end

  def handle_event("clear_buffer", _params, socket) do
    ChannelServer.clear(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.mod_token)
    {:noreply, socket}
  end

  def handle_event("end_room", _params, socket) do
    ChannelServer.end_room(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.mod_token)
    {:noreply, socket}
  end

  def handle_event("part", _params, socket) do
    ChannelServer.part(socket.assigns.channel_name, socket.assigns.nick, "left")
    NickRegistry.unregister(socket.assigns.nick)
    {:noreply, assign(socket, joined?: false)}
  end

  def handle_event("enable_notifications", _params, socket), do: {:noreply, assign(socket, notifications_enabled?: true)}
  def handle_event("disable_notifications", _params, socket), do: {:noreply, assign(socket, notifications_enabled?: false)}

  @impl true
  def handle_info({:hangout_event, event}, socket) do
    {:noreply, apply_event(socket, event)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="room">
      <div id="identity-root" phx-hook="Identity"></div>
      <header class="bar">
        <div>
          <strong><%= @channel_name %></strong>
          <span :if={@modes[:i]}>locked</span>
          <span :if={@topic}> · <%= @topic %></span>
        </div>
        <div class="controls">
          <button class="secondary" phx-click="enable_notifications" phx-hook="Notifications" id="notifications" data-channel={@channel_name} data-nick={@nick}>Notifications</button>
          <button class="secondary" phx-click="part">Leave</button>
        </div>
      </header>

      <section :if={@creator_mod_url} class="notice">
        Moderator link: <a href={@creator_mod_url}><%= @creator_mod_url %></a>
      </section>

      <section class="chat">
        <div id="messages" class="messages" phx-hook="Scroll">
          <p class="contract">
            The room disappears from this server when everyone leaves.
            Anyone in the room can still copy or record what they see.
          </p>
          <p :for={msg <- @messages} id={"msg-#{msg.id}"} class={"msg #{if msg.kind in [:notice, :system], do: "notice", else: ""}"} data-notify={notify_text(msg)}>
            <span class="meta"><%= Calendar.strftime(msg.at, "%H:%M:%S") %> <%= msg.from %></span>
            <%= render_body(msg) %>
          </p>
        </div>
        <aside class="members">
          <strong><%= length(@participants) %> in room</strong>
          <p :for={member <- @participants}>
            <%= if member.bot?, do: "bot ", else: "" %><%= member.nick %>
            <button :if={@moderator? and member.nick != @nick} class="danger" phx-click="kick_user" phx-value-nick={member.nick}>Kick</button>
          </p>
          <div :if={@moderator?} class="controls">
            <button class="secondary" phx-click="lock_room">Lock</button>
            <button class="secondary" phx-click="unlock_room">Unlock</button>
            <button class="secondary" phx-click="clear_buffer">Clear</button>
            <button class="danger" phx-click="end_room">End</button>
          </div>
        </aside>
      </section>

      <.form for={%{}} phx-submit="send_message" class="composer">
        <input name="nick" value={@nick} phx-blur="change_nick" />
        <input name="body" autocomplete="off" maxlength="400" placeholder="Message #{@channel_name}" />
        <button type="submit">Send</button>
      </.form>
      <p :if={@error} class="notice"><%= @error %></p>
    </main>
    """
  end

  defp join_room(socket, params) do
    ttl =
      case Integer.parse(params["ttl"] || "") do
        {seconds, ""} -> seconds
        _ -> nil
      end

    nick = unique_nick(socket.assigns.nick)
    :ok = NickRegistry.register(nick, %{transport: :liveview})

    participant = %Participant{
      nick: nick,
      user: nick,
      realname: nick,
      public_key: socket.assigns.public_key,
      transport: :liveview,
      pid: self()
    }

    case ChannelServer.join(socket.assigns.channel_name, participant, ttl: ttl, mod_token: socket.assigns.mod_token) do
      {:ok, snapshot, token} ->
        mod_url = if token, do: "/" <> socket.assigns.channel_slug <> "?mod=" <> token
        moderator? = token != nil or ChannelServer.validate_mod(socket.assigns.channel_name, socket.assigns.mod_token) == true

        assign(socket,
          nick: nick,
          joined?: true,
          messages: snapshot.buffer,
          participants: snapshot.members,
          topic: snapshot.topic,
          modes: snapshot.modes,
          moderator?: moderator?,
          mod_token: socket.assigns.mod_token || token,
          creator_mod_url: mod_url
        )

      {:error, reason} ->
        NickRegistry.unregister(nick)
        assign(socket, error: human_error(reason))
    end
  end

  defp change_nick(socket, nick) do
    nick = NickRegistry.normalize(nick)

    with true <- NickRegistry.valid?(nick),
         :ok <- NickRegistry.change(socket.assigns.nick, nick, %{transport: :liveview}),
         :ok <- ChannelServer.change_nick(socket.assigns.channel_name, socket.assigns.nick, nick) do
      {:noreply, assign(socket, nick: nick, error: nil)}
    else
      false -> {:noreply, assign(socket, error: "Invalid nick")}
      {:error, :in_use} -> {:noreply, assign(socket, error: "Nick is already in use")}
      _ -> {:noreply, assign(socket, error: "Could not change nick")}
    end
  end

  defp apply_event(socket, {:message, _channel, msg}) do
    push_event(assign(socket, messages: socket.assigns.messages ++ [msg]), "hangout:message", %{from: msg.from, body: msg.body, channel: msg.target})
  end

  defp apply_event(socket, {:notice, channel, from, body}) do
    msg = %Hangout.Message{id: System.unique_integer([:positive]), at: DateTime.utc_now(), from: from, target: channel, kind: :notice, body: body}
    assign(socket, messages: socket.assigns.messages ++ [msg])
  end

  defp apply_event(socket, {:user_joined, _channel, member}) do
    assign(socket, participants: upsert_member(socket.assigns.participants, member))
  end

  defp apply_event(socket, {:user_parted, _channel, member, _reason}) do
    assign(socket, participants: reject_member(socket.assigns.participants, member.nick))
  end

  defp apply_event(socket, {:user_kicked, _channel, _actor, member, reason}) do
    socket = assign(socket, participants: reject_member(socket.assigns.participants, member.nick))
    if member.nick == socket.assigns.nick, do: assign(socket, joined?: false, error: "You were kicked: #{reason}"), else: socket
  end

  defp apply_event(socket, {:nick_changed, _channel, old, new}) do
    participants = Enum.map(socket.assigns.participants, fn member -> if member.nick == old, do: %{member | nick: new}, else: member end)
    assign(socket, participants: participants)
  end

  defp apply_event(socket, {:topic_changed, _channel, _nick, topic}), do: assign(socket, topic: topic)
  defp apply_event(socket, {:modes_changed, _channel, modes, _member_modes}), do: assign(socket, modes: modes)
  defp apply_event(socket, {:buffer_cleared, _channel, _actor}), do: push_event(assign(socket, messages: []), "hangout:buffer_cleared", %{})
  defp apply_event(socket, {:room_ended, _channel, _actor}), do: assign(socket, joined?: false, error: "Room ended")
  defp apply_event(socket, {:room_expired, _channel}), do: assign(socket, joined?: false, error: "Room expired")
  defp apply_event(socket, {:ttl_changed, _channel, expires_at}), do: assign(socket, expires_at: expires_at)
  defp apply_event(socket, _event), do: socket

  defp unique_nick(base) do
    base = NickRegistry.normalize(base)

    if NickRegistry.valid?(base) and NickRegistry.lookup(base) == :error do
      base
    else
      unique_nick("guest-" <> Integer.to_string(:rand.uniform(99_999)))
    end
  end

  defp default_nick, do: "guest-" <> Integer.to_string(:rand.uniform(99_999))
  defp upsert_member(members, member), do: [member | reject_member(members, member.nick)] |> Enum.sort_by(& &1.nick)
  defp reject_member(members, nick), do: Enum.reject(members, &(&1.nick == nick))
  defp human_error(:invite_only), do: "Room is locked"
  defp human_error(:body_too_long), do: "Message is too long"
  defp human_error(:rate_limited), do: "Slow down"
  defp human_error(:not_operator), do: "Moderator permission required"
  defp human_error(:moderated), do: "Room is moderated"
  defp human_error(:bot_needs_human), do: "A human must create the room first"
  defp human_error(reason), do: "Could not complete action: #{inspect(reason)}"

  defp render_body(%{kind: :action, from: from, body: body}), do: "* #{from} #{body}"
  defp render_body(%{body: body}), do: body
  defp notify_text(%{from: from, body: body}), do: "#{from}: #{String.slice(body, 0, 100)}"
end
