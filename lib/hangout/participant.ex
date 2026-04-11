defmodule Hangout.Participant do
  @moduledoc """
  In-memory participant struct. Exists only while the channel lives.
  """

  @enforce_keys [:nick, :transport, :pid]
  defstruct [
    :nick,
    :user,
    :realname,
    :public_key,
    :transport,
    :pid,
    :joined_at,
    :last_seen_at,
    bot?: false,
    modes: MapSet.new(),
    rate_limit_state: nil
  ]

  @type t :: %__MODULE__{
          nick: String.t(),
          user: String.t() | nil,
          realname: String.t() | nil,
          public_key: String.t() | nil,
          transport: :liveview | :irc,
          bot?: boolean(),
          pid: pid(),
          joined_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          modes: MapSet.t(),
          rate_limit_state: Hangout.RateLimiter.t() | nil
        }

  def new(nick, transport, pid, opts \\ []) do
    %__MODULE__{
      nick: nick,
      user: Keyword.get(opts, :user, nick),
      realname: Keyword.get(opts, :realname, nick),
      public_key: Keyword.get(opts, :public_key),
      transport: transport,
      bot?: Keyword.get(opts, :bot?, false),
      pid: pid,
      joined_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      modes: Keyword.get(opts, :modes, MapSet.new()),
      rate_limit_state: Keyword.get(opts, :rate_limit_state) || Hangout.RateLimiter.new()
    }
  end

  def operator?(%__MODULE__{modes: modes}), do: MapSet.member?(modes, :o)
  def voiced?(%__MODULE__{modes: modes}), do: MapSet.member?(modes, :v)
  def human?(%__MODULE__{bot?: bot?}), do: !bot?
end
