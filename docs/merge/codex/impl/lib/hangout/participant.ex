defmodule Hangout.Participant do
  @moduledoc "A participant in one ephemeral channel."
  @enforce_keys [:nick, :transport, :pid]
  defstruct nick: nil,
            user: nil,
            realname: nil,
            public_key: nil,
            transport: :liveview,
            bot?: false,
            pid: nil,
            joined_at: nil,
            last_seen_at: nil,
            modes: MapSet.new(),
            rate_limit_state: %{}

  def human?(%__MODULE__{bot?: bot?}), do: !bot?
end
