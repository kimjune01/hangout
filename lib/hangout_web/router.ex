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

  scope "/", HangoutWeb do
    pipe_through :browser

    live "/", RoomLive, :show
    live "/:slug", RoomLive, :show
  end
end
