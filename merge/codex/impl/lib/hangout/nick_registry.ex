defmodule Hangout.NickRegistry do
  @moduledoc "Global IRC nick registry."

  @name __MODULE__
  @nick_re ~r/^[A-Za-z][A-Za-z0-9_\-\[\]\{\}\\\|\^` ]{0,15}$/

  def valid?(nick) when is_binary(nick), do: Regex.match?(@nick_re, nick)
  def valid?(_), do: false

  def register(nick, meta \\ %{}) do
    nick = normalize(nick)

    cond do
      nick == "" -> {:error, :no_nick}
      !valid?(nick) -> {:error, :invalid_nick}
      true -> do_register(nick, meta)
    end
  end

  def change(old, new, meta \\ %{}) do
    old = normalize(old)

    with :ok <- register(new, meta) do
      if old != "", do: Registry.unregister(@name, key(old))
      :ok
    end
  end

  def unregister(nil), do: :ok

  def unregister(nick) do
    Registry.unregister(@name, key(normalize(nick)))
    :ok
  end

  def lookup(nick) do
    case Registry.lookup(@name, key(nick)) do
      [{pid, meta}] -> {:ok, pid, meta}
      [] -> :error
    end
  end

  def pid(nick) do
    case lookup(nick) do
      {:ok, pid, _} -> {:ok, pid}
      :error -> :error
    end
  end

  defp do_register(nick, meta) do
    case Registry.register(@name, key(nick), Map.put(meta, :nick, nick)) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :in_use}
    end
  end

  def key(nick), do: String.downcase(normalize(nick))
  def normalize(nick) when is_binary(nick), do: String.trim(nick) |> String.slice(0, 16)
  def normalize(_), do: ""
end
