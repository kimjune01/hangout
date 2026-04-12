defmodule Hangout.ChannelSupervisor do
  @moduledoc """
  DynamicSupervisor for ChannelServer processes.
  Channels are started lazily on first join and terminate when empty.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new ChannelServer. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def start_channel(channel_name, opts \\ []) do
    max_channels = Application.get_env(:hangout, :max_channels, 1000)
    current_count = length(Hangout.ChannelRegistry.list_channels())

    if current_count >= max_channels do
      {:error, :too_many_channels}
    else
      spec = {Hangout.ChannelServer, [{:channel_name, channel_name} | opts]}
      DynamicSupervisor.start_child(__MODULE__, spec)
    end
  end

  @doc """
  Find or create a channel. Returns `{:ok, pid}`.
  """
  def ensure_channel(channel_name, opts \\ []) do
    case Hangout.ChannelRegistry.lookup(channel_name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case start_channel(channel_name, opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
