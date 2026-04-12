defmodule Hangout.NickRegistry do
  @moduledoc """
  Global nick uniqueness. Maps active nicks to connection/session PIDs.
  """

  @registry __MODULE__

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Try to register a nick for the given pid. Returns `:ok` or `{:error, :nick_in_use}`.
  """
  def register(nick, pid \\ self()) do
    case Registry.register(@registry, nick, pid) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :nick_in_use}
    end
  end

  @doc """
  Unregister a nick.
  """
  def unregister(nick) do
    Registry.unregister(@registry, nick)
  end

  @doc """
  Look up the PID owning a nick.
  """
  def lookup(nick) do
    case Registry.lookup(@registry, nick) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Change a nick atomically: unregister old, register new.
  Returns `:ok` or `{:error, :nick_in_use}`.
  """
  def change(old_nick, new_nick, pid \\ self()) do
    case register(new_nick, pid) do
      :ok ->
        unregister(old_nick)
        :ok

      {:error, :nick_in_use} ->
        {:error, :nick_in_use}
    end
  end

  @doc """
  Check if a nick is currently registered.
  """
  def registered?(nick) do
    case lookup(nick) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
