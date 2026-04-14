defmodule Hangout.AgentToken do
  @moduledoc """
  In-memory bearer tokens for room agent participation.
  """

  use GenServer

  alias Hangout.ChannelRegistry

  @table :agent_tokens
  @dedup_table :agent_msg_dedup
  @rate_table :agent_rate_limit
  @presence_table :agent_presence
  @prefix "agt_"
  @token_bytes 32
  @default_ttl_seconds 24 * 60 * 60

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def table, do: @table

  @valid_modes ~w(off draft called free)a

  def create(room_id, owner_nick, keypair_fingerprint, mode \\ :called)
      when mode in @valid_modes do
    GenServer.call(__MODULE__, {:create, room_id, owner_nick, keypair_fingerprint, mode})
  end

  def update_mode(raw_token, mode) when is_binary(raw_token) and mode in @valid_modes do
    token_hash = hash_token(raw_token)

    case :ets.lookup(@table, token_hash) do
      [{^token_hash, metadata}] ->
        :ets.insert(@table, {token_hash, %{metadata | mode: mode}})
        :ok

      [] ->
        {:error, :invalid_token}
    end
  end

  def validate(room_slug, raw_token) when is_binary(raw_token) do
    token_hash = hash_token(raw_token)

    with [{^token_hash, metadata}] <- :ets.lookup(@table, token_hash),
         :ok <- validate_metadata(room_slug, metadata) do
      {:ok, metadata}
    else
      [] -> {:error, :invalid_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_room_slug, _raw_token), do: {:error, :invalid_token}

  def revoke(raw_token) when is_binary(raw_token) do
    token_hash = hash_token(raw_token)

    case :ets.lookup(@table, token_hash) do
      [{^token_hash, metadata}] ->
        :ets.insert(@table, {token_hash, %{metadata | revoked_at: DateTime.utc_now()}})
        Phoenix.PubSub.broadcast(Hangout.PubSub, agent_topic(token_hash), {:agent_revoked, token_hash})
        cleanup_token_state(token_hash)
        :ok

      [] ->
        {:error, :invalid_token}
    end
  end

  def revoke(_raw_token), do: {:error, :invalid_token}

  def revoke_for_nick(room_id, nick) do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {hash, metadata}, count ->
        if same_agent?(metadata, room_id, nick) and active_metadata?(metadata, now) do
          :ets.insert(@table, {hash, %{metadata | revoked_at: now}})
          Phoenix.PubSub.broadcast(Hangout.PubSub, agent_topic(hash), {:agent_revoked, hash})
          cleanup_token_state(hash)
          count + 1
        else
          count
        end
      end,
      0,
      @table
    )
  end

  def find_active_for_nick(room_id, nick) do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {hash, metadata}, acc ->
        if acc == :none and same_agent?(metadata, room_id, nick) and
             active_metadata?(metadata, now) do
          {:ok, Map.put(metadata, :token_hash, hash)}
        else
          acc
        end
      end,
      :none,
      @table
    )
  end

  def active_for_room(room_id) do
    room_id = ChannelRegistry.canonical!(room_id)
    now = DateTime.utc_now()

    :ets.foldl(
      fn {hash, metadata}, acc ->
        if metadata.room_id == room_id and active_metadata?(metadata, now) do
          [Map.put(metadata, :token_hash, hash) | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  def agent_topic(token_hash), do: "agent:" <> Base.encode16(token_hash, case: :lower)

  def presence_topic(channel_name, owner_nick),
    do: "agent_presence:" <> channel_name <> ":" <> owner_nick

  @doc "Record that an agent SSE stream has attached. Broadcasts if state transitions to attached."
  def mark_attached(token_hash, pid, topic) when is_binary(token_hash) and is_pid(pid) do
    was_attached? = :ets.member(@presence_table, token_hash)
    :ets.insert(@presence_table, {token_hash, pid})

    unless was_attached? do
      Phoenix.PubSub.broadcast(Hangout.PubSub, topic, {:agent_attached, token_hash})
    end

    :ok
  end

  @doc "Record that an agent SSE stream has detached. Broadcasts only if this was the active stream."
  def mark_detached(token_hash, pid, topic) when is_binary(token_hash) and is_pid(pid) do
    case :ets.lookup(@presence_table, token_hash) do
      [{^token_hash, ^pid}] ->
        :ets.delete(@presence_table, token_hash)
        Phoenix.PubSub.broadcast(Hangout.PubSub, topic, {:agent_detached, token_hash})
        :ok

      _ ->
        :ok
    end
  end

  def attached?(token_hash) when is_binary(token_hash),
    do: :ets.member(@presence_table, token_hash)

  def check_rate_limit(raw_token, max_per_minute \\ 6) do
    token_hash = hash_token(raw_token)
    # Fixed-window rate limit keyed by {token_hash, minute_bucket}
    minute = div(System.monotonic_time(:second), 60)
    key = {token_hash, minute}

    # Ensure entry exists, then atomically increment
    :ets.insert_new(@rate_table, {key, 0})
    count = :ets.update_counter(@rate_table, key, {2, 1})

    if count > max_per_minute do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc "Atomically reserve a client_msg_id. Returns :ok or {:error, :duplicate}."
  def check_dedup(_raw_token, nil), do: :ok
  def check_dedup(_raw_token, ""), do: :ok

  def check_dedup(raw_token, client_msg_id) when is_binary(client_msg_id) do
    token_hash = hash_token(raw_token)
    key = {token_hash, client_msg_id}
    now = System.monotonic_time(:millisecond)

    # insert_new is atomic — only one concurrent caller wins
    if :ets.insert_new(@dedup_table, {key, now}) do
      prune_dedup(token_hash)
      :ok
    else
      {:error, :duplicate}
    end
  end

  def check_dedup(_raw_token, _client_msg_id), do: :ok

  @doc "Release a dedup reservation on publish failure."
  def release_dedup(_raw_token, nil), do: :ok
  def release_dedup(_raw_token, ""), do: :ok

  def release_dedup(raw_token, client_msg_id) when is_binary(client_msg_id) do
    token_hash = hash_token(raw_token)
    :ets.delete(@dedup_table, {token_hash, client_msg_id})
    :ok
  end

  def release_dedup(_raw_token, _client_msg_id), do: :ok

  def hash_token(raw_token), do: :crypto.hash(:sha256, raw_token)

  def reset! do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@dedup_table)
    :ets.delete_all_objects(@rate_table)
    :ets.delete_all_objects(@presence_table)
  end

  @impl true
  def init(:ok) do
    ensure_table(@table)
    ensure_table(@dedup_table)
    ensure_table(@rate_table)
    ensure_table(@presence_table)
    {:ok, %{rooms: MapSet.new()}}
  end

  @impl true
  def handle_call({:create, room_id, owner_nick, keypair_fingerprint, mode}, _from, state) do
    room_id = ChannelRegistry.canonical!(room_id)

    case find_active_for_nick(room_id, owner_nick) do
      {:ok, _metadata} ->
        {:reply, {:error, :active_token_exists}, state}

      :none ->
        token =
          @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

        token_hash = hash_token(token)
        now = DateTime.utc_now()
        ttl = Application.get_env(:hangout, :agent_token_ttl_seconds, @default_ttl_seconds)

        metadata = %{
          room_id: room_id,
          room_slug: ChannelRegistry.slug(room_id),
          owner_nick: owner_nick,
          keypair_fingerprint: keypair_fingerprint,
          mode: mode,
          created_at: now,
          expires_at: DateTime.add(now, ttl, :second),
          revoked_at: nil
        }

        :ets.insert(@table, {token_hash, metadata})

        state =
          if MapSet.member?(state.rooms, room_id) do
            state
          else
            Phoenix.PubSub.subscribe(Hangout.PubSub, channel_topic(room_id))
            %{state | rooms: MapSet.put(state.rooms, room_id)}
          end

        {:reply, {:ok, token}, state}
    end
  end

  @impl true
  def handle_info({:hangout_event, {:room_ended, room_id, _actor}}, state) do
    cleanup_room(room_id)
    {:noreply, %{state | rooms: MapSet.delete(state.rooms, room_id)}}
  end

  def handle_info({:hangout_event, {:room_expired, room_id}}, state) do
    cleanup_room(room_id)
    {:noreply, %{state | rooms: MapSet.delete(state.rooms, room_id)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp validate_metadata(room_slug, metadata) do
    cond do
      metadata.room_slug != ChannelRegistry.slug(room_slug) ->
        {:error, :room_mismatch}

      metadata.revoked_at ->
        {:error, :token_revoked}

      DateTime.compare(DateTime.utc_now(), metadata.expires_at) == :gt ->
        {:error, :token_expired}

      not ChannelRegistry.exists?(metadata.room_id) ->
        {:error, :room_ended}

      true ->
        :ok
    end
  end

  defp active_metadata?(metadata, now) do
    is_nil(metadata.revoked_at) and DateTime.compare(now, metadata.expires_at) != :gt
  end

  defp same_agent?(metadata, room_id, nick) do
    metadata.room_id == ChannelRegistry.canonical!(room_id) and
      String.downcase(metadata.owner_nick) == String.downcase(nick)
  end

  def cleanup_room(room_id) do
    room_id = ChannelRegistry.canonical!(room_id)

    :ets.foldl(
      fn {hash, metadata}, :ok ->
        if metadata.room_id == room_id do
          Phoenix.PubSub.broadcast(Hangout.PubSub, agent_topic(hash), {:agent_revoked, hash})
          cleanup_token_state(hash)
          :ets.delete(@table, hash)
        end
        :ok
      end,
      :ok,
      @table
    )
  end

  defp channel_topic(room_id), do: "channel:" <> room_id

  defp cleanup_token_state(token_hash) do
    :ets.delete(@presence_table, token_hash)

    # Remove dedup entries for this token
    :ets.foldl(
      fn
        {{^token_hash, _} = key, _}, :ok -> :ets.delete(@dedup_table, key); :ok
        _, :ok -> :ok
      end,
      :ok,
      @dedup_table
    )

    # Remove rate limit buckets for this token
    :ets.foldl(
      fn
        {{^token_hash, _} = key, _}, :ok -> :ets.delete(@rate_table, key); :ok
        _, :ok -> :ok
      end,
      :ok,
      @rate_table
    )
  end

  defp prune_dedup(token_hash) do
    entries =
      :ets.foldl(
        fn
          {{^token_hash, _client_msg_id} = key, inserted_at}, acc -> [{key, inserted_at} | acc]
          {_key, _inserted_at}, acc -> acc
        end,
        [],
        @dedup_table
      )

    entries
    |> Enum.sort_by(fn {_key, inserted_at} -> inserted_at end, :desc)
    |> Enum.drop(100)
    |> Enum.each(fn {key, _inserted_at} -> :ets.delete(@dedup_table, key) end)
  end

  defp ensure_table(name) do
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
  rescue
    ArgumentError -> name
  end
end
