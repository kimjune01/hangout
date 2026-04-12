#!/bin/bash
# setup.sh — One-time server setup for Hangout on Ubuntu 22.04 (Lightsail)
# Run as ubuntu user: bash deploy/setup.sh
#
# Lessons learned:
# - asdf + kerl fails in cloud-init (DNS issues, slow builds). Use apt packages.
# - rabbitmq PPA has up-to-date Erlang 27 + Elixir 1.17 for Ubuntu 22.04.
# - 512MB nano needs swap or mix compile gets OOM-killed.
# - Caddy auto-provisions TLS via Let's Encrypt. Just set DNS + CAA first.
# - CAA records must include "letsencrypt.org" if you had amazon.com only.
set -e

echo "==> Adding swap (1GB)..."
if [ ! -f /swapfile ]; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

echo "==> Installing Caddy..."
sudo apt-get update -y
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor | sudo tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg > /dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update -y
sudo apt-get install -y caddy git build-essential

echo "==> Installing Erlang + Elixir from rabbitmq PPA..."
sudo add-apt-repository -y ppa:rabbitmq/rabbitmq-erlang
sudo apt-get update -y
sudo apt-get install -y erlang-base erlang-dev erlang-parsetools erlang-xmerl \
  erlang-tools erlang-ssl erlang-crypto erlang-inets erlang-mnesia \
  erlang-runtime-tools erlang-public-key erlang-syntax-tools elixir

echo "==> Creating hangout user..."
sudo useradd -m -s /bin/bash hangout 2>/dev/null || true
sudo mkdir -p /opt/hangout
sudo chown hangout:hangout /opt/hangout

echo "==> Installing Caddyfile..."
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile

echo "==> Installing systemd service..."
SECRET=$(openssl rand -base64 48 | tr -d '\n')
sed "s|SECRET_KEY_BASE=GENERATE_ME|SECRET_KEY_BASE=$SECRET|" deploy/hangout.service | sudo tee /etc/systemd/system/hangout.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable hangout caddy

echo "==> Setup complete. Run: bash deploy/deploy.sh"
echo "==> Then: sudo systemctl start caddy"
