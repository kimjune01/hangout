defmodule Hangout.IRC.Connection do
  @moduledoc "One process per raw IRC client."

  alias Hangout.{ChannelServer, NickRegistry, Participant}
  alias Hangout.IRC.Parser

  @server "hangout"
  @created "2026-04-11"

  defstruct socket: nil,
            transport: nil,
            buffer: "",
            nick: nil,
            user: nil,
            realname: nil,
            registered?: false,
            channels: MapSet.new(),
            bot?: false

  def start_link(ref, transport, opts) do
    pid = spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  def init(ref, transport, _opts) do
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, active: :once)
    loop(%__MODULE__{socket: socket, transport: transport})
  end

  defp loop(state) do
    receive do
      {:tcp, socket, data} when socket == state.socket ->
        state.transport.setopts(state.socket, active: :once)
        state |> read_data(data) |> loop()

      {:tcp_closed, socket} when socket == state.socket ->
        terminate(state)

      {:tcp_error, socket, _reason} when socket == state.socket ->
        terminate(state)

      {:hangout_event, event} ->
        state |> deliver_event(event) |> loop()

      {:irc_private, prefix, command, target, body} ->
        send_line(state, Parser.line(prefix, command, [target, body]))
        loop(state)
    after
      60_000 ->
        send_line(state, Parser.line(@server, "PING", [System.unique_integer([:positive])]))
        loop(state)
    end
  end

  defp read_data(state, data) do
    max = Application.get_env(:hangout, :irc_line_max_bytes, 512)
    {lines, rest} = split_lines(state.buffer <> data)

    Enum.reduce(lines, %{state | buffer: byte_part(rest, 0, min(byte_size(rest), max))}, fn line, acc ->
      case Parser.parse(line) do
        {:ok, command} -> handle_command(acc, command)
        {:error, _} -> acc
      end
    end)
  end

  defp handle_command(state, %{command: "CAP"}), do: state
  defp handle_command(state, %{command: "PONG"}), do: state

  defp handle_command(state, %{command: "PING", params: params}) do
    token = List.last(params) || ""
    send_line(state, Parser.line(@server, "PONG", [token]))
    state
  end

  defp handle_command(state, %{command: "NICK", params: []}) do
    numeric(state, 431, ["No nickname given"])
    state
  end

  defp handle_command(%{registered?: true} = state, %{command: "NICK", params: [new | _]}) do
    new = NickRegistry.normalize(new)

    case NickRegistry.change(state.nick, new, %{transport: :irc}) do
      :ok ->
        Enum.each(state.channels, &ChannelServer.change_nick(&1, state.nick, new))
        %{state | nick: new}

      {:error, :invalid_nick} ->
        numeric(state, 432, [new, "Erroneous nickname"])
        state

      {:error, :in_use} ->
        numeric(state, 433, [new, "Nickname is already in use"])
        state

      _ ->
        state
    end
  end

  defp handle_command(state, %{command: "NICK", params: [nick | _]}) do
    nick = NickRegistry.normalize(nick)

    result =
      if state.nick do
        NickRegistry.change(state.nick, nick, %{transport: :irc})
      else
        NickRegistry.register(nick, %{transport: :irc})
      end

    case result do
      :ok -> maybe_register(%{state | nick: nick})
      {:error, :invalid_nick} -> numeric(state, 432, [nick, "Erroneous nickname"]); state
      {:error, :in_use} -> numeric(state, 433, [nick, "Nickname is already in use"]); state
      {:error, :no_nick} -> numeric(state, 431, ["No nickname given"]); state
    end
  end

  defp handle_command(%{registered?: true} = state, %{command: "USER"}) do
    numeric(state, 462, ["You may not reregister"])
    state
  end

  defp handle_command(state, %{command: "USER", params: [user, _mode, _star, realname | _]}) do
    maybe_register(%{state | user: user, realname: realname})
  end

  defp handle_command(state, %{command: "USER"}) do
    numeric(state, 461, ["USER", "Not enough parameters"])
    state
  end

  defp handle_command(%{registered?: false} = state, %{command: command}) when command not in ["NICK", "USER", "CAP", "PING", "PONG"] do
    numeric(state, 451, ["You have not registered"])
    state
  end

  defp handle_command(state, %{command: "BOT"}) do
    %{state | bot?: true}
  end

  defp handle_command(state, %{command: "JOIN", params: []}) do
    numeric(state, 461, ["JOIN", "Not enough parameters"])
    state
  end

  defp handle_command(state, %{command: "JOIN", params: [channels | _]}) do
    channels
    |> String.split(",", trim: true)
    |> Enum.reduce(state, fn channel, acc -> join_channel(acc, channel) end)
  end

  defp handle_command(state, %{command: "PART", params: []}) do
    numeric(state, 461, ["PART", "Not enough parameters"])
    state
  end

  defp handle_command(state, %{command: "PART", params: [channel | rest]}) do
    reason = List.first(rest) || "leaving"
    ChannelServer.part(channel, state.nick, reason)
    %{state | channels: MapSet.delete(state.channels, canonical(channel))}
  end

  defp handle_command(state, %{command: "QUIT", params: params}) do
    reason = List.first(params) || "quit"
    Enum.each(state.channels, &ChannelServer.part(&1, state.nick, reason))
    terminate(%{state | channels: MapSet.new()})
    exit(:normal)
  end

  defp handle_command(state, %{command: command, params: [target, body | _]}) when command in ["PRIVMSG", "NOTICE"] do
    cond do
      Parser.channel_name?(target) ->
        {kind, body} =
          if command == "PRIVMSG" do
            Parser.action_body(body)
          else
            {:notice, body}
          end

        case ChannelServer.message(target, state.nick, kind, body) do
          {:ok, _} -> state
          {:error, reason} -> cannot_send(state, target, reason); state
        end

      true ->
        send_private(state, command, target, body)
        state
    end
  end

  defp handle_command(state, %{command: command}) when command in ["PRIVMSG", "NOTICE"] do
    numeric(state, 461, [command, "Not enough parameters"])
    state
  end

  defp handle_command(state, %{command: "NAMES", params: [channel | _]}) do
    send_names(state, canonical(channel))
    state
  end

  defp handle_command(state, %{command: "TOPIC", params: [channel]}) do
    channel = canonical(channel)

    case ChannelServer.topic(channel) do
      {:ok, nil} -> numeric(state, 331, [channel, "No topic is set"])
      {:ok, topic} -> numeric(state, 332, [channel, topic])
      {:error, _} -> numeric(state, 403, [channel, "No such channel"])
    end

    state
  end

  defp handle_command(state, %{command: "TOPIC", params: [channel, topic | _]}) do
    channel = canonical(channel)

    case ChannelServer.set_topic(channel, state.nick, topic) do
      :ok -> state
      {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
      {:error, _} -> numeric(state, 403, [channel, "No such channel"]); state
    end
  end

  defp handle_command(state, %{command: "KICK", params: [channel, target | rest]}) do
    channel = canonical(channel)
    reason = List.first(rest) || state.nick

    case ChannelServer.kick(channel, state.nick, target, reason) do
      :ok -> state
      {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
      {:error, :not_on_channel} -> numeric(state, 441, [target, channel, "They aren't on that channel"]); state
      {:error, _} -> numeric(state, 403, [channel, "No such channel"]); state
    end
  end

  defp handle_command(state, %{command: "MODE", params: [channel, mode | rest]}) do
    channel = canonical(channel)
    <<op::binary-size(1), flag::binary-size(1), _::binary>> = mode <> " "
    arg = List.first(rest)

    case ChannelServer.mode(channel, state.nick, op, parse_mode(flag), arg) do
      :ok -> state
      {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
      {:error, _} -> numeric(state, 472, [flag, "is unknown mode char to me"]); state
    end
  end

  defp handle_command(state, %{command: "WHO", params: [channel | _]}) do
    channel = canonical(channel)

    case ChannelServer.names(channel) do
      {:ok, members} ->
        Enum.each(members, fn member ->
          numeric(state, 352, [channel, member.user || member.nick, "hangout", @server, member.nick, "H", "0 #{member.realname || member.nick}"])
        end)

        numeric(state, 315, [channel, "End of WHO list"])

      _ ->
        numeric(state, 403, [channel, "No such channel"])
    end

    state
  end

  defp handle_command(state, %{command: "WHOIS", params: [nick | _]}) do
    case NickRegistry.lookup(nick) do
      {:ok, _pid, meta} ->
        nick = meta[:nick] || nick
        numeric(state, 311, [nick, nick, "hangout", "*", nick])
        numeric(state, 318, [nick, "End of WHOIS list"])

      :error ->
        numeric(state, 401, [nick, "No such nick/channel"])
    end

    state
  end

  defp handle_command(state, %{command: "LIST"}) do
    numeric(state, 323, ["End of LIST"])
    state
  end

  defp handle_command(state, %{command: "MODAUTH", params: [token | _]}) do
    Enum.each(state.channels, fn channel ->
      if ChannelServer.modauth(channel, state.nick, token) == :ok do
        send_line(state, Parser.line(@server, "NOTICE", [state.nick, "Moderator capability accepted for #{channel}"]))
      end
    end)

    state
  end

  defp handle_command(state, %{command: "ROOMTTL", params: [channel, seconds | _]}) do
    channel = canonical(channel)

    case Integer.parse(seconds) do
      {ttl, ""} ->
        case ChannelServer.set_ttl(channel, state.nick, ttl) do
          :ok -> state
          {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
          {:error, _} -> numeric(state, 461, ["ROOMTTL", "Invalid TTL"]); state
        end

      _ ->
        numeric(state, 461, ["ROOMTTL", "Invalid TTL"])
        state
    end
  end

  defp handle_command(state, %{command: "CLEAR", params: [channel | _]}) do
    channel = canonical(channel)

    case ChannelServer.clear(channel, state.nick) do
      :ok -> state
      {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
      {:error, _} -> numeric(state, 403, [channel, "No such channel"]); state
    end
  end

  defp handle_command(state, %{command: "END", params: [channel | _]}) do
    channel = canonical(channel)

    case ChannelServer.end_room(channel, state.nick) do
      :ok -> %{state | channels: MapSet.delete(state.channels, channel)}
      {:error, :not_operator} -> numeric(state, 482, [channel, "You're not channel operator"]); state
      {:error, _} -> numeric(state, 403, [channel, "No such channel"]); state
    end
  end

  defp handle_command(state, %{command: command}) do
    numeric(state, 421, [command, "Unknown command"])
    state
  end

  defp maybe_register(%{registered?: true} = state), do: state

  defp maybe_register(%{nick: nick, user: user} = state) when is_binary(nick) and is_binary(user) do
    state = %{state | registered?: true}
    numeric(state, 1, ["Welcome to hangout"])
    numeric(state, 2, ["Your host is hangout"])
    numeric(state, 3, ["This server was created #{@created}"])
    numeric(state, 4, ["hangout 0.1.0 o o"])
    numeric(state, 5, ["CHANTYPES=# NICKLEN=16 CHANMODES=o,v,m,i,t,l :are supported by this server"])
    numeric(state, 422, ["MOTD File is missing"])
    state
  end

  defp maybe_register(state), do: state

  defp join_channel(state, channel) do
    channel = canonical(channel)

    participant = %Participant{
      nick: state.nick,
      user: state.user,
      realname: state.realname,
      transport: :irc,
      bot?: state.bot?,
      pid: self()
    }

    case ChannelServer.join(channel, participant) do
      {:ok, snapshot, token} ->
        if token, do: send_line(state, Parser.line(@server, "NOTICE", [state.nick, "Moderator URL: /#{snapshot.slug}?mod=#{token}"]))
        send_join_scrollback(state, snapshot)
        %{state | channels: MapSet.put(state.channels, channel)}

      {:error, :invite_only} ->
        numeric(state, 473, [channel, "Cannot join channel (+i)"])
        state

      {:error, :channel_full} ->
        numeric(state, 471, [channel, "Cannot join channel (+l)"])
        state

      {:error, :bot_needs_human} ->
        numeric(state, 403, [channel, "Bots cannot create rooms"])
        state

      _ ->
        numeric(state, 403, [channel, "No such channel"])
        state
    end
  end

  defp send_join_scrollback(state, snapshot) do
    if snapshot.topic, do: numeric(state, 332, [snapshot.name, snapshot.topic]), else: numeric(state, 331, [snapshot.name, "No topic is set"])
    send_names_from_snapshot(state, snapshot)

    if snapshot.buffer != [] do
      send_line(state, Parser.line(@server, "NOTICE", [snapshot.name, "--- scrollback ---"]))

      Enum.each(snapshot.buffer, fn msg ->
        send_line(state, Parser.line(Parser.user_prefix(msg.from), format_kind(msg.kind), [snapshot.name, format_body(msg)]))
      end)
    end
  end

  defp send_names(state, channel) do
    case ChannelServer.snapshot(channel) do
      {:ok, snapshot} -> send_names_from_snapshot(state, snapshot)
      {:error, _} -> numeric(state, 403, [channel, "No such channel"])
    end
  end

  defp send_names_from_snapshot(state, snapshot) do
    names =
      snapshot.members
      |> Enum.map(fn member ->
        prefix = if :o in member.modes, do: "@", else: ""
        prefix <> member.nick
      end)
      |> Enum.join(" ")

    numeric(state, 353, ["=", snapshot.name, names])
    numeric(state, 366, [snapshot.name, "End of NAMES list"])
  end

  defp send_private(state, command, target, body) do
    case NickRegistry.pid(target) do
      {:ok, pid} -> send(pid, {:irc_private, Parser.user_prefix(state.nick, state.user), command, target, body})
      :error -> numeric(state, 401, [target, "No such nick/channel"])
    end
  end

  defp deliver_event(state, {:message, channel, msg}) do
    send_line(state, Parser.line(Parser.user_prefix(msg.from), format_kind(msg.kind), [channel, format_body(msg)]))
    state
  end

  defp deliver_event(state, {:notice, channel, from, body}) do
    send_line(state, Parser.line(Parser.user_prefix(from), "NOTICE", [channel, body]))
    state
  end

  defp deliver_event(state, {:user_joined, channel, member}) do
    send_line(state, Parser.line(Parser.user_prefix(member.nick, member.user), "JOIN", [channel]))
    state
  end

  defp deliver_event(state, {:user_parted, channel, member, reason}) do
    send_line(state, Parser.line(Parser.user_prefix(member.nick, member.user), "PART", [channel, reason]))
    if member.nick == state.nick, do: %{state | channels: MapSet.delete(state.channels, channel)}, else: state
  end

  defp deliver_event(state, {:user_kicked, channel, actor, member, reason}) do
    send_line(state, Parser.line(Parser.user_prefix(actor), "KICK", [channel, member.nick, reason]))
    if member.nick == state.nick, do: %{state | channels: MapSet.delete(state.channels, channel)}, else: state
  end

  defp deliver_event(state, {:nick_changed, _channel, old, new}) do
    send_line(state, Parser.line(Parser.user_prefix(old), "NICK", [new]))
    if old == state.nick, do: %{state | nick: new}, else: state
  end

  defp deliver_event(state, {:topic_changed, channel, nick, topic}) do
    send_line(state, Parser.line(Parser.user_prefix(nick), "TOPIC", [channel, topic]))
    state
  end

  defp deliver_event(state, {:modes_changed, channel, modes, _member_modes}) do
    flags = for {mode, true} <- modes, mode in [:i, :m, :t], into: "", do: Atom.to_string(mode)
    if flags != "", do: send_line(state, Parser.line(@server, "MODE", [channel, "+" <> flags]))
    state
  end

  defp deliver_event(state, {:buffer_cleared, channel, _actor}) do
    send_line(state, Parser.line(@server, "NOTICE", [channel, "scrollback cleared"]))
    state
  end

  defp deliver_event(state, {:room_ended, channel, actor}) do
    send_line(state, Parser.line(@server, "NOTICE", [channel, "Room ended by #{actor}"]))
    send_line(state, Parser.line(@server, "PART", [channel, "Room ended"]))
    %{state | channels: MapSet.delete(state.channels, channel)}
  end

  defp deliver_event(state, {:room_expired, channel}) do
    send_line(state, Parser.line(@server, "PART", [channel, "Room expired"]))
    %{state | channels: MapSet.delete(state.channels, channel)}
  end

  defp deliver_event(state, _event), do: state

  defp cannot_send(state, target, :body_too_long), do: numeric(state, 404, [target, "Message body too long"])
  defp cannot_send(state, target, :rate_limited), do: numeric(state, 404, [target, "Message rate limited"])
  defp cannot_send(state, target, :moderated), do: numeric(state, 404, [target, "Cannot send to moderated channel"])
  defp cannot_send(state, target, _), do: numeric(state, 404, [target, "Cannot send to channel"])

  defp numeric(state, code, params), do: send_line(state, Parser.numeric(code, state.nick || "*", params))

  defp send_line(state, line), do: state.transport.send(state.socket, line)

  defp terminate(state) do
    Enum.each(state.channels, &ChannelServer.part(&1, state.nick, "quit"))
    NickRegistry.unregister(state.nick)
    :ok
  end

  defp canonical(channel), do: Hangout.ChannelRegistry.canonical!(channel)

  defp parse_mode("i"), do: :i
  defp parse_mode("m"), do: :m
  defp parse_mode("t"), do: :t
  defp parse_mode("l"), do: :l
  defp parse_mode("o"), do: :o
  defp parse_mode("v"), do: :v
  defp parse_mode(_), do: :unknown

  defp split_lines(data) do
    parts = String.split(data, ["\r\n", "\n"])

    case parts do
      [] -> {[], ""}
      _ -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp byte_part(data, start, len), do: binary_part(data, start, len)
  defp format_kind(:notice), do: "NOTICE"
  defp format_kind(_), do: "PRIVMSG"
  defp format_body(%{kind: :action, body: body}), do: <<1>> <> "ACTION " <> body <> <<1>>
  defp format_body(%{body: body}), do: body
end
