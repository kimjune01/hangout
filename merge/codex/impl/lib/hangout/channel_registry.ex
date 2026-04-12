defmodule Hangout.ChannelRegistry do
  @moduledoc "Registry helpers for canonical IRC channel names."

  @name __MODULE__
  @channel_re ~r/^#[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$/

  def via(name), do: {:via, Registry, {@name, canonical!(name)}}

  def lookup(name) do
    case Registry.lookup(@name, canonical!(name)) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> :error
    end
  end

  def exists?(name), do: match?({:ok, _}, lookup(name))

  def ensure_started(name, opts \\ []) do
    name = canonical!(name)

    case lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        if Registry.count(@name) >= Application.get_env(:hangout, :max_channels, 1000) do
          {:error, :too_many_channels}
        else
          case DynamicSupervisor.start_child(Hangout.ChannelSupervisor, {Hangout.ChannelServer, Keyword.put(opts, :name, name)}) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, pid}}}} -> {:ok, pid}
            other -> other
          end
        end
    end
  end

  def canonical!("<<" <> _), do: raise(ArgumentError, "invalid channel name")
  def canonical!("#" <> _ = name), do: name
  def canonical!(slug) when is_binary(slug), do: canonical!("#" <> slug)

  def valid?(name) when is_binary(name), do: Regex.match?(@channel_re, canonical!(name))
  def valid?(_), do: false

  def slug("#" <> slug), do: slug
  def slug(slug), do: slug
end
