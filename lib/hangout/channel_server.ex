defmodule Hangout.ChannelServer do
  @moduledoc "One ephemeral IRC-compatible room process."

  use GenServer, restart: :temporary

  alias Hangout.{AgentToken, ChannelRegistry, Message, Participant, RateLimiter, SecretFilter}

  require Logger

  @max_buffer Application.compile_env(:hangout, :max_buffer_size, 100)
  @body_max_bytes Application.compile_env(:hangout, :message_body_max_bytes, 4000)
  @server_name "hangout"

  defstruct name: nil,
            slug: nil,
            members: %{},
            monitor_refs: %{},
            buffer: :queue.new(),
            buffer_size: 0,
            created_at: nil,
            expires_at: nil,
            creator_public_key: nil,
            mod_capability_hash: nil,
            topic: nil,
            modes: %{i: false, m: false, t: true, l: nil},
            human_count: 0,
            bot_count: 0,
            next_message_id: 1,
            ttl_ref: nil,
            voice_participants: MapSet.new()

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: ChannelRegistry.via(name))
  end

  def join(name, %Participant{} = participant, opts \\ []) do
    with {:ok, pid} <- ChannelRegistry.ensure_started(name, opts) do
      case GenServer.call(pid, {:join, participant, opts}) do
        {:error, reason} = error when reason in [:bot_needs_human, :bad_channel] ->
          GenServer.cast(pid, :stop_if_empty)
          error

        other ->
          other
      end
    end
  end

  def part(name, nick, reason \\ "leaving"), do: call(name, {:part, nick, reason})
  def quit(name, nick, reason \\ "quit"), do: part(name, nick, reason)
  def message(name, nick, kind, body), do: call(name, {:message, nick, kind, body})
  def agent_message(name, owner_nick, body), do: call(name, {:agent_message, owner_nick, body})
  def change_nick(name, old, new), do: call(name, {:nick, old, new})
  def topic(name), do: call(name, :topic)
  def set_topic(name, nick, topic, token \\ nil), do: call(name, {:set_topic, nick, topic, token})
  def names(name), do: call(name, :names)
  def snapshot(name), do: call(name, :snapshot)
  def modauth(name, nick, token), do: call(name, {:modauth, nick, token})
  def kick(name, actor, target, reason, token \\ nil), do: call(name, {:kick, actor, target, reason, token})
  def mode(name, actor, op, mode, arg \\ nil, token \\ nil), do: call(name, {:mode, actor, op, mode, arg, token})
  def clear(name, actor, token \\ nil), do: call(name, {:clear, actor, token})
  def end_room(name, actor, token \\ nil), do: call(name, {:end_room, actor, token})
  def set_ttl(name, actor, seconds, token \\ nil), do: call(name, {:ttl, actor, seconds, token})
  def validate_mod(name, token), do: call(name, {:validate_mod, token})
  def who(name), do: call(name, :who)
  def whois(name, nick), do: call(name, {:whois, nick})
  def mark_bot(name, nick), do: call(name, {:mark_bot, nick})
  def voice_join(name, nick), do: call(name, {:voice_join, nick})
  def voice_leave(name, nick), do: call(name, {:voice_leave, nick})
  def voice_signal(name, from, to, signal), do: call(name, {:voice_signal, from, to, signal})

  def topic_name(channel_name), do: "channel:" <> channel_name

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    name = ChannelRegistry.canonical!(Keyword.fetch!(opts, :name))
    created_at = DateTime.utc_now()
    ttl = Keyword.get(opts, :ttl, Application.get_env(:hangout, :default_ttl))
    {expires_at, ttl_ref} = schedule_ttl(created_at, ttl)

    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       name: name,
       slug: ChannelRegistry.slug(name),
       created_at: created_at,
       expires_at: expires_at,
       creator_public_key: Keyword.get(opts, :creator_public_key),
       ttl_ref: ttl_ref
     }}
  end

  @impl true
  def handle_call({:join, %Participant{} = participant, opts}, _from, state) do
    participant = normalize_participant(participant)
    first_human? = state.human_count == 0 and Participant.human?(participant)

    cond do
      !ChannelRegistry.valid?(state.name) ->
        {:reply, {:error, :bad_channel}, state}

      participant.bot? and state.human_count == 0 and map_size(state.members) == 0 ->
        {:reply, {:error, :bot_needs_human}, state}

      Map.has_key?(state.members, participant.nick) ->
        {:reply, {:error, :already_joined}, state}

      state.modes[:i] and not authorized?(state, participant.nick, Keyword.get(opts, :mod_token)) ->
        {:reply, {:error, :invite_only}, state}

      map_size(state.members) >= max_members(state) ->
        {:reply, {:error, :channel_full}, state}

      true ->
        ref = Process.monitor(participant.pid)

        participant =
          if first_human? do
            %{participant | modes: MapSet.put(participant.modes, :o)}
          else
            participant
          end

        {state, token} =
          if first_human? do
            token = random_token()
            {%{state | mod_capability_hash: hash_token(token)}, token}
          else
            {state, nil}
          end

        state =
          if first_human? and is_binary(participant.public_key) do
            %{state | creator_public_key: participant.public_key}
          else
            state
          end

        state =
          state
          |> put_member(participant.nick, participant)
          |> Map.update!(:monitor_refs, &Map.put(&1, participant.nick, ref))
          |> refresh_counts()

        broadcast(state, {:user_joined, state.name, public_participant(participant)})

        {:reply, {:ok, build_snapshot(state), token}, state}
    end
  end

  def handle_call({:part, nick, reason}, _from, state) do
    case Map.fetch(state.members, nick) do
      :error ->
        {:reply, {:error, :not_on_channel}, state}

      {:ok, participant} ->
        state = remove_member(state, nick) |> refresh_counts()
        event = {:user_parted, state.name, public_participant(participant), reason}
        broadcast(state, event)
        deliver_to(participant, event)
        maybe_stop_if_empty({:reply, :ok, state}, "Room closed: everyone left")
    end
  end

  def handle_call({:message, nick, kind, body}, _from, state) do
    with {:member, %Participant{} = participant} <- {:member, state.members[nick]},
         :ok <- can_send?(state, participant),
         :ok <- validate_body(body),
         {:ok, limiter} <- RateLimiter.check(participant.rate_limit_state) do
      participant = %{participant | rate_limit_state: limiter, last_seen_at: DateTime.utc_now()}
      msg = build_message(state, nick, kind, body)

      state =
        state
        |> put_member(nick, participant)
        |> append_buffer(msg)

      broadcast(state, {:message, state.name, msg})
      route_mentions(state, msg)
      {:reply, {:ok, msg}, state}
    else
      {:member, nil} ->
        {:reply, {:error, :not_on_channel}, state}

      {:error, reason, limiter} ->
        state = update_limiter(state, nick, limiter)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:agent_message, owner_nick, body}, _from, state) do
    with :ok <- can_agent_send?(state),
         :ok <- validate_body(body),
         {:ok, body} <- SecretFilter.check(body) do
      msg = build_message(state, owner_nick, :privmsg, body, true)
      state = append_buffer(state, msg)

      broadcast(state, {:message, state.name, msg})
      {:reply, {:ok, msg}, state}
    else
      {:secret, kind} -> {:reply, {:secret, kind}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:nick, old, new}, _from, state) do
    cond do
      !Map.has_key?(state.members, old) ->
        {:reply, {:error, :not_on_channel}, state}

      Map.has_key?(state.members, new) ->
        {:reply, {:error, :nick_in_use}, state}

      true ->
        AgentToken.revoke_for_nick(state.name, old)
        {participant, members} = Map.pop(state.members, old)
        participant = %{participant | nick: new, last_seen_at: DateTime.utc_now()}
        {ref, refs} = Map.pop(state.monitor_refs, old)
        refs = if ref, do: Map.put(refs, new, ref), else: refs
        voice = if MapSet.member?(state.voice_participants, old) do
          state.voice_participants |> MapSet.delete(old) |> MapSet.put(new)
        else
          state.voice_participants
        end
        state = %{state | members: Map.put(members, new, participant), monitor_refs: refs, voice_participants: voice}
        broadcast(state, {:nick_changed, state.name, old, new})
        {:reply, :ok, state}
    end
  end

  def handle_call(:topic, _from, state), do: {:reply, {:ok, state.topic}, state}

  def handle_call(:names, _from, state) do
    {:reply, {:ok, state.members |> Map.values() |> Enum.map(&public_participant/1)}, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, build_snapshot(state)}, state}

  def handle_call({:set_topic, nick, topic, token}, _from, state) do
    cond do
      !Map.has_key?(state.members, nick) and !valid_token?(state, token) ->
        {:reply, {:error, :not_on_channel}, state}

      authorized?(state, nick, token) or !state.modes[:t] ->
        state = %{state | topic: topic}
        broadcast(state, {:topic_changed, state.name, nick, topic})
        {:reply, :ok, state}

      true ->
        {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:modauth, nick, token}, _from, state) do
    if valid_token?(state, token) and state.members[nick] do
      state = update_member_modes(state, nick, &MapSet.put(&1, :o))
      broadcast(state, {:user_mode_changed, @server_name, nick, state.name, :o, true})
      {:reply, :ok, state}
    else
      {:reply, {:error, :invalid_token}, state}
    end
  end

  def handle_call({:kick, actor, target, reason, token}, _from, state) do
    if authorized?(state, actor, token) do
      case Map.fetch(state.members, target) do
        :error ->
          {:reply, {:error, :not_on_channel}, state}

        {:ok, participant} ->
          state = remove_member(state, target) |> refresh_counts()
          event = {:user_kicked, state.name, actor, public_participant(participant), reason || "kicked"}
          broadcast(state, event)
          deliver_to(participant, event)
          maybe_stop_if_empty({:reply, :ok, state}, "Room closed: everyone left")
      end
    else
      {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:mode, actor, op, mode_key, arg, token}, _from, state) do
    if authorized?(state, actor, token) do
      case apply_mode(state, op, mode_key, arg) do
        {:ok, state} ->
          broadcast(state, {:modes_changed, state.name, state.modes, public_modes(state)})
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:clear, actor, token}, _from, state) do
    if authorized?(state, actor, token) do
      state = %{state | buffer: :queue.new(), buffer_size: 0}
      broadcast(state, {:buffer_cleared, state.name, actor})

      notice = build_message(state, @server_name, :notice, "scrollback cleared")
      state = append_buffer(state, notice)
      broadcast(state, {:message, state.name, notice})

      {:reply, :ok, state}
    else
      {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:end_room, actor, token}, _from, state) do
    if authorized?(state, actor, token) do
      broadcast(state, {:room_ended, state.name, actor})
      {:stop, :normal, :ok, state}
    else
      {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:ttl, actor, seconds, token}, _from, state) do
    cond do
      !authorized?(state, actor, token) ->
        {:reply, {:error, :chanop_needed}, state}

      seconds <= 0 or seconds > max_ttl() ->
        {:reply, {:error, :bad_ttl}, state}

      true ->
        if state.ttl_ref, do: Process.cancel_timer(state.ttl_ref)
        expires_at = DateTime.add(DateTime.utc_now(), seconds, :second)
        ref = Process.send_after(self(), :ttl_expired, seconds * 1000)
        state = %{state | expires_at: expires_at, ttl_ref: ref}
        broadcast(state, {:ttl_changed, state.name, expires_at})
        {:reply, :ok, state}
    end
  end

  def handle_call({:mark_bot, nick}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, %{bot?: true}} ->
        {:reply, :ok, state}

      {:ok, participant} ->
        participant = %{participant | bot?: true}
        human_count = state.human_count - 1
        bot_count = state.bot_count + 1
        state = %{state | members: Map.put(state.members, nick, participant), human_count: human_count, bot_count: bot_count}

        if human_count == 0 do
          broadcast(state, {:room_ended, state.name, "No humans remain"})
          {:stop, :normal, :ok, state}
        else
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_on_channel}, state}
    end
  end

  def handle_call({:voice_join, nick}, _from, state) do
    max = Application.get_env(:hangout, :max_voice_participants, 5)

    cond do
      !Application.get_env(:hangout, :enable_voice, true) ->
        {:reply, {:error, :voice_disabled}, state}

      !Map.has_key?(state.members, nick) ->
        {:reply, {:error, :not_on_channel}, state}

      MapSet.member?(state.voice_participants, nick) ->
        {:reply, {:ok, MapSet.to_list(state.voice_participants)}, state}

      MapSet.size(state.voice_participants) >= max ->
        {:reply, {:error, :voice_full}, state}

      true ->
        state = %{state | voice_participants: MapSet.put(state.voice_participants, nick)}
        existing = MapSet.to_list(state.voice_participants)
        broadcast(state, {:voice_joined, state.name, nick, existing})
        {:reply, {:ok, existing}, state}
    end
  end

  def handle_call({:voice_leave, nick}, _from, state) do
    if MapSet.member?(state.voice_participants, nick) do
      state = %{state | voice_participants: MapSet.delete(state.voice_participants, nick)}
      broadcast(state, {:voice_left, state.name, nick})
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:voice_signal, from, to, signal}, _from, state) do
    # Relay signaling to the target participant's process
    case state.members[to] do
      %{pid: pid} -> send(pid, {:voice_signal, from, signal})
      nil -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:validate_mod, token}, _from, state) do
    {:reply, valid_token?(state, token), state}
  end

  def handle_call(:who, _from, state) do
    who_list =
      Enum.map(state.members, fn {nick, p} ->
        %{nick: nick, user: p.user, realname: p.realname, bot?: p.bot?, modes: MapSet.to_list(p.modes)}
      end)

    {:reply, {:ok, who_list}, state}
  end

  def handle_call({:whois, nick}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, p} ->
        {:reply, {:ok, %{
          nick: p.nick,
          user: p.user,
          realname: p.realname,
          channels: [state.name],
          bot?: p.bot?,
          transport: p.transport
        }}, state}

      :error ->
        {:reply, {:error, :no_such_nick}, state}
    end
  end

  @impl true
  def handle_cast(:stop_if_empty, state) do
    if map_size(state.members) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  @impl true
  def handle_info(:ttl_expired, state) do
    notice = build_message(state, @server_name, :notice, "Room expired")
    broadcast(state, {:message, state.name, notice})
    broadcast(state, {:room_expired, state.name})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.members, fn {_nick, p} -> p.pid == pid end) do
      {nick, participant} ->
        state = remove_member(state, nick) |> refresh_counts()
        event = {:user_quit, state.name, public_participant(participant), "Connection lost"}
        broadcast(state, event)
        maybe_stop_noreply(state, "Last human left")

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.info("Channel #{state.name} terminating",
      members: map_size(state.members),
      buffer_size: state.buffer_size
    )

    # Clean up all agent tokens for this room on any termination path
    AgentToken.cleanup_room(state.name)
    :ok
  end

  # --- Private Helpers ---

  defp call(name, message) do
    with {:ok, pid} <- ChannelRegistry.lookup(name) do
      GenServer.call(pid, message)
    else
      :error -> {:error, :no_such_channel}
    end
  end

  defp normalize_participant(%Participant{} = p) do
    now = DateTime.utc_now()

    %{
      p
      | joined_at: p.joined_at || now,
        last_seen_at: p.last_seen_at || now,
        rate_limit_state: p.rate_limit_state || RateLimiter.new()
    }
  end

  defp validate_body(body) when is_binary(body) and byte_size(body) > @body_max_bytes, do: {:error, :body_too_long}
  defp validate_body(body) when is_binary(body), do: :ok
  defp validate_body(_), do: {:error, :body_too_long}

  defp can_send?(state, participant) do
    cond do
      !state.modes[:m] -> :ok
      MapSet.member?(participant.modes, :o) or MapSet.member?(participant.modes, :v) -> :ok
      true -> {:error, :moderated}
    end
  end

  defp update_limiter(state, nick, limiter) do
    case state.members[nick] do
      nil -> state
      participant -> put_member(state, nick, %{participant | rate_limit_state: limiter})
    end
  end

  defp can_agent_send?(state) do
    if state.modes[:m], do: {:error, :agent_muted}, else: :ok
  end

  defp build_message(state, nick, kind, body, agent \\ false) do
    %Message{
      id: state.next_message_id,
      at: DateTime.utc_now(),
      from: nick,
      target: state.name,
      kind: kind,
      body: body,
      agent: agent
    }
  end

  defp append_buffer(state, msg) do
    buffer = :queue.in(msg, state.buffer)
    buffer_size = state.buffer_size + 1

    {buffer, buffer_size} =
      if buffer_size > @max_buffer do
        {{:value, _}, buffer} = :queue.out(buffer)
        {buffer, buffer_size - 1}
      else
        {buffer, buffer_size}
      end

    %{state | buffer: buffer, buffer_size: buffer_size, next_message_id: state.next_message_id + 1}
  end

  defp refresh_counts(state) do
    {humans, bots} =
      state.members
      |> Map.values()
      |> Enum.reduce({0, 0}, fn
        %Participant{bot?: true}, {h, b} -> {h, b + 1}
        %Participant{}, {h, b} -> {h + 1, b}
      end)

    %{state | human_count: humans, bot_count: bots}
  end

  defp maybe_stop_if_empty({:reply, reply, state}, notice) do
    if state.human_count == 0 do
      broadcast(state, {:notice, state.name, @server_name, notice})
      {:stop, :normal, reply, state}
    else
      {:reply, reply, state}
    end
  end

  defp maybe_stop_noreply(state, notice) do
    if state.human_count == 0 do
      broadcast(state, {:notice, state.name, @server_name, notice})
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp apply_mode(state, op, mode_key, _arg) when mode_key in [:i, :m, :t] do
    {:ok, put_mode(state, mode_key, op == "+")}
  end

  defp apply_mode(state, "+", mode_key, nick) when mode_key in [:o, :v] and is_binary(nick) do
    if state.members[nick] do
      {:ok, update_member_modes(state, nick, &MapSet.put(&1, mode_key))}
    else
      {:error, :not_on_channel}
    end
  end

  defp apply_mode(state, "-", mode_key, nick) when mode_key in [:o, :v] and is_binary(nick) do
    if state.members[nick] do
      {:ok, update_member_modes(state, nick, &MapSet.delete(&1, mode_key))}
    else
      {:error, :not_on_channel}
    end
  end

  defp apply_mode(state, "+", :l, limit) do
    case Integer.parse(to_string(limit || "")) do
      {n, ""} when n > 0 -> {:ok, put_mode(state, :l, n)}
      _ -> {:error, :bad_mode}
    end
  end

  defp apply_mode(state, "-", :l, _), do: {:ok, put_mode(state, :l, nil)}
  defp apply_mode(_state, _op, _mode, _arg), do: {:error, :bad_mode}

  defp authorized?(state, nick, token) do
    valid_token?(state, token) or
      case state.members[nick] do
        %Participant{modes: modes} -> MapSet.member?(modes, :o)
        _ -> false
      end
  end

  defp valid_token?(_state, nil), do: false
  defp valid_token?(_state, ""), do: false
  defp valid_token?(%{mod_capability_hash: nil}, _token), do: false

  defp valid_token?(state, token) do
    :crypto.hash_equals(state.mod_capability_hash, hash_token(token))
  end

  defp hash_token(token), do: :crypto.hash(:sha256, to_string(token))

  defp random_token do
    bytes = Application.get_env(:hangout, :capability_token_bytes, 16)
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp schedule_ttl(_created_at, nil), do: {nil, nil}

  defp schedule_ttl(created_at, seconds) when is_integer(seconds) and seconds > 0 do
    seconds = min(seconds, max_ttl())
    expires_at = DateTime.add(created_at, seconds, :second)
    {expires_at, Process.send_after(self(), :ttl_expired, seconds * 1000)}
  end

  defp schedule_ttl(_, _), do: {nil, nil}

  defp max_ttl, do: Application.get_env(:hangout, :max_ttl, 86_400)

  defp max_members(state) do
    state.modes[:l] || Application.get_env(:hangout, :max_members_per_channel, 200)
  end

  defp build_snapshot(state) do
    %{
      name: state.name,
      slug: state.slug,
      members: state.members |> Map.values() |> Enum.map(&public_participant/1),
      buffer: :queue.to_list(state.buffer),
      created_at: state.created_at,
      expires_at: state.expires_at,
      topic: state.topic,
      modes: state.modes,
      human_count: state.human_count,
      bot_count: state.bot_count,
      voice_participants: MapSet.to_list(state.voice_participants)
    }
  end

  defp put_member(state, nick, participant) do
    %{state | members: Map.put(state.members, nick, participant)}
  end

  defp remove_member(state, nick) do
    was_op = match?(%Participant{modes: modes} when is_struct(modes), state.members[nick]) and
             MapSet.member?(state.members[nick].modes, :o)
    was_in_voice = MapSet.member?(state.voice_participants, nick)
    AgentToken.revoke_for_nick(state.name, nick)

    state =
      case Map.pop(state.monitor_refs, nick) do
        {ref, refs} when is_reference(ref) ->
          Process.demonitor(ref, [:flush])
          %{state | members: Map.delete(state.members, nick), monitor_refs: refs}

        {nil, _} ->
          %{state | members: Map.delete(state.members, nick)}
      end

    state = %{state | voice_participants: MapSet.delete(state.voice_participants, nick)}
    if was_in_voice, do: broadcast(state, {:voice_left, state.name, nick})

    # Mod succession: if the departing member was an op and no ops remain, promote the longest-tenured human
    state = maybe_promote_successor(state, was_op)
    state
  end

  defp maybe_promote_successor(state, false), do: state

  defp maybe_promote_successor(state, true) do
    has_ops = Enum.any?(state.members, fn {_nick, p} -> MapSet.member?(p.modes, :o) end)

    if has_ops do
      state
    else
      state.members
      |> Map.values()
      |> Enum.filter(&Participant.human?/1)
      |> Enum.sort_by(& &1.joined_at, DateTime)
      |> List.first()
      |> case do
        nil -> state
        successor ->
          state = update_member_modes(state, successor.nick, &MapSet.put(&1, :o))
          broadcast(state, {:user_mode_changed, @server_name, successor.nick, state.name, :o, true})
          state
      end
    end
  end

  defp update_member_modes(state, nick, fun) do
    participant = %{state.members[nick] | modes: fun.(state.members[nick].modes)}
    put_member(state, nick, participant)
  end

  defp put_mode(state, mode_key, value) do
    %{state | modes: Map.put(state.modes, mode_key, value)}
  end

  defp public_modes(state) do
    Map.new(state.members, fn {nick, p} -> {nick, MapSet.to_list(p.modes)} end)
  end

  defp public_participant(%Participant{} = p) do
    %{
      nick: p.nick,
      user: p.user,
      realname: p.realname,
      public_key: p.public_key,
      transport: p.transport,
      bot?: p.bot?,
      joined_at: p.joined_at,
      last_seen_at: p.last_seen_at,
      modes: MapSet.to_list(p.modes)
    }
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(Hangout.PubSub, topic_name(state.name), {:hangout_event, event})
  end

  defp route_mentions(_state, %Message{agent: true}), do: :ok

  defp route_mentions(state, %Message{kind: kind} = msg) when kind in [:privmsg, :action] do
    body = strip_backtick_spans(msg.body)

    state.name
    |> AgentToken.active_for_room()
    |> Enum.filter(&mentions_owner?(body, &1.owner_nick))
    |> Enum.reject(fn metadata ->
      String.downcase(msg.from) == String.downcase(metadata.owner_nick)
    end)
    |> Enum.each(fn metadata ->
      event = {
        :hangout_event,
        {:mention,
         %{
           "id" => msg.id,
           "from" => %{"nick" => msg.from, "agent" => false},
           "body" => msg.body,
           "at" => DateTime.to_iso8601(msg.at)
         }}
      }

      Phoenix.PubSub.broadcast(Hangout.PubSub, AgentToken.agent_topic(metadata.token_hash), event)
    end)
  end

  defp route_mentions(_state, _msg), do: :ok

  defp mentions_owner?(body, owner_nick) do
    escaped = Regex.escape(owner_nick)
    Regex.match?(~r/(^|[^\p{L}\p{N}_])@#{escaped}🤖(?=$|[^\p{L}\p{N}_])/iu, body)
  end

  defp strip_backtick_spans(body), do: strip_backtick_spans(body, false, "")

  defp strip_backtick_spans(<<"`", rest::binary>>, in_code?, acc) do
    strip_backtick_spans(rest, !in_code?, acc)
  end

  defp strip_backtick_spans(<<char::utf8, rest::binary>>, false, acc) do
    strip_backtick_spans(rest, false, <<acc::binary, char::utf8>>)
  end

  defp strip_backtick_spans(<<_char::utf8, rest::binary>>, true, acc) do
    strip_backtick_spans(rest, true, acc)
  end

  defp strip_backtick_spans(<<>>, _in_code?, acc), do: acc

  defp deliver_to(%Participant{transport: :irc, pid: pid}, event) do
    send(pid, {:hangout_event, event})
  end

  defp deliver_to(_participant, _event), do: :ok
end
