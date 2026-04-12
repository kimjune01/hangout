defmodule Hangout.Message do
  @moduledoc "In-memory room message. Never persisted."
  @enforce_keys [:id, :at, :from, :target, :kind, :body]
  defstruct [:id, :at, :from, :target, :kind, :body]
end
