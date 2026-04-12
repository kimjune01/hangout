defmodule HangoutWeb do
  @moduledoc false

  def static_paths, do: ~w(assets)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
