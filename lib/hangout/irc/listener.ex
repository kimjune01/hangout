defmodule Hangout.IRC.Listener do
  @moduledoc """
  Ranch TCP acceptor for IRC connections.

  Configurable port via `:hangout, :irc_port` (default 6667).
  Returns a child_spec suitable for a supervision tree.
  """

  require Logger

  def child_spec(_opts) do
    port = Application.get_env(:hangout, :irc_port, 6667)

    :ranch.child_spec(
      __MODULE__,
      :ranch_tcp,
      %{
        socket_opts: [port: port],
        num_acceptors: 10,
        max_connections: 1000
      },
      Hangout.IRC.Connection,
      []
    )
  end
end
