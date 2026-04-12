defmodule Hangout.NickRegistry do
  @moduledoc """
  Global nick uniqueness. Maps active nicks to connection/session PIDs.
  """

  @registry __MODULE__
  alias Hangout.IRC.Parser

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Validates a nick against IRC conventions (max 16 chars).
  """
  def valid?(nick) when is_binary(nick), do: Parser.valid_nick?(nick)
  def valid?(_), do: false

  @doc """
  Normalize a nick: trim and cap at 16 chars.
  """
  def normalize(nick) when is_binary(nick), do: String.trim(nick) |> String.slice(0, 16)
  def normalize(_), do: ""

  @doc """
  Case-insensitive registry key.
  """
  def key(nick), do: String.downcase(normalize(nick))

  @doc """
  Try to register a nick for the calling process. Returns `:ok` or `{:error, reason}`.
  """
  def register(nick, meta \\ %{}) do
    nick = normalize(nick)

    cond do
      nick == "" -> {:error, :no_nick}
      !valid?(nick) -> {:error, :invalid_nick}
      true -> do_register(nick, meta)
    end
  end

  defp do_register(nick, meta) do
    case Registry.register(@registry, key(nick), Map.put(meta, :nick, nick)) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :nick_in_use}
    end
  end

  @doc """
  Unregister a nick.
  """
  def unregister(nil), do: :ok

  def unregister(nick) do
    Registry.unregister(@registry, key(normalize(nick)))
    :ok
  end

  @doc """
  Look up the PID and metadata owning a nick.
  """
  def lookup(nick) do
    case Registry.lookup(@registry, key(nick)) do
      [{pid, meta}] -> {:ok, pid, meta}
      [] -> :error
    end
  end

  @doc """
  Look up just the PID owning a nick.
  """
  def pid(nick) do
    case lookup(nick) do
      {:ok, pid, _} -> {:ok, pid}
      :error -> :error
    end
  end

  @doc """
  Change a nick atomically: register new, unregister old.
  Returns `:ok` or `{:error, reason}`.
  """
  def change(old_nick, new_nick, meta \\ %{}) do
    old_nick = normalize(old_nick)

    with :ok <- register(new_nick, meta) do
      if old_nick != "", do: Registry.unregister(@registry, key(old_nick))
      :ok
    end
  end

  @doc """
  Check if a nick is currently registered.
  """
  def registered?(nick) do
    case lookup(nick) do
      {:ok, _, _} -> true
      :error -> false
    end
  end
end
