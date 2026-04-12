# Hangout Deploy/Infrastructure Review

Scope reviewed:

- `deploy/setup.sh`
- `deploy/deploy.sh`
- `deploy/Caddyfile`
- `deploy/hangout.service`
- `infra/main.go`
- `config/prod.exs`
- `config/runtime.exs`

## Findings

### 1. High - IRC TLS port is open, but the service listens on plain IRC 6667

What's wrong:

- `infra/main.go:72-95` opens public TCP `6697` and comments it as "IRC TLS".
- `deploy/hangout.service:18` sets `IRC_PORT=6667`.
- `config/runtime.exs:13,23` passes that value directly to the application.
- `deploy/Caddyfile:1-3` only proxies HTTPS traffic to Phoenix and does not proxy raw IRC/TLS.
- The app will listen on local port `6667`, while the Lightsail firewall exposes `6697`. Production IRC clients using `ircs://chat.june.kim:6697` will fail. If port `6667` is later opened to fix this quickly, IRC credentials/messages go over cleartext.

How to fix:

- Decide one production IRC path and make the firewall, service, and proxy match.
- Preferred: terminate TLS for IRC on `6697` with Caddy's layer4 plugin, stunnel, nginx stream, or native TLS support in the Elixir listener, then forward to local `127.0.0.1:6667`.
- If native TLS is not implemented yet, do not advertise or open `6697`; document plain IRC as intentionally disabled in production until TLS is ready.
- Add a deploy verification check that connects to the expected public IRC endpoint, not only `localhost:4000`.

### 2. High - Phoenix binds to all IPv4 and IPv6 interfaces; backend port may become publicly reachable

What's wrong:

- `config/runtime.exs:17-19` binds Phoenix HTTP to `{0, 0, 0, 0, 0, 0, 0, 0}`.
- The intended path is Caddy on `80/443` forwarding to `localhost:4000`, but the app itself accepts traffic on every interface.
- Lightsail currently does not expose `4000` in `infra/main.go`, but any future firewall change, host firewall mistake, or local misconfiguration would bypass Caddy, TLS, request logging, and any future Caddy-level controls.

How to fix:

- Bind the Phoenix endpoint to loopback only:

  ```elixir
  http: [
    ip: {127, 0, 0, 1},
    port: port
  ]
  ```

- If IPv6 loopback is required, configure it explicitly and verify Caddy can reach it.
- Add a host firewall rule that denies all inbound traffic except `22`, `80`, `443`, and the chosen IRC TLS port.

### 3. High - Secret is stored directly in the systemd unit and is likely world-readable to privileged/support users

What's wrong:

- `deploy/setup.sh:46-47` generates `SECRET_KEY_BASE` and writes it into `/etc/systemd/system/hangout.service`.
- `deploy/hangout.service:17` stores the secret in an `Environment=` line.
- Unit files are configuration, not secret storage. The secret can show up in `systemctl cat hangout`, backups, support bundles, file copies, and accidental commits if the installed unit is copied back.

How to fix:

- Move secrets to a root-owned environment file, for example `/etc/hangout/hangout.env`, mode `0600`.
- Use `EnvironmentFile=/etc/hangout/hangout.env` in the unit.
- Generate the file in `setup.sh` with `sudo install -d -m 0700 /etc/hangout` and `sudo install -m 0600`.
- Consider using Pulumi config secrets or AWS SSM Parameter Store if the deployment grows beyond one instance.

### 4. High - Deploy can leave the service down after a failed or interrupted release copy

What's wrong:

- `deploy/deploy.sh:30-39` stops the service, sleeps, copies files over the live release directory, then starts the service.
- If `cp`, `chown`, disk space, SSH session, or the shell exits between stop and start, Hangout stays down.
- Copying directly into `/opt/hangout` can also produce a partially updated release if the copy fails midway.

How to fix:

- Build into a versioned release directory, validate it, then atomically switch a symlink such as `/opt/hangout/current`.
- Use `systemctl restart hangout` after the symlink switch instead of a long stop window.
- Add a shell `trap` that attempts to restart the previous known-good release on failure.
- Keep at least one previous release for rollback and prune older releases.

### 5. High - Infrastructure bootstrap conflicts with the maintained setup script

What's wrong:

- `deploy/setup.sh:30-35` installs Erlang/Elixir from the RabbitMQ PPA and says asdf is avoided because cloud-init builds are unreliable.
- `infra/main.go:32-42` still installs Erlang/Elixir through asdf in Lightsail user data.
- `infra/main.go` also does not install the Caddyfile, systemd unit, swap, or generated secret from `deploy/setup.sh`.
- A newly recreated instance from Pulumi will not match the documented/manual server state and may fail at exactly the point recovery is needed.

