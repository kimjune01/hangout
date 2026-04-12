defmodule Hangout.IPLimiter do
  @moduledoc """
  Per-IP concurrent connection counter using ETS.
  Limits the number of simultaneous IRC connections from a single IP.
  """

  use GenServer

  @table __MODULE__
  @max_per_ip Application.compile_env(:hangout, :max_connections_per_ip, 10)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @doc "Try to admit a connection from the given IP. Returns :ok or {:error, :too_many_connections}."
  def admit(ip) do
    count = :ets.update_counter(@table, ip, {2, 1}, {ip, 0})

    if count > @max_per_ip do
      :ets.update_counter(@table, ip, {2, -1})
      {:error, :too_many_connections}
    else
      :ok
    end
  end

  @doc "Release a connection slot for the given IP."
  def release(ip) do
    try do
      count = :ets.update_counter(@table, ip, {2, -1})
      if count <= 0, do: :ets.delete(@table, ip)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
