import Config

config :hangout, HangoutWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev-secret-key-base-", 4)

config :logger, level: :info