How to fix:

- Make Pulumi user data call the same setup path or render equivalent commands from one source of truth.
- Prefer a minimal cloud-init bootstrap that installs prerequisites and then runs a pinned setup artifact.
- Remove the stale asdf path from `infra/main.go` if the RabbitMQ PPA path is the supported production path.
- Add a fresh-instance test/runbook: create instance, run deploy, verify HTTPS and IRC endpoints.

### 6. Medium - systemd service lacks common process hardening

What's wrong:

- `deploy/hangout.service:5-18` runs as a dedicated user, which is good, but has no additional sandboxing.
- The service can write broadly anywhere the `hangout` user can write, read large parts of the filesystem, gain new privileges through child processes if a vulnerability allows it, and access device/kernel interfaces unnecessary for a chat app.

How to fix:

- Add hardening options appropriate for a Phoenix release, test them, and relax only what breaks:

  ```ini
  NoNewPrivileges=true
  PrivateTmp=true
  ProtectSystem=strict
  ProtectHome=true
  ReadWritePaths=/opt/hangout
  CapabilityBoundingSet=
  RestrictSUIDSGID=true
  LockPersonality=true
  ProtectKernelTunables=true
  ProtectKernelModules=true
  ProtectControlGroups=true
  SystemCallArchitectures=native
  ```

- If the release needs writable temp/cache directories, create explicit `StateDirectory=hangout`, `CacheDirectory=hangout`, or additional `ReadWritePaths=`.

### 7. Medium - Restart policy has no rate-limit tuning or watchdog/health semantics

What's wrong:

- `deploy/hangout.service:12-13` uses `Restart=on-failure` with `RestartSec=5`.
- There is no `StartLimitBurst`, `StartLimitIntervalSec`, readiness notification, or watchdog.
- A crash loop may burn CPU, fill logs, or get throttled by systemd defaults in a way that is not obvious during an incident.

How to fix:

- Add explicit rate limits, for example:

  ```ini
  Restart=on-failure
  RestartSec=5
  StartLimitIntervalSec=300
  StartLimitBurst=5
  ```

- Add a lightweight `/healthz` endpoint and set up external uptime checks against `https://chat.june.kim/healthz`.
- For deeper supervision, use `Type=notify` only if the release can notify systemd when ready; otherwise keep `Type=exec` but rely on external health checks.

### 8. Medium - Deploy health check is too weak and can report success for the wrong thing

What's wrong:

- `deploy/deploy.sh:41-44` only checks that systemd says the service is active and that `http://localhost:4000/` returns some HTTP status.
- It does not fail on bad HTTP status because `curl` lacks `--fail`.
- It does not verify public HTTPS, WebSocket/LiveView behavior, Caddy, certificate issuance, or IRC.

How to fix:

- Use `curl --fail --show-error --silent http://127.0.0.1:4000/healthz`.
- Also verify `https://chat.june.kim/healthz` after Caddy is started.
- Add a simple IRC smoke check for the chosen production port.
- Make the script exit non-zero if any post-deploy check fails.

### 9. Medium - No explicit host firewall or SSH hardening in setup

What's wrong:

- `infra/main.go:76-80` exposes SSH `22` publicly with no source CIDR restriction.
- `deploy/setup.sh` does not configure `ufw`, `sshd_config`, fail2ban, password login policy, root login policy, or unattended security updates.
- Lightsail's firewall is useful, but the host should still have a defensive local policy.

How to fix:

- Restrict SSH source CIDRs in Lightsail if your client IP range is stable.
- Configure host firewall defaults:

  ```bash
  sudo ufw default deny incoming
  sudo ufw allow 22/tcp
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw allow 6697/tcp # only if IRC TLS is actually configured
  sudo ufw --force enable
  ```

- Ensure `PasswordAuthentication no`, `PermitRootLogin no`, and key-only auth are set.
- Install and configure `fail2ban` or equivalent SSH rate limiting.
- Enable `unattended-upgrades` for security patches.

### 10. Medium - No backup/snapshot strategy for instance recovery

What's wrong:

- `infra/main.go` provisions a static IP and instance but no snapshot schedule.
- The app is ephemeral, but the server state is not: Caddy cert/account data, generated secret, installed unit, SSH/user state, and deployment directory are all operationally significant.
- Rebuilding from Pulumi currently does not reproduce the manual setup, so losing the instance means a manual recovery under pressure.

How to fix:

