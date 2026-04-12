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

end
