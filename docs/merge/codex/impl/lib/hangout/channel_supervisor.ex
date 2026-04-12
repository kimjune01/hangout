defmodule Hangout.ChannelSupervisor do
  @moduledoc "Dynamic supervisor API for channel processes."

  def start_channel(name, opts \\ []) do
    Hangout.ChannelRegistry.ensure_started(name, opts)
  end
end
