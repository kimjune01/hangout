defmodule Hangout.IRC.Listener do
  @moduledoc "Ranch TCP acceptor for IRC clients."
  use GenServer

  @ref :hangout_irc

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    port = Application.get_env(:hangout, :irc_port, 6667)
    transport_opts = %{socket_opts: [port: port], num_acceptors: 20}

    case :ranch.start_listener(@ref, :ranch_tcp, transport_opts, Hangout.IRC.Connection, []) do
      {:ok, _pid} -> {:ok, %{port: port}}
      {:error, {:already_started, _pid}} -> {:ok, %{port: port}}
      {:error, reason} -> {:stop, reason}
    end
  end
end
