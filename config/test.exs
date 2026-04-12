import Config

config :hangout, HangoutWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test", 16),
  server: false

config :hangout,
  irc_port: 16667

config :logger, level: :warning
