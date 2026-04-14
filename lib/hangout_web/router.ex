defmodule HangoutWeb.Router do
  use HangoutWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HangoutWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :agent_api do
    plug :accepts, ["json"]
  end

  pipeline :agent_sse do
  end

  scope "/:room/agent", HangoutWeb do
    pipe_through :agent_sse
    get "/:token/events", AgentController, :events
  end

  scope "/:room/agent", HangoutWeb do
    pipe_through :agent_api
    post "/:token/messages", AgentController, :messages
    post "/:token/drafts", AgentController, :drafts
  end

  scope "/", HangoutWeb do
    pipe_through :browser

    live "/", RoomLive, :show
    live "/:slug", RoomLive, :show
  end
end
