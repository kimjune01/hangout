import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "hangout.site"
  port = String.to_integer(System.get_env("PORT") || "4000")
  irc_port = String.to_integer(System.get_env("IRC_PORT") || "6667")

  config :hangout, HangoutWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :hangout, irc_port: irc_port

  # Optional: single-room mode. Set DEFAULT_ROOM=june to skip the home page.
  if default_room = System.get_env("DEFAULT_ROOM") do
    config :hangout, default_room: default_room
  end
end