- Add Lightsail automatic snapshots or document a deliberate "rebuild from scratch" runbook that is tested.
- Back up or reproducibly generate `/etc/hangout/hangout.env`, `/etc/caddy`, and deployment state.
- Prefer making the instance disposable by fixing the bootstrap drift in finding 5.

### 11. Medium - No log retention/access log plan

What's wrong:

- `config/prod.exs:6` sets app logs to `:info`, which is fine, but there is no explicit journald retention policy, Caddy access log config, or log shipping.
- `deploy/Caddyfile:1-3` does not enable access logs.
- During an incident, there may be no request-level history for HTTP traffic, and on a tiny Lightsail disk, unbounded local logs can consume space.

How to fix:

- Configure journald limits such as `SystemMaxUse`, `RuntimeMaxUse`, and retention appropriate for the instance size.
- Add Caddy access logging with rotation, or ship logs externally.
- Add basic log review commands to the runbook:

  ```bash
  journalctl -u hangout --since -1h
  journalctl -u caddy --since -1h
  ```

### 12. Medium - Disk-space risk on the smallest Lightsail instance

What's wrong:

- `deploy/setup.sh:13-19` adds 1GB swap.
- `deploy/deploy.sh:20-28` fetches dependencies, compiles, and builds releases on the production host.
- `deploy/deploy.sh:35-36` copies a full release into `/opt/hangout` but never cleans old build artifacts, Hex/Rebar caches, git objects, journal logs, or release leftovers.
- On the nano instance, disk pressure can break deploys and leave the service stopped because of finding 4.

How to fix:

- Add preflight checks for available disk and memory before stopping the service.
- Prune old releases and build artifacts after successful deploys.
- Consider building releases off-box and copying only the artifact to Lightsail.
- Add a disk usage alert, even a simple cron/script that reports when `/` exceeds 80%.

### 13. Low - Caddy is enabled but not started by setup

What's wrong:

- `deploy/setup.sh:49-53` enables `hangout` and `caddy` but only tells the operator to start Caddy after deploy.
- If the operator misses that final manual step, the app may be running locally but unavailable over HTTPS.

How to fix:

- Start or reload Caddy from the script after installing the Caddyfile:

  ```bash
  sudo systemctl enable --now caddy
  sudo caddy validate --config /etc/caddy/Caddyfile
  sudo systemctl reload caddy
  ```

- Keep the app start separate if desired, but make proxy activation deterministic.

### 14. Low - `setup.sh` is not fully idempotent

What's wrong:

- `deploy/setup.sh:19` appends the swapfile entry to `/etc/fstab` whenever `/swapfile` does not exist, without checking for an existing stale entry.
- `deploy/setup.sh:25-26` overwrites apt repository files without validation.
- `deploy/setup.sh:47` rewrites the service file and generates a new secret each time setup is rerun.

How to fix:

- Check for existing fstab entries before appending.
- Validate apt key/repo installation before replacing.
- Generate the secret only if the environment file does not already exist, or require an explicit `ROTATE_SECRET=1`.

### 15. Low - Production host fallback is wrong for this deployment

What's wrong:

- `config/runtime.exs:11` defaults `PHX_HOST` to `hangout.site`.
- `deploy/hangout.service:15` sets the correct host `chat.june.kim`, but if the environment variable is omitted during a manual start or future service refactor, generated URLs will point at the wrong domain.

How to fix:

- Change the production fallback to `chat.june.kim`, or remove the fallback and fail fast when `PHX_HOST` is missing.
- For production, failing fast is cleaner than silently generating wrong URLs.

### 16. Low - Supply-chain inputs are not pinned or verified beyond package-manager defaults

What's wrong:

- `deploy/setup.sh:25-31` downloads repository metadata/key material over the network at setup time.
- `infra/main.go:34,37-40` clones asdf and installs language versions through network plugins.
- This is common for small deployments, but it makes fresh instance recovery dependent on mutable upstream install paths.

How to fix:

- Prefer Ubuntu/PPA packages from pinned repositories for the supported path.
- Remove the stale asdf bootstrap from Pulumi.
- For stronger reproducibility, build releases in CI with pinned toolchains and deploy release artifacts to the server.

## Highest-priority fixes

1. Fix the IRC production path: either real TLS on `6697` or no exposed/advertised IRC TLS port.
2. Bind Phoenix to loopback and add a host firewall.
3. Move `SECRET_KEY_BASE` out of the systemd unit into a root-only env file.
4. Make deploys atomic with rollback/restart traps.
5. Unify Pulumi bootstrap with `deploy/setup.sh` so a new instance is recoverable.
