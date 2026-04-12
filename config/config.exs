import Config

config :hangout,
  irc_port: 6667,
  max_buffer_size: 100,
  max_nick_length: 16,
  max_channel_name_length: 48,
  default_ttl: nil,
  max_ttl: 86_400,
  capability_token_bytes: 16,
  max_members_per_channel: 200,
  max_channels: 1000,
  reconnect_grace_seconds: 60,
  message_body_max_bytes: 400,
  irc_line_max_bytes: 512,
  message_rate_limit: {5, 10_000},
  message_burst: 10,
  enable_voice: true,
  max_voice_participants: 5

config :hangout, HangoutWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HangoutWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Hangout.PubSub,
  live_view: [signing_salt: "hangout_lv_salt"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.21.5",
  hangout: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind, :version, "4.1.12"

import_config "#{config_env()}.exs"
