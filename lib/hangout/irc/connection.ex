defmodule Hangout.IRC.Connection do
  @moduledoc """
  One process per IRC client connection. Handles registration, command
  dispatch, and message relay. Ranch protocol callback.
  """

  use GenServer, restart: :temporary

  alias Hangout.{ChannelServer, ChannelSupervisor, NickRegistry, Participant}
  alias Hangout.IRC.Parser

  require Logger

  @behaviour :ranch_protocol

  @server_name "hangout"
  @ping_interval 60_000
  @ping_timeout 30_000

  defstruct [
    :socket,
    :transport,
    :nick,
    :user,
    :realname,
    :peername,
    :ping_timer,
    :ping_ref,
    registered?: false,
    bot?: false,
    channels: MapSet.new(),
    buffer: ""
  ]

  # --- Ranch Protocol ---

  @impl :ranch_protocol
  def start_link(ref, transport, opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])
    {:ok, pid}
  end

  # --- GenServer init (called via proc_lib) ---

  @impl true
  def init({ref, transport, _opts}) do
    {:ok, socket} = :ranch.handshake(ref)
    transport.setopts(socket, active: :once, packet: :raw, buffer: 16_384)

    peername =
      case transport.peername(socket) do
        {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
        _ -> "unknown"
      end

    state = %__MODULE__{
      socket: socket,
      transport: transport,
      peername: peername
    }

    :gen_server.enter_loop(__MODULE__, [], state)
  end

  # --- Incoming TCP data ---

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state.transport.setopts(socket, active: :once)
    {lines, rest} = split_lines(state.buffer <> to_string(data))
    state = %{state | buffer: rest}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        line = String.trim_trailing(line, "\r\n") |> String.trim_trailing("\n")

        case handle_line(line, acc) do
          {:noreply, new_state} -> new_state
          {:stop, :normal, new_state} -> throw({:stop, new_state})
        end
      end)

    {:noreply, state}
  catch
    {:stop, state} -> {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, _reason}, state) do
    {:stop, :normal, state}
  end

  # --- PubSub messages from ChannelServer ---

  def handle_info({:new_message, msg}, state) do
    if msg.from != state.nick do
      case msg.kind do
        :privmsg ->
          send_line(state, Parser.user_msg(msg.from, msg.from, "PRIVMSG", msg.target, msg.body))

        :notice ->
          send_line(state, Parser.user_msg(msg.from, msg.from, "NOTICE", msg.target, msg.body))

        :action ->
          body = "\x01ACTION #{msg.body}\x01"
          send_line(state, Parser.user_msg(msg.from, msg.from, "PRIVMSG", msg.target, body))

        :system ->
          send_line(state, Parser.server_msg("NOTICE", msg.target, msg.body))
      end
    end

    {:noreply, state}
  end

  def handle_info({:user_joined, nick, channel}, state) do
    if nick != state.nick do
      send_line(state, Parser.user_cmd(nick, nick, "JOIN", channel))
    end

    {:noreply, state}
  end

  def handle_info({:user_parted, nick, channel, message}, state) do
    if nick != state.nick do
      msg = if message, do: " :#{message}", else: ""
      send_line(state, Parser.user_cmd(nick, nick, "PART", "#{channel}#{msg}"))
    end

    {:noreply, state}
  end

  def handle_info({:user_quit, nick, _channel, message}, state) do
    if nick != state.nick do
      send_line(state, ":#{nick}!#{nick}@hangout QUIT :#{message}\r\n")
    end

    {:noreply, state}
  end

  def handle_info({:user_kicked, kicker, target, channel, reason}, state) do
    send_line(state, ":#{kicker}!#{kicker}@hangout KICK #{channel} #{target} :#{reason}\r\n")

    if target == state.nick do
      state = %{state | channels: MapSet.delete(state.channels, channel)}
      Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel}")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nick_changed, old_nick, new_nick, _channel}, state) do
    if old_nick != state.nick do
      send_line(state, ":#{old_nick}!#{old_nick}@hangout NICK :#{new_nick}\r\n")
    end

    {:noreply, state}
  end

  def handle_info({:topic_changed, nick, channel, topic}, state) do
    send_line(state, ":#{nick}!#{nick}@hangout TOPIC #{channel} :#{topic}\r\n")
    {:noreply, state}
  end

  def handle_info({:modes_changed, nick, channel, mode, value}, state) do
    flag = if value, do: "+#{mode}", else: "-#{mode}"
    send_line(state, ":#{nick}!#{nick}@hangout MODE #{channel} #{flag}\r\n")
    {:noreply, state}
  end

  def handle_info({:user_mode_changed, setter, target, channel, mode, value}, state) do
    flag = if value, do: "+#{mode}", else: "-#{mode}"
    send_line(state, ":#{setter}!#{setter}@hangout MODE #{channel} #{flag} #{target}\r\n")
    {:noreply, state}
  end

  def handle_info({:room_ended, channel, reason}, state) do
    send_line(state, Parser.server_msg("NOTICE", channel, reason))
    send_line(state, ":#{state.nick}!#{state.nick}@hangout PART #{channel} :#{reason}\r\n")
    state = %{state | channels: MapSet.delete(state.channels, channel)}
    Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel}")
    {:noreply, state}
  end

  def handle_info({:room_expired, channel}, state) do
    send_line(state, Parser.server_msg("NOTICE", channel, "Room expired"))
    state = %{state | channels: MapSet.delete(state.channels, channel)}
    Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel}")
    {:noreply, state}
  end

  def handle_info({:buffer_cleared, _nick, channel}, state) do
    send_line(state, Parser.server_msg("NOTICE", channel, "Scrollback cleared"))
    {:noreply, state}
  end

  def handle_info({:ttl_set, _nick, channel, expires_at}, state) do
    send_line(state, Parser.server_msg("NOTICE", channel, "Room TTL set, expires at #{DateTime.to_iso8601(expires_at)}"))
    {:noreply, state}
  end

  def handle_info({:channel_created, _channel, _token}, state) do
    {:noreply, state}
  end

  def handle_info({:private_message, from_nick, _to_nick, body}, state) do
    send_line(state, Parser.user_msg(from_nick, from_nick, "PRIVMSG", state.nick, body))
    {:noreply, state}
  end

  def handle_info(:send_ping, state) do
    token = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    send_line(state, Parser.ping(token))
    ref = Process.send_after(self(), {:ping_timeout, token}, @ping_timeout)
    {:noreply, %{state | ping_ref: ref}}
  end

  def handle_info({:ping_timeout, _token}, state) do
    send_line(state, "ERROR :Ping timeout\r\n")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for channel <- state.channels do
      try do
        ChannelServer.part(channel, state.nick, "Connection closed")
      catch
        :exit, _ -> :ok
      end

      Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel}")
    end

    if state.nick do
      NickRegistry.unregister(state.nick)
    end

    :ok
  end

  # --- Command dispatch ---

  defp handle_line("", state), do: {:noreply, state}

  defp handle_line(line, state) do
    {_prefix, command, params} = Parser.parse(line)
    dispatch(command, params, state)
  end

  # Pre-registration commands
  defp dispatch("CAP", _params, state) do
    {:noreply, state}
  end

  defp dispatch("NICK", [nick], state) do
    cond do
      not Parser.valid_nick?(nick) ->
        target = state.nick || "*"
        send_line(state, Parser.numeric(432, target, "Erroneous nickname"))
        {:noreply, state}

      state.nick == nil ->
        case NickRegistry.register(nick, %{transport: :irc, pid: self()}) do
          :ok ->
            state = %{state | nick: nick}
            maybe_complete_registration(state)

          {:error, :nick_in_use} ->
            send_line(state, Parser.numeric(433, "*", [nick, "Nickname is already in use"]))
            {:noreply, state}
        end

      true ->
        case NickRegistry.change(state.nick, nick, %{transport: :irc, pid: self()}) do
          :ok ->
            old_nick = state.nick
            state = %{state | nick: nick}

            for channel <- state.channels do
              try do
                ChannelServer.change_nick(channel, old_nick, nick)
              catch
                :exit, _ -> :ok
              end
            end

            send_line(state, ":#{old_nick}!#{old_nick}@hangout NICK :#{nick}\r\n")
            {:noreply, state}

          {:error, :nick_in_use} ->
            send_line(state, Parser.numeric(433, state.nick, [nick, "Nickname is already in use"]))
            {:noreply, state}
        end
    end
  end

  defp dispatch("NICK", [], state) do
    target = state.nick || "*"
    send_line(state, Parser.numeric(431, target, "No nickname given"))
    {:noreply, state}
  end

  defp dispatch("USER", [user, _mode, _unused | rest], state) do
    if state.registered? do
      send_line(state, Parser.numeric(462, state.nick, "You may not reregister"))
      {:noreply, state}
    else
      realname = List.last(rest) || user
      state = %{state | user: user, realname: realname}
      maybe_complete_registration(state)
    end
  end

  defp dispatch("USER", _params, state) do
    target = state.nick || "*"
    send_line(state, Parser.numeric(461, target, ["USER", "Not enough parameters"]))
    {:noreply, state}
  end

  defp dispatch("PASS", _params, state) do
    {:noreply, state}
  end

  # Post-registration guard
  defp dispatch(command, _params, %{registered?: false} = state)
       when command not in ["NICK", "USER", "CAP", "PASS", "QUIT"] do
    target = state.nick || "*"
    send_line(state, Parser.numeric(451, target, "You have not registered"))
    {:noreply, state}
  end

  defp dispatch("PING", params, state) do
    token = List.first(params) || @server_name
    send_line(state, Parser.pong(token))
    {:noreply, state}
  end

  defp dispatch("PONG", _params, state) do
    if state.ping_ref, do: Process.cancel_timer(state.ping_ref)
    {:noreply, %{state | ping_ref: nil}}
  end

  defp dispatch("JOIN", [channels_str | _], state) do
    channels = String.split(channels_str, ",", trim: true)

    state =
      Enum.reduce(channels, state, fn channel_name, acc ->
        channel_name = normalize_channel(channel_name)

        cond do
          not Parser.valid_channel_name?(channel_name) ->
            send_line(acc, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
            acc

          MapSet.member?(acc.channels, channel_name) ->
            acc

          true ->
            case ChannelSupervisor.ensure_channel(channel_name) do
              {:ok, _pid} ->
                participant =
                  Participant.new(state.nick, :irc, self(),
                    user: state.user,
                    realname: state.realname,
                    bot?: state.bot?
                  )

                case ChannelServer.join(channel_name, participant) do
                  {:ok, info, token} ->
                    Phoenix.PubSub.subscribe(Hangout.PubSub, "channel:#{channel_name}")

                    # JOIN confirmation
                    send_line(acc, Parser.user_cmd(state.nick, state.user, "JOIN", channel_name))

                    # Topic
                    case info.topic do
                      nil ->
                        send_line(acc, Parser.numeric(331, state.nick, [channel_name, "No topic is set"]))

                      topic ->
                        send_line(acc, Parser.numeric(332, state.nick, [channel_name, topic]))
                    end

                    # NAMES
                    nicks_with_prefix = format_names(channel_name, info.members)
                    send_line(acc, Parser.names_reply(state.nick, channel_name, nicks_with_prefix))
                    send_line(acc, Parser.end_of_names(state.nick, channel_name))

                    # Scrollback
                    send_scrollback(acc, channel_name, info.buffer)

                    # Creator notice with capability token
                    if token do
                      send_line(
                        acc,
                        Parser.server_msg(
                          "NOTICE",
                          state.nick,
                          "You are the room creator. Moderator token: #{token}"
                        )
                      )
                    end

                    %{acc | channels: MapSet.put(acc.channels, channel_name)}

                  {:error, :channel_full} ->
                    send_line(acc, Parser.numeric(471, state.nick, [channel_name, "Channel is full"]))
                    acc

                  {:error, :invite_only} ->
                    send_line(acc, Parser.numeric(473, state.nick, [channel_name, "Cannot join channel (+i)"]))
                    acc

                  {:error, _reason} ->
                    acc
                end

              {:error, :too_many_channels} ->
                send_line(acc, Parser.server_msg("NOTICE", channel_name, "Too many active channels"))
                acc

              {:error, _} ->
                acc
            end
        end
      end)

    {:noreply, state}
  end

  defp dispatch("JOIN", [], state) do
    send_line(state, Parser.numeric(461, state.nick, ["JOIN", "Not enough parameters"]))
    {:noreply, state}
  end

  defp dispatch("PART", [channels_str | rest], state) do
    message = List.first(rest)
    channels = String.split(channels_str, ",", trim: true)

    state =
      Enum.reduce(channels, state, fn channel_name, acc ->
        channel_name = normalize_channel(channel_name)

        if MapSet.member?(acc.channels, channel_name) do
          try do
            ChannelServer.part(channel_name, state.nick, message)
          catch
            :exit, _ -> :ok
          end

          Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel_name}")
          send_line(acc, Parser.user_cmd(state.nick, state.user, "PART", channel_name))
          %{acc | channels: MapSet.delete(acc.channels, channel_name)}
        else
          send_line(acc, Parser.numeric(442, state.nick, [channel_name, "You're not on that channel"]))
          acc
        end
      end)

    {:noreply, state}
  end

  defp dispatch("PRIVMSG", [target, body], state) do
    cond do
      Parser.channel_name?(target) ->
        channel_name = normalize_channel(target)

        unless MapSet.member?(state.channels, channel_name) do
          send_line(state, Parser.numeric(404, state.nick, [channel_name, "Cannot send to channel"]))
          {:noreply, state}
        else
          case Parser.parse_ctcp_action(body) do
            {:action, text} ->
              case ChannelServer.message(channel_name, state.nick, :action, text) do
                {:ok, _msg} ->
                  :ok

                {:error, :rate_limited} ->
                  send_line(state, Parser.server_msg("NOTICE", state.nick, "Rate limited"))

                {:error, :body_too_long} ->
                  send_line(state, Parser.numeric(404, state.nick, [channel_name, "Message too long"]))

                {:error, _} ->
                  :ok
              end

            :not_action ->
              case ChannelServer.message(channel_name, state.nick, :privmsg, body) do
                {:ok, _msg} ->
                  :ok

                {:error, :rate_limited} ->
                  send_line(state, Parser.server_msg("NOTICE", state.nick, "Rate limited"))

                {:error, :body_too_long} ->
                  send_line(state, Parser.numeric(404, state.nick, [channel_name, "Message too long"]))

                {:error, :cannot_send} ->
                  send_line(state, Parser.numeric(404, state.nick, [channel_name, "Cannot send to channel (+m)"]))

                {:error, _} ->
                  :ok
              end
          end

          {:noreply, state}
        end

      true ->
        case NickRegistry.pid(target) do
          {:ok, pid} ->
            send(pid, {:private_message, state.nick, target, body})

          :error ->
            send_line(state, Parser.numeric(401, state.nick, [target, "No such nick/channel"]))
        end

        {:noreply, state}
    end
  end

  defp dispatch("PRIVMSG", _, state) do
    send_line(state, Parser.numeric(461, state.nick, ["PRIVMSG", "Not enough parameters"]))
    {:noreply, state}
  end

  defp dispatch("NOTICE", [target, body], state) do
    if Parser.channel_name?(target) do
      channel_name = normalize_channel(target)

      if MapSet.member?(state.channels, channel_name) do
        ChannelServer.message(channel_name, state.nick, :notice, body)
      end
    end

    # Per IRC convention, never auto-reply to NOTICE
    {:noreply, state}
  end

  defp dispatch("TOPIC", [channel_name], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.topic(channel_name) do
      {:ok, nil} ->
        send_line(state, Parser.numeric(331, state.nick, [channel_name, "No topic is set"]))

      {:ok, topic} ->
        send_line(state, Parser.numeric(332, state.nick, [channel_name, topic]))
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp dispatch("TOPIC", [channel_name, topic], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.set_topic(channel_name, state.nick, topic) do
      :ok ->
        :ok

      {:error, :chanop_needed} ->
        send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

      {:error, :not_in_channel} ->
        send_line(state, Parser.numeric(442, state.nick, [channel_name, "You're not on that channel"]))
    end

    {:noreply, state}
  end

  defp dispatch("KICK", [channel_name, target | rest], state) do
    channel_name = normalize_channel(channel_name)
    reason = List.first(rest) || "Kicked"

    case ChannelServer.kick(channel_name, state.nick, target, reason) do
      :ok ->
        :ok

      {:error, :chanop_needed} ->
        send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

      {:error, :not_in_channel} ->
        send_line(
          state,
          Parser.numeric(441, state.nick, ["#{target} #{channel_name}", "They aren't on that channel"])
        )
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp dispatch("MODE", [target | rest], state) do
    if Parser.channel_name?(target) do
      handle_channel_mode(normalize_channel(target), rest, state)
    else
      # User mode — minimal support
      {:noreply, state}
    end
  end

  defp dispatch("NAMES", [channel_name | _], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.names(channel_name) do
      {:ok, members} ->
        nicks = format_names_from_members(members)
        send_line(state, Parser.names_reply(state.nick, channel_name, nicks))
        send_line(state, Parser.end_of_names(state.nick, channel_name))

      _ ->
        send_line(state, Parser.end_of_names(state.nick, channel_name))
    end

    {:noreply, state}
  end

  defp dispatch("WHO", [channel_name | _], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.who(channel_name) do
      {:ok, who_list} ->
        for entry <- who_list do
          prefix = if MapSet.member?(entry.modes, :o), do: "@", else: ""

          send_line(
            state,
            ":hangout 352 #{state.nick} #{channel_name} #{entry.user} hangout hangout #{entry.nick} H#{prefix} :0 #{entry.realname}\r\n"
          )
        end

        send_line(state, ":hangout 315 #{state.nick} #{channel_name} :End of WHO list\r\n")

      _ ->
        send_line(state, ":hangout 315 #{state.nick} #{channel_name} :End of WHO list\r\n")
    end

    {:noreply, state}
  end

  defp dispatch("WHOIS", [nick | _], state) do
    found =
      Enum.reduce_while(state.channels, nil, fn channel, _acc ->
        case ChannelServer.whois(channel, nick) do
          {:ok, info} -> {:halt, info}
          _ -> {:cont, nil}
        end
      end)

    case found do
      nil ->
        send_line(state, Parser.numeric(401, state.nick, [nick, "No such nick/channel"]))

      info ->
        send_line(
          state,
          ":hangout 311 #{state.nick} #{info.nick} #{info.user} hangout * :#{info.realname}\r\n"
        )

        channels_str = Enum.join(info.channels, " ")
        send_line(state, ":hangout 319 #{state.nick} #{info.nick} :#{channels_str}\r\n")
        send_line(state, ":hangout 318 #{state.nick} #{info.nick} :End of WHOIS list\r\n")
    end

    {:noreply, state}
  end

  defp dispatch("LIST", _params, state) do
    # Non-discoverable by policy
    send_line(state, ":hangout 323 #{state.nick} :End of LIST\r\n")
    {:noreply, state}
  end

  defp dispatch("QUIT", params, state) do
    message = List.first(params) || "Quit"

    for channel <- state.channels do
      try do
        ChannelServer.part(channel, state.nick, message)
      catch
        :exit, _ -> :ok
      end

      Phoenix.PubSub.unsubscribe(Hangout.PubSub, "channel:#{channel}")
    end

    send_line(state, "ERROR :Closing Link: #{state.peername} (Quit: #{message})\r\n")
    {:stop, :normal, %{state | channels: MapSet.new()}}
  end

  # Custom commands

  defp dispatch("BOT", _params, state) do
    state = %{state | bot?: true}

    for channel <- state.channels do
      try do
        ChannelServer.mark_bot(channel, state.nick)
      catch
        :exit, _ -> :ok
      end
    end

    send_line(state, Parser.server_msg("NOTICE", state.nick, "You are now marked as a bot"))
    {:noreply, state}
  end

  defp dispatch("MODAUTH", [token], state) do
    results =
      Enum.map(state.channels, fn channel ->
        try do
          ChannelServer.modauth(channel, state.nick, token)
        catch
          :exit, _ -> {:error, :no_channel}
        end
      end)

    if Enum.any?(results, &(&1 == :ok)) do
      send_line(state, Parser.server_msg("NOTICE", state.nick, "Moderator authentication successful"))
    else
      send_line(state, Parser.server_msg("NOTICE", state.nick, "Invalid moderator token"))
    end

    {:noreply, state}
  end

  defp dispatch("ROOMTTL", [channel_name, seconds_str], state) do
    channel_name = normalize_channel(channel_name)

    case Integer.parse(seconds_str) do
      {seconds, ""} ->
        case ChannelServer.set_ttl(channel_name, state.nick, seconds) do
          :ok ->
            send_line(
              state,
              Parser.server_msg("NOTICE", channel_name, "Room TTL set to #{seconds} seconds")
            )

          {:error, :chanop_needed} ->
            send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

          {:error, :ttl_too_large} ->
            send_line(state, Parser.server_msg("NOTICE", state.nick, "TTL exceeds maximum"))

          {:error, _} ->
            send_line(state, Parser.server_msg("NOTICE", state.nick, "Failed to set TTL"))
        end

      _ ->
        send_line(state, Parser.numeric(461, state.nick, ["ROOMTTL", "Not enough parameters"]))
    end

    {:noreply, state}
  end

  defp dispatch("END", [channel_name], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.end_room(channel_name, state.nick) do
      :ok ->
        :ok

      {:error, :chanop_needed} ->
        send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp dispatch("CLEAR", [channel_name], state) do
    channel_name = normalize_channel(channel_name)

    case ChannelServer.clear(channel_name, state.nick) do
      :ok ->
        :ok

      {:error, :chanop_needed} ->
        send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp dispatch(command, _params, state) do
    send_line(state, Parser.numeric(421, state.nick || "*", [command, "Unknown command"]))
    {:noreply, state}
  end

  # --- Helpers ---

  defp maybe_complete_registration(%{nick: nick, user: user} = state)
       when nick != nil and user != nil and not state.registered? do
    state = %{state | registered?: true}

    # Welcome burst: 001-004, 005 ISUPPORT, 422 no MOTD
    send_line(state, Parser.numeric(1, nick, "Welcome to hangout"))
    send_line(state, Parser.numeric(2, nick, "Your host is hangout"))
    send_line(state, Parser.numeric(3, nick, "This server was created #{Date.utc_today()}"))
    send_line(state, Parser.numeric(4, nick, ["hangout 0.1.0 o o"]))

    send_line(
      state,
      ":hangout 005 #{nick} CHANTYPES=# NICKLEN=16 CHANNELLEN=48 CHANMODES=o,v,m,i,t,l :are supported by this server\r\n"
    )

    send_line(state, Parser.numeric(422, nick, "MOTD File is missing"))

    # Start ping timer
    ping_timer = Process.send_after(self(), :send_ping, @ping_interval)
    state = %{state | ping_timer: ping_timer}

    {:noreply, state}
  end

  defp maybe_complete_registration(state), do: {:noreply, state}

  defp send_line(%{socket: socket, transport: transport}, line) do
    transport.send(socket, line)
  end

  defp normalize_channel("#" <> _ = name), do: name
  defp normalize_channel(name), do: "#" <> name

  defp send_scrollback(state, channel_name, buffer) when length(buffer) > 0 do
    send_line(state, Parser.server_msg("NOTICE", channel_name, "--- scrollback ---"))

    for msg <- buffer do
      case msg.kind do
        :privmsg ->
          send_line(state, Parser.user_msg(msg.from, msg.from, "PRIVMSG", channel_name, msg.body))

        :action ->
          body = "\x01ACTION #{msg.body}\x01"
          send_line(state, Parser.user_msg(msg.from, msg.from, "PRIVMSG", channel_name, body))

        :notice ->
          send_line(state, Parser.user_msg(msg.from, msg.from, "NOTICE", channel_name, msg.body))

        :system ->
          send_line(state, Parser.server_msg("NOTICE", channel_name, msg.body))
      end
    end
  end

  defp send_scrollback(_state, _channel_name, _buffer), do: :ok

  defp format_names(_channel_name, members) when is_list(members) do
    format_names_from_members(members)
  end

  defp format_names_from_members(members) do
    Enum.map(members, fn member ->
      cond do
        :o in member.modes -> "@#{member.nick}"
        :v in member.modes -> "+#{member.nick}"
        true -> member.nick
      end
    end)
  end

  defp handle_channel_mode(channel_name, [], state) do
    case ChannelServer.snapshot(channel_name) do
      {:ok, ch_state} ->
        mode_str =
          ch_state.modes
          |> Enum.filter(fn {_k, v} -> v end)
          |> Enum.map(fn {k, _v} -> to_string(k) end)
          |> Enum.join("")

        send_line(state, ":hangout 324 #{state.nick} #{channel_name} +#{mode_str}\r\n")

      _ ->
        :ok
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp handle_channel_mode(channel_name, [mode_str | rest], state) do
    {adding, mode_char} =
      case mode_str do
        "+" <> m -> {true, m}
        "-" <> m -> {false, m}
        m -> {true, m}
      end

    mode_atom = parse_mode(mode_char)

    cond do
      mode_atom == nil ->
        send_line(state, Parser.numeric(472, state.nick, [mode_char, "is unknown mode char to me"]))

      mode_atom in [:o, :v] ->
        target_nick = List.first(rest)

        if target_nick do
          case ChannelServer.mode(channel_name, state.nick, (if adding, do: "+", else: "-"), mode_atom, target_nick) do
            :ok ->
              :ok

            {:error, :chanop_needed} ->
              send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

            {:error, _} ->
              :ok
          end
        else
          send_line(state, Parser.numeric(461, state.nick, ["MODE", "Not enough parameters"]))
        end

      true ->
        case ChannelServer.mode(channel_name, state.nick, (if adding, do: "+", else: "-"), mode_atom) do
          :ok ->
            :ok

          {:error, :chanop_needed} ->
            send_line(state, Parser.numeric(482, state.nick, [channel_name, "You're not channel operator"]))

          {:error, _} ->
            :ok
        end
    end

    {:noreply, state}
  catch
    :exit, _ ->
      send_line(state, Parser.numeric(403, state.nick, [channel_name, "No such channel"]))
      {:noreply, state}
  end

  defp parse_mode("i"), do: :i
  defp parse_mode("m"), do: :m
  defp parse_mode("t"), do: :t
  defp parse_mode("l"), do: :l
  defp parse_mode("o"), do: :o
  defp parse_mode("v"), do: :v
  defp parse_mode(_), do: nil

  defp split_lines(data) do
    parts = String.split(data, ["\r\n", "\n"])

    case parts do
      [] -> {[], ""}
      _ -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end
end
