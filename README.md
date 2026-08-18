# Mihomo Setup

This directory contains a standalone `mihomo` deployment with a locally hosted `yacd` Web UI.

## Paths

- Binary: `./mihomo`
- Active config: `./config.yaml`
- Raw subscription config: `./config.raw.yaml`
- Sanitized examples for Git backup: `./config.example.yaml`, `./config.raw.example.yaml`
- Public local overrides: `./mixin.yaml`
- Private local overrides: `./mixin.local.yaml` (copy from `./mixin.local.example.yaml`)
- Subscription examples for Git backup: `./.subscription_url.example`, `./subscriptions.example.json`
- UI files: `./public`
- Log file: `./mi.log`

The live subscription URLs, controller secret, and proxy credentials remain local-only and are not tracked in Git. Put the controller secret and other private overrides in `mixin.local.yaml`; it is merged after `mixin.yaml`. The example files keep the directory structure recoverable without publishing runtime secrets.

## Commands

- Start: `./start.sh`
- Stop: `./stop.sh`
- Restart: `./restart.sh`
- Status: `./status.sh`
- Rebuild merged config: `./merge-config.sh`
- Update subscription: `./update-subscription.sh '<your-subscription-url>'`

## Proxy Ports

- HTTP: `127.0.0.1:30419`
- SOCKS5: `127.0.0.1:30420`
- Mixed: `127.0.0.1:30421`

## Web UI

After startup, open `http://127.0.0.1:9090/ui` on the host itself.

For browser-based subscription changes, open `http://127.0.0.1:9090/ui/subscription.html`.

To access it from another machine on the same network, run `./status.sh` and use the `LAN UI` address it prints.

The current controller secret is stored in `config.yaml` and shown by `./status.sh`.

## User Service

If `systemd --user` is available, the service file lives at `~/.config/systemd/user/mihomo.service`.

Useful commands:

- `systemctl --user daemon-reload`
- `systemctl --user enable --now mihomo.service`
- `systemctl --user restart mihomo.service`
- `systemctl --user status mihomo.service`

The browser-based subscription manager runs as `mihomo-admin.service`.
