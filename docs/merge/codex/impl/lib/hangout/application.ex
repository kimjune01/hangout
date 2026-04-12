defmodule Hangout.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hangout.PubSub},
      {Registry, keys: :unique, name: Hangout.ChannelRegistry},
      {Registry, keys: :unique, name: Hangout.NickRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Hangout.ChannelSupervisor},
      Hangout.IRC.Listener,
      HangoutWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hangout.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HangoutWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
