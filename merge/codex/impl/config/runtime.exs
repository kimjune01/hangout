import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required in production"

  config :hangout, HangoutWeb.Endpoint,
    secret_key_base: secret_key_base,
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"]

  if port = System.get_env("IRC_PORT") do
    config :hangout, irc_port: String.to_integer(port)
  end
end
