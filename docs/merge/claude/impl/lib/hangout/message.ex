defmodule Hangout.Message do
  @moduledoc """
  In-memory message struct. Never persisted.
  """

  @enforce_keys [:id, :at, :from, :target, :kind, :body]
  defstruct [:id, :at, :from, :target, :kind, :body]

  @type kind :: :privmsg | :notice | :action | :system

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          at: DateTime.t(),
          from: String.t(),
          target: String.t(),
          kind: kind(),
          body: String.t()
        }

  @doc """
  Build a new message with a monotonic id.
  """
  def new(from, target, kind, body) do
    %__MODULE__{
      id: System.unique_integer([:monotonic, :positive]),
      at: DateTime.utc_now(),
      from: from,
      target: target,
      kind: kind,
      body: body
    }
  end
end
