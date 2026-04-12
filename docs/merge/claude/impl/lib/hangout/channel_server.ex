defmodule Hangout.ChannelServer do
  @moduledoc """
  GenServer per channel. Holds all room state in memory.
  Terminates when the last human leaves or TTL expires.
  """

  use GenServer, restart: :temporary

  alias Hangout.{Message, Participant, RateLimiter, ChannelRegistry}

  require Logger

  @max_buffer Application.compile_env(:hangout, :max_buffer_size, 100)
  @body_max_bytes Application.compile_env(:hangout, :message_body_max_bytes, 400)
  @max_members Application.compile_env(:hangout, :max_members_per_channel, 200)
  @server_name "hangout"

  # --- State ---

  defstruct [
    :channel_name,
    :slug,
    :created_at,
    :expires_at,
    :creator_public_key,
    :mod_capability_hash,
    :topic,
    :ttl_timer,
    modes: %{},
    members: %{},
    buffer: :queue.new(),
    buffer_size: 0,
    human_count: 0,
    bot_count: 0,
    rate_limiters: %{}
  ]

  # --- Client API ---

  def start_link(opts) do
    channel_name = Keyword.fetch!(opts, :channel_name)
    GenServer.start_link(__MODULE__, opts, name: ChannelRegistry.via(channel_name))
  end

  def join(channel_name, participant) do
    GenServer.call(via(channel_name), {:join, participant})
  end

  def part(channel_name, nick, message \\ nil) do
    GenServer.call(via(channel_name), {:part, nick, message})
  end

  def send_message(channel_name, nick, body) do
    GenServer.call(via(channel_name), {:privmsg, nick, body})
  end

  def send_notice(channel_name, nick, body) do
    GenServer.call(via(channel_name), {:notice, nick, body})
  end

  def send_action(channel_name, nick, body) do
    GenServer.call(via(channel_name), {:action, nick, body})
  end

  def change_nick(channel_name, old_nick, new_nick) do
    GenServer.call(via(channel_name), {:nick_change, old_nick, new_nick})
  end

  def set_topic(channel_name, nick, topic) do
    GenServer.call(via(channel_name), {:set_topic, nick, topic})
  end

  def get_topic(channel_name) do
    GenServer.call(via(channel_name), :get_topic)
  end

  def get_members(channel_name) do
    GenServer.call(via(channel_name), :get_members)
  end

  def get_buffer(channel_name) do
    GenServer.call(via(channel_name), :get_buffer)
  end

  def kick(channel_name, kicker_nick, target_nick, reason \\ "Kicked") do
    GenServer.call(via(channel_name), {:kick, kicker_nick, target_nick, reason})
  end

  def set_mode(channel_name, nick, mode, value) do
    GenServer.call(via(channel_name), {:set_mode, nick, mode, value})
  end

  def set_user_mode(channel_name, setter_nick, target_nick, mode, value) do
    GenServer.call(via(channel_name), {:set_user_mode, setter_nick, target_nick, mode, value})
  end

  def mod_auth(channel_name, nick, token) do
    GenServer.call(via(channel_name), {:mod_auth, nick, token})
  end

  def set_ttl(channel_name, nick, seconds) do
    GenServer.call(via(channel_name), {:set_ttl, nick, seconds})
  end

  def clear_buffer(channel_name, nick) do
    GenServer.call(via(channel_name), {:clear, nick})
  end

  def end_channel(channel_name, nick) do
    GenServer.call(via(channel_name), {:end_channel, nick})
  end

  def mark_bot(channel_name, nick) do
    GenServer.call(via(channel_name), {:mark_bot, nick})
  end

  def get_state(channel_name) do
    GenServer.call(via(channel_name), :get_state)
  end

  def who(channel_name) do
    GenServer.call(via(channel_name), :who)
  end

  def whois(channel_name, nick) do
    GenServer.call(via(channel_name), {:whois, nick})
  end

  def private_message(from_nick, to_nick, body) do
    case Hangout.NickRegistry.lookup(to_nick) do
      {:ok, pid} ->
        send(pid, {:private_message, from_nick, to_nick, body})
        :ok

      :error ->
        {:error, :no_such_nick}
    end
  end

  defp via(channel_name), do: ChannelRegistry.via(channel_name)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    channel_name = Keyword.fetch!(opts, :channel_name)
    slug = String.trim_leading(channel_name, "#")

    # Generate capability token
    token_bytes = Application.get_env(:hangout, :capability_token_bytes, 16)
    raw_token = :crypto.strong_rand_bytes(token_bytes) |> Base.encode16(case: :lower)
    capability_hash = :crypto.hash(:sha256, raw_token)

    state = %__MODULE__{
      channel_name: channel_name,
      slug: slug,
      created_at: DateTime.utc_now(),
      expires_at: Keyword.get(opts, :expires_at),
      creator_public_key: Keyword.get(opts, :creator_public_key),
      mod_capability_hash: capability_hash,
      topic: Keyword.get(opts, :topic),
      modes: %{}
    }

    # Schedule TTL if provided
    state =
      case Keyword.get(opts, :ttl_seconds) do
        nil -> state
        seconds -> schedule_ttl(state, seconds)
      end

    Process.flag(:trap_exit, true)

    {:ok, state, {:continue, {:created, raw_token}}}
  end

  @impl true
  def handle_continue({:created, raw_token}, state) do
    # Broadcast creation event with capability token
    Phoenix.PubSub.broadcast(
      Hangout.PubSub,
      pubsub_topic(state.channel_name),
      {:channel_created, state.channel_name, raw_token}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call({:join, %Participant{} = participant}, _from, state) do
    cond do
      Map.has_key?(state.members, participant.nick) ->
        {:reply, {:error, :already_joined}, state}

      map_size(state.members) >= @max_members ->
        {:reply, {:error, :channel_full}, state}

      state.modes[:i] == true ->
        {:reply, {:error, :invite_only}, state}

      true ->
        Process.monitor(participant.pid)

        updated_participant = %{participant | joined_at: DateTime.utc_now(), last_seen_at: DateTime.utc_now()}
        members = Map.put(state.members, participant.nick, updated_participant)

        {human_count, bot_count} = count_members(members)

        state = %{state |
          members: members,
          human_count: human_count,
          bot_count: bot_count
        }

        # Broadcast join
        broadcast(state, {:user_joined, participant.nick, state.channel_name})

        buffer_list = :queue.to_list(state.buffer)

        {:reply, {:ok, %{
          topic: state.topic,
          members: Map.keys(state.members),
          buffer: buffer_list,
          modes: state.modes,
          mod_capability_hash: state.mod_capability_hash
        }}, state}
    end
  end

  def handle_call({:part, nick, message}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, _participant} ->
        broadcast(state, {:user_parted, nick, state.channel_name, message})
        state = remove_member(state, nick)

        if state.human_count == 0 do
          broadcast(state, {:room_ended, state.channel_name, "Last human left"})
          {:stop, :normal, :ok, state}
        else
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call({:privmsg, nick, body}, _from, state) do
    with {:ok, state} <- check_can_send(state, nick),
         :ok <- validate_body(body) do
      msg = Message.new(nick, state.channel_name, :privmsg, body)
      state = append_message(state, msg)
      broadcast(state, {:new_message, msg})
      {:reply, {:ok, msg}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notice, nick, body}, _from, state) do
    with :ok <- validate_body(body) do
      msg = Message.new(nick, state.channel_name, :notice, body)
      state = append_message(state, msg)
      broadcast(state, {:new_message, msg})
      {:reply, {:ok, msg}, state}
    end
  end

  def handle_call({:action, nick, body}, _from, state) do
    with {:ok, state} <- check_can_send(state, nick),
         :ok <- validate_body(body) do
      msg = Message.new(nick, state.channel_name, :action, body)
      state = append_message(state, msg)
      broadcast(state, {:new_message, msg})
      {:reply, {:ok, msg}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:nick_change, old_nick, new_nick}, _from, state) do
    case Map.fetch(state.members, old_nick) do
      {:ok, participant} ->
        updated = %{participant | nick: new_nick, last_seen_at: DateTime.utc_now()}
        members = state.members |> Map.delete(old_nick) |> Map.put(new_nick, updated)

        # Update rate limiter key
        rate_limiters =
          case Map.pop(state.rate_limiters, old_nick) do
            {nil, rl} -> rl
            {limiter, rl} -> Map.put(rl, new_nick, limiter)
          end

        state = %{state | members: members, rate_limiters: rate_limiters}
        broadcast(state, {:nick_changed, old_nick, new_nick, state.channel_name})
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call({:set_topic, nick, topic}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        if state.modes[:t] == true and not Participant.operator?(participant) do
          {:reply, {:error, :chanop_needed}, state}
        else
          state = %{state | topic: topic}
          broadcast(state, {:topic_changed, nick, state.channel_name, topic})
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call(:get_topic, _from, state) do
    {:reply, {:ok, state.topic}, state}
  end

  def handle_call(:get_members, _from, state) do
    {:reply, {:ok, state.members}, state}
  end

  def handle_call(:get_buffer, _from, state) do
    {:reply, {:ok, :queue.to_list(state.buffer)}, state}
  end

  def handle_call({:kick, kicker_nick, target_nick, reason}, _from, state) do
    with {:ok, kicker} <- Map.fetch(state.members, kicker_nick),
         true <- Participant.operator?(kicker),
         {:ok, _target} <- Map.fetch(state.members, target_nick) do
      broadcast(state, {:user_kicked, kicker_nick, target_nick, state.channel_name, reason})
      state = remove_member(state, target_nick)

      if state.human_count == 0 do
        broadcast(state, {:room_ended, state.channel_name, "Last human left"})
        {:stop, :normal, :ok, state}
      else
        {:reply, :ok, state}
      end
    else
      :error -> {:reply, {:error, :not_in_channel}, state}
      false -> {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:set_mode, nick, mode, value}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        if Participant.operator?(participant) do
          modes = Map.put(state.modes, mode, value)
          state = %{state | modes: modes}
          broadcast(state, {:modes_changed, nick, state.channel_name, mode, value})
          {:reply, :ok, state}
        else
          {:reply, {:error, :chanop_needed}, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call({:set_user_mode, setter_nick, target_nick, mode, value}, _from, state) do
    with {:ok, setter} <- Map.fetch(state.members, setter_nick),
         true <- Participant.operator?(setter),
         {:ok, target} <- Map.fetch(state.members, target_nick) do
      updated_modes =
        if value do
          MapSet.put(target.modes, mode)
        else
          MapSet.delete(target.modes, mode)
        end

      updated_target = %{target | modes: updated_modes}
      members = Map.put(state.members, target_nick, updated_target)
      state = %{state | members: members}
      broadcast(state, {:user_mode_changed, setter_nick, target_nick, state.channel_name, mode, value})
      {:reply, :ok, state}
    else
      :error -> {:reply, {:error, :not_in_channel}, state}
      false -> {:reply, {:error, :chanop_needed}, state}
    end
  end

  def handle_call({:mod_auth, nick, token}, _from, state) do
    token_hash = :crypto.hash(:sha256, token)

    if :crypto.hash_equals(state.mod_capability_hash, token_hash) do
      case Map.fetch(state.members, nick) do
        {:ok, participant} ->
          updated = %{participant | modes: MapSet.put(participant.modes, :o)}
          members = Map.put(state.members, nick, updated)
          state = %{state | members: members}
          broadcast(state, {:user_mode_changed, @server_name, nick, state.channel_name, :o, true})
          {:reply, :ok, state}

        :error ->
          {:reply, {:error, :not_in_channel}, state}
      end
    else
      {:reply, {:error, :invalid_token}, state}
    end
  end

  def handle_call({:set_ttl, nick, seconds}, _from, state) do
    max_ttl = Application.get_env(:hangout, :max_ttl, 86_400)

    cond do
      seconds > max_ttl ->
        {:reply, {:error, :ttl_too_large}, state}

      seconds <= 0 ->
        {:reply, {:error, :invalid_ttl}, state}

      true ->
        case Map.fetch(state.members, nick) do
          {:ok, participant} ->
            if Participant.operator?(participant) or
                 (state.creator_public_key != nil and participant.public_key == state.creator_public_key) or
                 map_size(state.members) == 1 do
              state = schedule_ttl(state, seconds)
              broadcast(state, {:ttl_set, nick, state.channel_name, state.expires_at})
              {:reply, :ok, state}
            else
              {:reply, {:error, :chanop_needed}, state}
            end

          :error ->
            {:reply, {:error, :not_in_channel}, state}
        end
    end
  end

  def handle_call({:clear, nick}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        if Participant.operator?(participant) do
          state = %{state | buffer: :queue.new(), buffer_size: 0}
          broadcast(state, {:buffer_cleared, nick, state.channel_name})
          {:reply, :ok, state}
        else
          {:reply, {:error, :chanop_needed}, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call({:end_channel, nick}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        if Participant.operator?(participant) do
          broadcast(state, {:room_ended, state.channel_name, "Room ended by #{nick}"})
          {:stop, :normal, :ok, state}
        else
          {:reply, {:error, :chanop_needed}, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call({:mark_bot, nick}, _from, state) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        updated = %{participant | bot?: true}
        members = Map.put(state.members, nick, updated)
        {human_count, bot_count} = count_members(members)
        state = %{state | members: members, human_count: human_count, bot_count: bot_count}

        if human_count == 0 do
          broadcast(state, {:room_ended, state.channel_name, "No humans remain"})
          {:stop, :normal, :ok, state}
        else
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:who, _from, state) do
    who_list =
      Enum.map(state.members, fn {nick, p} ->
        %{nick: nick, user: p.user, realname: p.realname, bot?: p.bot?, modes: p.modes}
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
          channels: [state.channel_name],
          bot?: p.bot?
        }}, state}

      :error ->
        {:reply, {:error, :no_such_nick}, state}
    end
  end

  @impl true
  def handle_info(:ttl_expired, state) do
    # Broadcast TTL expiry notice
    notice = Message.new(@server_name, state.channel_name, :notice, "Room expired")
    broadcast(state, {:new_message, notice})
    broadcast(state, {:room_expired, state.channel_name})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Find the member whose process died
    case Enum.find(state.members, fn {_nick, p} -> p.pid == pid end) do
      {nick, _participant} ->
        broadcast(state, {:user_quit, nick, state.channel_name, "Connection lost"})
        state = remove_member(state, nick)

        if state.human_count == 0 do
          broadcast(state, {:room_ended, state.channel_name, "Last human left"})
          {:stop, :normal, state}
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("Channel process terminating",
      channel_count: map_size(state.members),
      buffer_count: state.buffer_size
    )

    :ok
  end

  # --- Private Helpers ---

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(Hangout.PubSub, pubsub_topic(state.channel_name), message)
  end

  defp pubsub_topic(channel_name), do: "channel:#{channel_name}"

  defp append_message(state, msg) do
    buffer = :queue.in(msg, state.buffer)
    buffer_size = state.buffer_size + 1

    {buffer, buffer_size} =
      if buffer_size > @max_buffer do
        {{:value, _}, buffer} = :queue.out(buffer)
        {buffer, buffer_size - 1}
      else
        {buffer, buffer_size}
      end

    %{state | buffer: buffer, buffer_size: buffer_size}
  end

  defp remove_member(state, nick) do
    members = Map.delete(state.members, nick)
    rate_limiters = Map.delete(state.rate_limiters, nick)
    {human_count, bot_count} = count_members(members)

    %{state |
      members: members,
      rate_limiters: rate_limiters,
      human_count: human_count,
      bot_count: bot_count
    }
  end

  defp count_members(members) do
    Enum.reduce(members, {0, 0}, fn {_nick, p}, {h, b} ->
      if p.bot?, do: {h, b + 1}, else: {h + 1, b}
    end)
  end

  defp check_can_send(state, nick) do
    case Map.fetch(state.members, nick) do
      {:ok, participant} ->
        cond do
          state.modes[:m] == true and
            not Participant.operator?(participant) and
            not Participant.voiced?(participant) ->
            {:error, :cannot_send}

          true ->
            # Rate limiting
            limiter = Map.get(state.rate_limiters, nick, RateLimiter.default_message_limiter())

            case RateLimiter.check(limiter) do
              {:ok, updated_limiter} ->
                state = %{state | rate_limiters: Map.put(state.rate_limiters, nick, updated_limiter)}
                {:ok, state}

              {:error, :rate_limited} ->
                {:error, :rate_limited, state}
            end
        end

      :error ->
        {:error, :not_in_channel}
    end
  end

  defp validate_body(body) when byte_size(body) > @body_max_bytes, do: {:error, :body_too_long}
  defp validate_body(_body), do: :ok

  defp schedule_ttl(state, seconds) do
    # Cancel existing timer if any
    if state.ttl_timer, do: Process.cancel_timer(state.ttl_timer)

    expires_at = DateTime.add(DateTime.utc_now(), seconds, :second)
    timer = Process.send_after(self(), :ttl_expired, seconds * 1000)

    %{state | expires_at: expires_at, ttl_timer: timer}
  end
end
