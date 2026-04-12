defmodule Hangout.ChannelRegistry do
  @moduledoc """
  Registry wrapper for mapping canonical channel names to ChannelServer PIDs.
  """

  @registry __MODULE__
  @channel_re ~r/^#[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$/

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Returns the via tuple for a channel name.
  """
  def via(channel_name) do
    {:via, Registry, {@registry, canonical!(channel_name)}}
  end

  @doc """
  Look up the PID of a channel by name. Returns `{:ok, pid}` or `:error`.
  """
  def lookup(channel_name) do
    case canonical(channel_name) do
      {:ok, canon} ->
        case Registry.lookup(@registry, canon) do
          [{pid, _value}] when is_pid(pid) -> {:ok, pid}
          [] -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  Returns true if a channel is registered.
  """
  def exists?(name), do: match?({:ok, _}, lookup(name))

  @doc """
  Returns a list of all registered channel names.
  """
  def list_channels do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Find or create a channel. Returns `{:ok, pid}`.
  """
  def ensure_started(name, opts \\ []) do
    name = canonical!(name)

    case lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        if Registry.count(@registry) >= Application.get_env(:hangout, :max_channels, 1000) do
          {:error, :too_many_channels}
        else
          case DynamicSupervisor.start_child(
                 Hangout.ChannelSupervisor,
                 {Hangout.ChannelServer, Keyword.put(opts, :name, name)}
               ) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, pid}}}} -> {:ok, pid}
            other -> other
          end
        end
    end
  end

  @doc """
  Validates a channel name against IRC conventions.
  """
  def valid?(name) when is_binary(name) do
    case canonical(name) do
      {:ok, canon} -> Regex.match?(@channel_re, canon)
      :error -> false
    end
  end

  def valid?(_), do: false

  @doc """
  Canonicalize a channel name (ensure it starts with #).
  """
  def canonical(name) when is_binary(name) do
    case name do
      "#" <> _ -> {:ok, name}
      "<<" <> _ -> :error
      slug -> {:ok, "#" <> slug}
    end
  end

  def canonical(_), do: :error

  def canonical!("<<" <> _), do: raise(ArgumentError, "invalid channel name")
  def canonical!("#" <> _ = name), do: name
  def canonical!(slug) when is_binary(slug), do: canonical!("#" <> slug)

  @doc """
  Strip the leading # from a channel name.
  """
  def slug("#" <> slug), do: slug
  def slug(slug), do: slug
end
