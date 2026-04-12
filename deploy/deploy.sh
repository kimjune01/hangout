#!/bin/bash
# deploy.sh — Deploy Hangout to Lightsail instance
# Run on the server: cd ~/hangout && bash deploy/deploy.sh
#
# Lessons learned:
# - Lightsail nano (512MB) OOMs during mix compile. Add 1GB swap first.
# - Must stop hangout service before cp — BEAM binaries are "Text file busy" while running.
# - Caddy needs Let's Encrypt in CAA records. Check: dig CAA yourdomain.com
# - server: true must be set in prod.exs or Phoenix won't bind HTTP.
# - Don't use cache_static_manifest unless you run mix phx.digest (we don't use asset pipeline).
# - Erlang from rabbitmq PPA is faster than building from source via asdf/kerl.
# - Secret key base goes in systemd unit Environment= line, not a dotenv file.
set -e

echo "==> Pulling latest..."
git pull

echo "==> Fetching deps..."
export MIX_ENV=prod
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod

echo "==> Compiling..."
mix compile

echo "==> Building release..."
mix release --overwrite

echo "==> Stopping service..."
sudo systemctl stop hangout || true
sleep 2

echo "==> Installing release..."
sudo cp -r _build/prod/rel/hangout/* /opt/hangout/
sudo chown -R hangout:hangout /opt/hangout

echo "==> Starting service..."
sudo systemctl start hangout

sleep 3
echo "==> Status:"
sudo systemctl is-active hangout
curl -s -o /dev/null -w "HTTP: %{http_code}\n" http://localhost:4000/
echo "==> Done."
