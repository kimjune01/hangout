#!/bin/bash
# Deploy Hangout to Lightsail instance.
# Run from repo root on the server: bash deploy/deploy.sh
set -e

echo "==> Fetching deps..."
export MIX_ENV=prod
. /opt/asdf/asdf.sh
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod

echo "==> Building release..."
mix release --overwrite

echo "==> Installing release..."
sudo cp -r _build/prod/rel/hangout/* /opt/hangout/
sudo chown -R hangout:hangout /opt/hangout

echo "==> Restarting service..."
sudo systemctl restart hangout

echo "==> Done. Status:"
sudo systemctl status hangout --no-pager
