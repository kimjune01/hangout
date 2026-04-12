defmodule Hangout.ChannelRegistry do
  @moduledoc """
  Registry wrapper for mapping canonical channel names to ChannelServer PIDs.
  """

  @registry __MODULE__

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Returns the via tuple for a channel name, e.g. `"#calc-study"`.
  """
  def via(channel_name) do
    {:via, Registry, {@registry, channel_name}}
  end

  @doc """
  Look up the PID of a channel by name. Returns `{:ok, pid}` or `:error`.
  """
  def lookup(channel_name) do
    case Registry.lookup(@registry, channel_name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns a list of all registered channel names.
  """
  def list_channels do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
