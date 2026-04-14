defmodule HangoutWeb.RoomLive do
  use HangoutWeb, :live_view

  alias Hangout.{ChannelServer, NickRegistry, Participant}

  alias Hangout.Naming

  # --- Mount & Lifecycle ---

  @impl true
  def mount(params, _session, socket) do
    slug = Map.get(params, "slug") || Application.get_env(:hangout, :default_room, "hangout")
    channel_name = "##{slug}"
    mod_token = Map.get(params, "mod")
    ttl_seconds = parse_ttl(Map.get(params, "ttl"))

    # Peek at the room before joining — show who's inside
    {room_population, room_members} =
      case Hangout.ChannelRegistry.lookup(channel_name) do
        {:ok, _pid} ->
          case ChannelServer.snapshot(channel_name) do
            {:ok, snap} -> {snap.human_count, snap.members}
            _ -> {0, []}
          end
        :error -> {0, []}
      end

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
        asked_notifications?: false,
        mod_banner_dismissed?: false,
        in_voice?: false,
        voice_participants: [],
        voice_enabled?: Application.get_env(:hangout, :enable_voice, true),
        legal_url: Application.get_env(:hangout, :legal_url),
        room_population: room_population,
        room_members: room_members,
        page_title: "##{slug}",
        send_error: nil,
        info_open?: false,
        agent_connected?: false,
        agent_token: nil,
        agent_token_url: nil,
        agent_mode: :called,
        agent_modal_open?: false,
        room_agent_policy: :called
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
      revoke_current_agent(socket)
      ChannelServer.part(socket.assigns.channel_name, socket.assigns.nick, "left")
      NickRegistry.unregister(socket.assigns.nick)
    end

    :ok
  end

  # --- Events from browser ---

  @impl true
  def handle_event("choose_nick", %{"nick" => nick}, socket) do
    nick = String.trim(nick)

    nick = if nick == "", do: generate_nick(), else: nick

    cond do
      not NickRegistry.valid?(nick) ->
        {:noreply, put_flash(socket, :error, "Invalid nick. Use 1-16 chars starting with a letter.")}

      true ->
        case join_channel(socket, nick) do
          {:ok, socket} ->
            socket = append_you_joined(socket)
            {:noreply, push_event(socket, "hangout:nick_set", %{nick: socket.assigns.nick})}
          {:error, reason, socket} ->
            {:noreply, put_flash(socket, :error, human_error(reason))}
        end
    end
  end

  def handle_event("send_message", %{"body" => body} = params, socket) do
    body = String.trim(body || "")
    agent_draft? = params["agent_draft"] in ["true", "1", true]

    if body == "" or not socket.assigns.joined? do
      {:noreply, socket}
    else
      case Hangout.SecretFilter.check(body) do
        {:secret, kind} ->
          {:noreply, assign(socket, :send_error, "Message blocked — looks like a #{kind}. Don't paste secrets in chat.")}

        {:ok, _body} ->
          {kind, text} =
            if String.starts_with?(body, "/me ") do
              {:action, String.trim_leading(body, "/me ")}
            else
              {:privmsg, body}
            end

          case send_room_message(socket, kind, text, agent_draft?) do
            {:ok, _msg} ->
              socket =
                socket
                |> assign(:send_error, nil)

              socket =
                if not socket.assigns[:asked_notifications?] do
                  socket
                  |> assign(:asked_notifications?, true)
                  |> push_event("hangout:ask_notifications", %{})
                else
                  socket
                end

              {:noreply, socket}

            {:error, reason} when reason in [:rate_limited, :body_too_long, :moderated] ->
              {:noreply, assign(socket, :send_error, human_error(reason))}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, human_error(reason))}
          end
      end
    end
  end

  def handle_event("change_nick", %{"nick" => new_nick}, socket) do
    new_nick = NickRegistry.normalize(new_nick)
    old_nick = socket.assigns.nick

    with true <- NickRegistry.valid?(new_nick),
         :ok <- NickRegistry.change(old_nick, new_nick, %{transport: :liveview}),
         :ok <- ChannelServer.change_nick(socket.assigns.channel_name, old_nick, new_nick) do
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, agent_draft_topic(socket.assigns.channel_name, old_nick))
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, Hangout.AgentToken.presence_topic(socket.assigns.channel_name, old_nick))
      Phoenix.PubSub.subscribe(Hangout.PubSub, agent_draft_topic(socket.assigns.channel_name, new_nick))
      Phoenix.PubSub.subscribe(Hangout.PubSub, Hangout.AgentToken.presence_topic(socket.assigns.channel_name, new_nick))

      socket =
        socket
        |> revoke_current_agent()
        |> assign(nick: new_nick, agent_connected?: false, agent_token: nil, agent_token_url: nil)

      {:noreply, socket}
    else
      false -> {:noreply, put_flash(socket, :error, "Invalid nick")}
      {:error, :nick_in_use} -> {:noreply, put_flash(socket, :error, "Nick already in use")}
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

  def handle_event("dismiss_mod_banner", _params, socket) do
    {:noreply, assign(socket, mod_banner_dismissed?: true)}
  end

  def handle_event("cancel_end", _params, socket) do
    {:noreply, assign(socket, confirm_end?: false)}
  end

  def handle_event("reset_nick", _params, socket) do
    if socket.assigns.joined? do
      revoke_current_agent(socket)
      ChannelServer.part(socket.assigns.channel_name, socket.assigns.nick, "changing name")
      NickRegistry.unregister(socket.assigns.nick)
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, agent_draft_topic(socket.assigns.channel_name, socket.assigns.nick))
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, Hangout.AgentToken.presence_topic(socket.assigns.channel_name, socket.assigns.nick))
    end

    # Refresh guest list for re-entry screen
    fresh_members =
      case Hangout.ChannelRegistry.lookup(socket.assigns.channel_name) do
        {:ok, _} ->
          case ChannelServer.snapshot(socket.assigns.channel_name) do
            {:ok, snap} -> snap.members
            _ -> []
          end
        :error -> []
      end

    socket =
      socket
      |> assign(
        joined?: false,
        nick: nil,
        participants: [],
        messages: [],
        room_members: fresh_members,
        agent_connected?: false,
        agent_token: nil,
        agent_token_url: nil
      )
      |> push_event("hangout:nick_clear", %{})

    {:noreply, socket}
  end

  def handle_event("toggle_agent_modal", _params, socket) do
    {:noreply, assign(socket, agent_modal_open?: not socket.assigns.agent_modal_open?)}
  end

  def handle_event("set_agent_mode", %{"mode" => mode_str}, socket) do
    mode = case mode_str do
      "0" -> :off
      "1" -> :draft
      "2" -> :called
      "3" -> :free
      "4" -> :unleashed
      _ -> :called
    end

    # Update the token's mode in ETS
    if socket.assigns[:agent_token] do
      Hangout.AgentToken.update_mode(socket.assigns.agent_token, mode)
    else
      Hangout.AgentToken.update_mode_for_nick(socket.assigns.channel_name, socket.assigns.nick, mode)
    end

    {:noreply, assign(socket, agent_mode: mode)}
  end

  def handle_event("set_room_agent_policy", %{"policy" => policy_str}, socket) do
    if socket.assigns.moderator? do
      policy = case policy_str do
        "0" -> :off
        "1" -> :draft
        "2" -> :called
        "3" -> :free
        "4" -> :unleashed
        _ -> :called
      end

      case ChannelServer.set_agent_policy(
        socket.assigns.channel_name,
        socket.assigns.nick,
        policy,
        socket.assigns.mod_token
      ) do
        :ok -> {:noreply, assign(socket, room_agent_policy: policy)}
        {:error, _} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("copy_agent_url", _params, socket) do
    if socket.assigns.joined? do
      socket = ensure_agent_token(socket)
      if socket.assigns.agent_token_url do
        {:noreply, push_event(socket, "hangout:copy_agent_url", %{url: socket.assigns.agent_token_url})}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("generate_agent_token", _params, socket) do
    if socket.assigns.joined? do
      case Hangout.AgentToken.create(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.public_key, socket.assigns.agent_mode) do
        {:ok, token} ->
          token_hash = Hangout.AgentToken.hash_token(token)

          {:noreply,
           assign(socket,
             agent_connected?: Hangout.AgentToken.attached?(token_hash),
             agent_token: token,
             agent_token_url: agent_token_url(socket, token)
           )}

        {:error, :active_token_exists} ->
          {:noreply, put_flash(socket, :error, "An agent invite is already active for this nick.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, human_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("revoke_agent_token", _params, socket) do
    socket = revoke_current_agent(socket)
    {:noreply, assign(socket, agent_connected?: false, agent_token: nil, agent_token_url: nil)}
  end

  def handle_event("forward_to_agent", %{"msg-id" => id}, socket) do
    effective = Hangout.AgentToken.effective_mode(socket.assigns.agent_mode, socket.assigns.room_agent_policy)

    with true <- effective != :off,
         true <- socket.assigns.agent_connected?,
         token when is_binary(token) <- socket.assigns.agent_token,
         {:ok, msg} <- find_message(socket.assigns.messages, id) do
      token_hash = Hangout.AgentToken.hash_token(token)
      agent_topic = "agent:" <> Base.encode16(token_hash, case: :lower)
      payload = build_forward_payload(socket, msg)

      Phoenix.PubSub.broadcast(Hangout.PubSub, agent_topic, {:hangout_event, {:forward, payload}})
    end

    {:noreply, socket}
  end

  def handle_event("toggle_members", _params, socket) do
    {:noreply, assign(socket, mobile_members_open?: not socket.assigns.mobile_members_open?)}
  end

  def handle_event("toggle_info", _params, socket) do
    {:noreply, assign(socket, info_open?: not socket.assigns.info_open?)}
  end

  def handle_event("close_info", _params, socket) do
    {:noreply, assign(socket, info_open?: false)}
  end

  def handle_event("close_members", _params, socket) do
    {:noreply, assign(socket, mobile_members_open?: false)}
  end

  def handle_event("voice_join", _params, socket) do
    case ChannelServer.voice_join(socket.assigns.channel_name, socket.assigns.nick) do
      {:ok, peers} ->
        socket =
          socket
          |> assign(in_voice?: true, voice_participants: peers)
          |> push_event("voice:joined", %{peers: peers, self: socket.assigns.nick})

        {:noreply, socket}

      {:error, :voice_full} ->
        {:noreply, put_flash(socket, :error, "Voice is full (max 5)")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("voice_leave", _params, socket) do
    ChannelServer.voice_leave(socket.assigns.channel_name, socket.assigns.nick)
    socket =
      socket
      |> assign(in_voice?: false)
      |> push_event("voice:left", %{})

    {:noreply, socket}
  end

  def handle_event("voice_signal", %{"to" => to, "signal" => signal}, socket) do
    ChannelServer.voice_signal(socket.assigns.channel_name, socket.assigns.nick, to, signal)
    {:noreply, socket}
  end

  def handle_event("enable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: true)}
  end

  def handle_event("disable_notifications", _params, socket) do
    {:noreply, assign(socket, notifications_enabled?: false)}
  end

  def handle_event("identity_ready", params, socket) do
    socket = assign(socket, public_key: params["publicKey"])

    # Auto-join with saved nick if available and not already joined
    case {params["savedNick"], socket.assigns.joined?} do
      {nick, false} when is_binary(nick) and nick != "" ->
        case join_channel(socket, nick) do
          {:ok, socket} ->
            socket = append_you_joined(socket)
            {:noreply, push_event(socket, "hangout:nick_set", %{nick: socket.assigns.nick})}
          {:error, _reason, socket} ->
            # Saved nick failed (in use, invalid) — show the prompt
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # --- PubSub + direct messages ---

  @impl true
  def handle_info({:agent_draft, %{body: body}}, socket) do
    {:noreply, push_event(socket, "hangout:agent_draft", %{body: body, nick: socket.assigns.nick})}
  end

  def handle_info({:agent_attached, token_hash}, socket) do
    if own_token_hash?(socket, token_hash) do
      {:noreply, assign(socket, agent_connected?: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_detached, token_hash}, socket) do
    if own_token_hash?(socket, token_hash) do
      {:noreply, assign(socket, agent_connected?: false)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:voice_signal, from, signal}, socket) do
    {:noreply, push_event(socket, "voice:signal", %{from: from, signal: signal})}
  end

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

      <%= if @connection_status in [:room_ended, :room_expired] do %>
        <main class="room-ended">
          <h2>Room ended</h2>
          <p style="color: var(--muted); margin-top: 1rem;">This room no longer exists.</p>
          <a href="/" style="margin-top: 1rem; display: inline-block;">Create a new room</a>
        </main>
      <% else %>
        <%= if f = @flash["error"] do %>
          <div class="flash error" role="alert">{f}</div>
        <% end %>

        <header class="header">
          <div style="display: flex; align-items: baseline; min-width: 0; overflow: hidden;">
            <h1>{@channel_name}</h1>
            <%= if @joined? and @topic do %>
              <span class="topic">{@topic}</span>
            <% end %>
          </div>
          <div class="badges">
            <%= if @joined? do %>
              <%= if @moderator? && @mod_capability_url do %>
                <button class="mod-link-btn" onclick={"navigator.clipboard.writeText(#{Jason.encode!(@mod_capability_url)}).then(() => { this.textContent='✓ copied'; setTimeout(() => this.textContent='copy mod link (save this)', 2000) })"}>copy mod link (save this)</button>
              <% end %>
              <%= if @modes[:i] do %>
                <span class="lock-badge" title="Room is locked">🔒</span>
              <% end %>
              <%= if @modes[:m] do %>
                <span title="Room is muted">🔇</span>
              <% end %>
              <%= if @expires_at do %>
                <span class="ttl-badge" id="ttl-countdown" phx-hook="TTLCountdown" data-expires-at={DateTime.to_iso8601(@expires_at)}>
                  expires {DateTime.to_iso8601(@expires_at)}
                </span>
              <% end %>
            <% end %>
            <button class="info-btn" id="theme-btn" aria-label="Toggle theme" title="Toggle theme" phx-hook="ThemeToggle" onclick="(function(){var h=document.documentElement,t=h.getAttribute('data-theme')==='dark'?'light':'dark';h.setAttribute('data-theme',t);localStorage.setItem('hangout_theme',t);this.textContent=t==='dark'?'☀':'☾'}).call(this)">☀</button>
            <%= if @joined? do %>
              <button class="info-btn" phx-click="toggle_agent_modal" aria-label="Invite agent" title="Invite agent">🤖</button>
            <% end %>
            <button class="info-btn" phx-click="toggle_info" aria-label="Info" title="Info">💬</button>
          </div>

          <%= if @info_open? do %>
            <HangoutWeb.InfoModal.info_modal
              legal_url={@legal_url}
              agent_token_url={@agent_token_url}
              agent_connected?={@agent_connected?}
              nick={@nick}
            />
          <% end %>

          <%= if @agent_modal_open? do %>
            <div class="info-backdrop" phx-click="toggle_agent_modal"></div>
            <div class="info-modal agent-modal" phx-window-keydown="toggle_agent_modal" phx-key="Escape">
              <%= if @moderator? do %>
                <h3>Room policy</h3>
                <div class="agent-mode-desc">
                  <%= agent_policy_desc(@room_agent_policy) %>
                </div>
                <div class="agent-slider">
                  <input type="range" min="0" max="4" value={agent_mode_value(@room_agent_policy)} phx-change="set_room_agent_policy" name="policy" class={"freedom-slider #{if @room_agent_policy == :unleashed, do: "unleashed"}"} />
                  <div class="freedom-labels">
                    <span class={"freedom-label #{if @room_agent_policy == :off, do: "active"}"}>Off</span>
                    <span class={"freedom-label #{if @room_agent_policy == :draft, do: "active"}"}>Draft</span>
                    <span class={"freedom-label #{if @room_agent_policy == :called, do: "active"}"}>Called</span>
                    <span class={"freedom-label #{if @room_agent_policy == :free, do: "active"}"}>Free</span>
                    <span class={"freedom-label #{if @room_agent_policy == :unleashed, do: "active danger"}"}>🔥</span>
                  </div>
                </div>
                <hr style="border: none; border-top: 1px solid var(--border); margin: 0.75rem 0;" />
              <% end %>
              <h3>My agent</h3>
              <div class="agent-mode-desc">
                <%= agent_mode_desc(@agent_mode) %>
              </div>
              <div class="agent-slider">
                <input type="range" min="0" max="4" value={agent_mode_value(@agent_mode)} phx-change="set_agent_mode" name="mode" class={"freedom-slider #{if @agent_mode == :unleashed, do: "unleashed"}"} />
                <div class="freedom-labels">
                  <span class={"freedom-label #{if @agent_mode == :off, do: "active"}"}>Off</span>
                  <span class={"freedom-label #{if @agent_mode == :draft, do: "active"}"}>Draft</span>
                  <span class={"freedom-label #{if @agent_mode == :called, do: "active"}"}>Called</span>
                  <span class={"freedom-label #{if @agent_mode == :free, do: "active"}"}>Free</span>
                  <span class={"freedom-label #{if @agent_mode == :unleashed, do: "active danger"}"}>🔥</span>
                </div>
              </div>
              <%= if @agent_token_url do %>
                <div class="agent-url-row" style="margin-top: 0.75rem;">
                  <code class="agent-url">{@agent_token_url}</code>
                  <button class="agent-copy-btn" onclick={"navigator.clipboard.writeText(#{Jason.encode!(@agent_token_url)}).then(() => { this.textContent='✓'; setTimeout(() => this.textContent='📋', 1000) })"} title="Copy" aria-label="Copy">📋</button>
                </div>
                <div class="hint" style="margin-top: 0.25rem;">
                  <%= if @agent_connected? do %>
                    🟢 connected
                  <% else %>
                    ⚪ waiting for agent…
                  <% end %>
                </div>
              <% else %>
                <button class="agent-invite-btn" phx-click="generate_agent_token" style="margin-top: 0.75rem;">Generate invite link</button>
              <% end %>
              <div class="hint" style="margin-top: 0.5rem;">
                Your agent sees room messages and responds from your working directory.
              </div>
            </div>
          <% end %>
        </header>

        <div id="voice-hook" phx-hook="Voice" style="display:none"></div>
        <main class="room-layout">
          <div class="messages-panel" style="position: relative;">
            <button class="member-toggle" phx-click="toggle_members" aria-expanded={to_string(@mobile_members_open?)} aria-label="Toggle member list" style={"animation: count-flash 0.6s ease-out"} id={"member-count-#{if @joined?, do: length(@participants), else: length(@room_members)}"}>
              <%= if @joined?, do: length(@participants), else: length(@room_members) %> in room
            </button>

            <%= if @mobile_members_open? do %>
              <div class="member-drawer-backdrop" phx-click="toggle_members"></div>
              <div class="member-drawer" phx-window-keydown="close_members" phx-key="Escape">
                <%= for member <- (if @joined?, do: @participants, else: @room_members) do %>
                  <div class="nick-entry">
                    <%= if :o in (member[:modes] || member.modes || []) do %>
                      <span class="op-badge">@</span>
                    <% end %>
                    <span style={"color: #{nick_color(member.nick)}"}>{member.nick}</span>
                    <%= if member[:bot?] || member.bot? do %>
                      <span class="bot-badge">[bot]</span>
                    <% end %>
                    <%= if @joined? and @moderator? and member.nick != @nick do %>
                      <button class="kick-btn" phx-click="kick_user" phx-value-nick={member.nick} title="Kick">x</button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div class="messages" id="messages" phx-hook="Scroll">

              <%= if @joined? do %>
                <%= if @messages == [] do %>
                  <div class="message system" style="text-align: center; margin-top: 2rem;">No messages yet.</div>
                <% end %>
                <%= for msg <- @messages do %>
                  <div class={"message #{message_class(msg)}#{if Map.get(msg, :agent, false), do: " agent", else: ""}"} id={"msg-#{msg.id}"}>
                    <span class="time" data-utc={DateTime.to_iso8601(msg.at)}>{format_time(msg.at)}</span>
                    <%= case msg.kind do %>
                      <% :privmsg -> %>
                        <span class="nick" style={"color: #{nick_color(msg.from)}"}>{display_nick(msg)}:</span>
                        <%= if @agent_connected? do %>
                          <button class="forward-btn" phx-click="forward_to_agent" phx-value-msg-id={msg.id} title="Forward to agent" aria-label="Forward to agent">→🤖</button>
                        <% end %>
                        <%= if Hangout.Markdown.has_markdown?(msg.body) do %>
                          <button class="copy-md" onclick={"navigator.clipboard.writeText(#{Jason.encode!(msg.body)}).then(() => { this.textContent='✓'; setTimeout(() => this.textContent='📋', 1000) })"} title="Copy markdown" aria-label="Copy">📋</button>
                          <div class="md-body">{Hangout.Markdown.render(msg.body)}</div>
                        <% else %>
                          {msg.body}
                        <% end %>
                      <% :action -> %>
                        * <span class="nick" style={"color: #{nick_color(msg.from)}"}>{display_nick(msg)}</span> {msg.body}
                      <% :notice -> %>
                        -<span class="nick">{msg.from}</span>- {msg.body}
                      <% :system -> %>
                        {msg.body}
                      <% _ -> %>
                        <span class="nick" style={"color: #{nick_color(msg.from)}"}>{display_nick(msg)}:</span> {msg.body}
                    <% end %>
                  </div>
                <% end %>
              <% else %>
                <div class="entry-content">
                  <div class="guest-list">
                    <%= if @room_members != [] do %>
                      <div class="guest-label">Inside now</div>
                      <%= for member <- Enum.take(@room_members, 8) do %>
                        <span class="guest" style={"color: #{nick_color(member.nick)}"}>{member.nick}</span>
                      <% end %>
                      <%= if length(@room_members) > 8 do %>
                        <span class="guest more">+{length(@room_members) - 8} more</span>
                      <% end %>
                    <% else %>
                      <div class="guest-label">No one here yet</div>
                    <% end %>
                  </div>
                  <div class="social-contract">
                    <p>The room disappears when everyone leaves.</p>
                    <p>Anyone present can still copy what they see.</p>
                    <%= if @legal_url do %>
                      <p><a href={@legal_url} target="_blank" style="color: var(--dim);">terms & privacy</a></p>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>

            <div class="input-bar" id="input-bar">
              <%= if @joined? do %>
                <%= if @voice_enabled? do %>
                  <%= if @in_voice? do %>
                    <button class="voice-btn voice-active" phx-click="voice_leave" title="Leave voice">🎙️</button>
                  <% else %>
                    <button class="voice-btn" phx-click="voice_join" title="Join voice">🎙️</button>
                  <% end %>
                <% end %>
                <button class="nick-label" phx-click="reset_nick" title="Change name">{@nick}</button>
                <form phx-submit="send_message" id="message-form" phx-hook="MessageForm" data-nick={@nick} style="display: flex; flex: 1; align-items: center;">
                  <span class="draft-label" hidden></span>
                  <input type="hidden" name="agent_draft" value="false" disabled />
                  <input
                    type="text"
                    name="body"
                    placeholder="say something"
                    autocomplete="off"
                    autofocus
                    maxlength="4000"
                    id="message-input"
                    aria-label="Message"
                    phx-hook="AutoFocus"
                  />
                  <button type="button" class="draft-discard" hidden aria-label="Discard agent draft">✕</button>
                  <button type="submit" aria-label="Send">↑</button>
                </form>
              <% else %>
                <form phx-submit="choose_nick" id="join-form" style="display: flex; flex: 1; align-items: center; gap: 0.5rem;">
                  <input
                    type="text"
                    name="nick"
                    value=""
                    placeholder="your name"
                    autocomplete="off"
                    autofocus
                    aria-label="your name"
                    style="font-family: var(--font-mono);"
                  />
                  <button type="submit" style="background:var(--accent);color:var(--btn-text);border:none;padding:0.4rem 1rem;border-radius:4px;cursor:pointer;font-weight:600;white-space:nowrap;">
                    <%= if @room_members == [], do: "Start the room", else: "Step in" %>
                  </button>
                </form>
              <% end %>
            </div>

            <%= if @send_error do %>
              <div class="send-error" role="alert">{@send_error}</div>
            <% end %>

            <%= if @moderator? do %>
              <details class="mod-controls">
                <summary>Room controls</summary>
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
        </main>
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
            Phoenix.PubSub.subscribe(Hangout.PubSub, agent_draft_topic(channel_name, nick))
            Phoenix.PubSub.subscribe(Hangout.PubSub, Hangout.AgentToken.presence_topic(channel_name, nick))

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
                mod_capability_url: mod_url,
                room_agent_policy: snapshot[:agent_policy] || :called
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

  defp apply_event(socket, {:user_joined, channel, member}) do
    socket = assign(socket, participants: upsert_member(socket.assigns.participants, member))

    if member.nick != socket.assigns.nick do
      msg = %Hangout.Message{
        id: System.unique_integer([:positive]),
        at: DateTime.utc_now(),
        from: "hangout",
        target: channel,
        kind: :system,
        body: "#{member.nick} joined"
      }

      assign(socket, messages: append_message(socket.assigns.messages, msg))
    else
      socket
    end
  end

  defp apply_event(socket, {:user_parted, channel, member, _reason}) do
    socket = assign(socket, participants: reject_member(socket.assigns.participants, member.nick))

    msg = %Hangout.Message{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(),
      from: "hangout",
      target: channel,
      kind: :system,
      body: "#{member.nick} left"
    }

    assign(socket, messages: append_message(socket.assigns.messages, msg))
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

  defp apply_event(socket, {:nick_changed, channel, old, new}) do
    participants =
      Enum.map(socket.assigns.participants, fn member ->
        if member.nick == old, do: %{member | nick: new}, else: member
      end)

    msg = %Hangout.Message{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(),
      from: "hangout",
      target: channel,
      kind: :system,
      body: "#{old} is now #{new}"
    }

    socket
    |> assign(participants: participants)
    |> assign(messages: append_message(socket.assigns.messages, msg))
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

  defp apply_event(socket, {:user_quit, channel, member, _reason}) do
    socket = assign(socket, participants: reject_member(socket.assigns.participants, member.nick))

    msg = %Hangout.Message{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(),
      from: "hangout",
      target: channel,
      kind: :system,
      body: "#{member.nick} disconnected"
    }

    assign(socket, messages: append_message(socket.assigns.messages, msg))
  end

  defp apply_event(socket, {:voice_joined, _channel, nick, peers}) do
    socket
    |> assign(voice_participants: peers)
    |> push_event("voice:peer_joined", %{nick: nick, peers: peers})
  end

  defp apply_event(socket, {:voice_left, _channel, nick}) do
    peers = List.delete(socket.assigns[:voice_participants] || [], nick)

    socket =
      socket
      |> assign(voice_participants: peers)
      |> push_event("voice:peer_left", %{nick: nick})

    if nick == socket.assigns.nick, do: assign(socket, in_voice?: false), else: socket
  end

  defp apply_event(socket, {:user_mode_changed, _server, nick, _channel, mode, value}) do
    participants =
      Enum.map(socket.assigns.participants, fn member ->
        if member.nick == nick do
          modes = if value, do: [mode | member.modes], else: List.delete(member.modes, mode)
          %{member | modes: Enum.uniq(modes)}
        else
          member
        end
      end)

    socket = assign(socket, participants: participants)

    if nick == socket.assigns.nick and mode == :o do
      assign(socket, moderator?: value)
    else
      socket
    end
  end

  defp apply_event(socket, {:agent_policy_changed, _channel, policy}) do
    assign(socket, room_agent_policy: policy)
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

  defp append_you_joined(socket) do
    msg = %Hangout.Message{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(),
      from: "hangout",
      target: socket.assigns.channel_name,
      kind: :system,
      body: "You joined as #{socket.assigns.nick}"
    }

    assign(socket, messages: append_message(socket.assigns.messages, msg))
  end

  defp send_room_message(socket, kind, text, true) do
    if socket.assigns[:agent_connected?] and is_binary(socket.assigns[:agent_token]) do
      ChannelServer.agent_message(socket.assigns.channel_name, socket.assigns.nick, text)
    else
      # No active agent — treat as normal message, ignore the flag
      ChannelServer.message(socket.assigns.channel_name, socket.assigns.nick, kind, text)
    end
  end

  defp send_room_message(socket, kind, text, false) do
    ChannelServer.message(socket.assigns.channel_name, socket.assigns.nick, kind, text)
  end

  defp revoke_current_agent(socket) do
    cond do
      is_binary(socket.assigns[:agent_token]) ->
        Hangout.AgentToken.revoke(socket.assigns.agent_token)
        socket

      socket.assigns[:agent_connected?] and socket.assigns[:joined?] ->
        Hangout.AgentToken.revoke_for_nick(socket.assigns.channel_name, socket.assigns.nick)
        socket

      true ->
        socket
    end
  end

  defp agent_token_url(socket, token) do
    path = "/#{socket.assigns.channel_slug}/agent/#{token}/events"

    HangoutWeb.Endpoint.url()
    |> URI.merge(path)
    |> to_string()
  end

  defp agent_mode_desc(:off), do: "Agent cannot speak. Connection stays alive."
  defp agent_mode_desc(:draft), do: "Owner forwards only. Every response needs your approval."
  defp agent_mode_desc(:called), do: "Anyone can @mention your agent. It replies directly."
  defp agent_mode_desc(:free), do: "Agent can speak freely. No invocation needed."
  defp agent_mode_desc(:unleashed), do: "⚠️ Agents can invoke other agents. Conversations may cascade."
  defp agent_mode_desc(_), do: ""

  defp agent_policy_desc(:off), do: "No agents can speak in this room."
  defp agent_policy_desc(:draft), do: "Agents can only draft responses for owner approval."
  defp agent_policy_desc(:called), do: "Agents can respond when @mentioned."
  defp agent_policy_desc(:free), do: "Agents can speak freely in this room."
  defp agent_policy_desc(:unleashed), do: "⚠️ Agents can invoke each other. You are responsible for what happens."
  defp agent_policy_desc(_), do: ""

  defp agent_mode_value(:off), do: 0
  defp agent_mode_value(:draft), do: 1
  defp agent_mode_value(:called), do: 2
  defp agent_mode_value(:free), do: 3
  defp agent_mode_value(:unleashed), do: 4
  defp agent_mode_value(_), do: 2

  defp ensure_agent_token(socket) do
    if socket.assigns[:agent_token] do
      socket
    else
      case Hangout.AgentToken.create(socket.assigns.channel_name, socket.assigns.nick, socket.assigns.public_key, socket.assigns.agent_mode) do
        {:ok, token} ->
          token_hash = Hangout.AgentToken.hash_token(token)

          assign(socket,
            agent_connected?: Hangout.AgentToken.attached?(token_hash),
            agent_token: token,
            agent_token_url: agent_token_url(socket, token)
          )

        {:error, :active_token_exists} -> socket
        {:error, _} -> socket
      end
    end
  end

  defp agent_draft_topic(channel_name, nick), do: "agent_draft:#{channel_name}:#{nick}"

  defp own_token_hash?(socket, incoming_hash) do
    case socket.assigns[:agent_token] do
      token when is_binary(token) -> Hangout.AgentToken.hash_token(token) == incoming_hash
      _ -> false
    end
  end

  defp find_message(messages, id) do
    case Enum.find(messages, &(to_string(&1.id) == to_string(id))) do
      nil -> :error
      msg -> {:ok, msg}
    end
  end

  defp build_forward_payload(socket, msg) do
    %{
      "id" => "fwd_#{System.unique_integer([:positive])}",
      "from" => %{"nick" => socket.assigns.nick, "agent" => false},
      "target" => serialize_agent_message(msg),
      "context" => socket.assigns.messages |> Enum.take(-20) |> Enum.map(&serialize_agent_message/1),
      "requires_approval" => true
    }
  end

  defp serialize_agent_message(msg) do
    %{
      "id" => msg.id,
      "from" => %{"nick" => msg.from, "agent" => Map.get(msg, :agent, false)},
      "body" => msg.body,
      "kind" => to_string(msg.kind),
      "at" => DateTime.to_iso8601(msg.at)
    }
  end

  defp generate_nick, do: Naming.random_nick()

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp format_time(_), do: ""

  defp message_class(%{kind: :system}), do: "system"
  defp message_class(%{kind: :action}), do: "action"
  defp message_class(%{kind: :notice}), do: "notice"
  defp message_class(_), do: ""

  defp display_nick(msg) do
    if Map.get(msg, :agent, false), do: msg.from <> "🤖", else: msg.from
  end

  # Nick color palettes — 12 hues, each passing 4.5:1 contrast on its background
  # Dark mode: light colors on #11100f
  @nick_colors_dark [
    "#7cc7b2", "#e0b15d", "#c78dea", "#6cb4ee",
    "#e88b72", "#8dd99b", "#dda0c5", "#b0c862",
    "#7ab8d4", "#d4a76a", "#a0b4e0", "#c9c270"
  ]
  # Light mode: darker saturated colors on #f5f3ef
  @nick_colors_light [
    "#1a7a65", "#8a6508", "#7a3daa", "#1a6eb8",
    "#b83a2a", "#2a7a3d", "#a0406a", "#5a7a1a",
    "#1a6a8a", "#8a5a1a", "#3a5a9a", "#7a7a1a"
  ]

  defp nick_color(nick) do
    hash = :erlang.phash2(nick, length(@nick_colors_dark))
    # Return CSS custom property that resolves per-theme
    dark = Enum.at(@nick_colors_dark, hash)
    light = Enum.at(@nick_colors_light, hash)
    "light-dark(#{light}, #{dark})"
  end

  defp human_error(:nick_in_use), do: "Nick already in use"
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
