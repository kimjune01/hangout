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
  def start_channel(name, opts \\ []) do
    Hangout.ChannelRegistry.ensure_started(name, opts)
  end

  @doc """
  Find or create a channel. Returns `{:ok, pid}`.
  """
  def ensure_channel(channel_name, opts \\ []) do
    Hangout.ChannelRegistry.ensure_started(channel_name, opts)
  end
end
