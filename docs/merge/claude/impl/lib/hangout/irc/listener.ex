defmodule Hangout.IRC.Listener do
  @moduledoc """
  Ranch TCP acceptor for IRC connections on port 6667.
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
