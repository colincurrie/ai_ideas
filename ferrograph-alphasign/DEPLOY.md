# Deploying to the Raspberry Pi

Two independent services, both running on the Pi that's physically wired
to the sign:

```
[Browser] --HTTPS, login+session--> [web_app :4567] --localhost HTTP--> [serial_api :4568] --RS232--> [Sign]
                                    (Tailscale-reachable)                 (127.0.0.1 only)
```

## 1. Prerequisites on the Pi

```
sudo apt update
sudo apt install ruby-full build-essential ruby-dev libudev-dev
```

`libudev-dev` (or `libudev1`/`libudev0` depending on your Raspberry Pi OS
version) is needed to build the `serialport` gem's native extension.

Clone this repo onto the Pi, then from `ferrograph-alphasign/`:

```
bundle install
```

## 2. Configuration

Both services read configuration from the environment. Generate the two
secrets you'll need:

```
# A session secret (64+ chars) for web_app
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'

# A bcrypt hash of your chosen login password
bin/hash_password
```

Create an environment file for each service (referenced by the systemd
units below) - `/etc/ferrograph/serial-api.env`:

```
SERIAL_DEVICE=/dev/ttyUSB0
SERIAL_BAUD=9600
# SERIAL_PARITY, SERIAL_DATA_BITS, SERIAL_STOP_BITS: leave at defaults
# (none/8/1) unless you know why you need something else - see
# docs/xdf-firmware-notes.md, XDF always requires 8N1.
SERIAL_API_BIND=127.0.0.1
SERIAL_API_PORT=4568
```

`/etc/ferrograph/web-app.env`:

```
WEB_APP_USERNAME=admin
WEB_APP_PASSWORD_HASH=<paste the bin/hash_password output here>
SESSION_SECRET=<paste the SecureRandom.hex(64) output here>
SERIAL_API_URL=http://127.0.0.1:4568
WEB_APP_ALLOWED_HOSTS=localhost,127.0.0.1,<your-device>.<your-tailnet>.ts.net
WEB_APP_SECURE_COOKIES=true
```

Restrict permissions on these (they contain secrets):

```
sudo mkdir -p /etc/ferrograph
sudo chmod 700 /etc/ferrograph
sudo chmod 600 /etc/ferrograph/*.env
```

## 3. systemd units

`/etc/systemd/system/ferrograph-serial-api.service`:

```ini
[Unit]
Description=Ferrograph serial-api (Alpha protocol device driver)
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/ferrograph-alphasign
EnvironmentFile=/etc/ferrograph/serial-api.env
ExecStart=/usr/bin/env bundle exec rackup serial_api/config.ru -o 127.0.0.1 -p 4568
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/ferrograph-web-app.service`:

```ini
[Unit]
Description=Ferrograph web-app (authenticated UI)
After=network.target ferrograph-serial-api.service
Requires=ferrograph-serial-api.service

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/ferrograph-alphasign
EnvironmentFile=/etc/ferrograph/web-app.env
ExecStart=/usr/bin/env bundle exec rackup web_app/config.ru -o 0.0.0.0 -p 4567
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Adjust `User=`/`WorkingDirectory=` to match your actual Pi user and clone
path. Then:

```
sudo systemctl daemon-reload
sudo systemctl enable --now ferrograph-serial-api ferrograph-web-app
sudo journalctl -u ferrograph-serial-api -u ferrograph-web-app -f  # watch logs
```

Note `web_app` binds `0.0.0.0` (reachable on the LAN too, not just via
Tailscale) - that's fine, since auth is enforced by the app itself and the
Pi likely isn't port-forwarded to the public internet; tighten to
`127.0.0.1` plus the Tailscale interface's address specifically if you'd
rather it not be reachable from the LAN at all.

## 4. Tailscale (remote access)

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Sign into the same Tailscale account on your phone/laptop. Find the Pi's
tailnet hostname:

```
tailscale status
```

Get a real HTTPS cert for that hostname (needed for secure session
cookies - `WEB_APP_SECURE_COOKIES=true` above assumes this):

```
sudo tailscale cert <device>.<your-tailnet>.ts.net
```

That gives you a cert/key pair; either point a small reverse proxy (Caddy
is the least fuss - a two-line Caddyfile will auto-load a `tailscale
cert`-issued pair given the right hostname) at `web_app`, or terminate TLS
in Puma directly by adding `-b
'ssl://0.0.0.0:443?key=...&cert=...'`-style options to the `ExecStart`
line. Either way, once that's in place you're reachable at
`https://<device>.<your-tailnet>.ts.net` from any device on your tailnet,
with no public exposure and no router configuration.

## 5. Smoke test

```
curl http://127.0.0.1:4568/status          # serial_api, from the Pi itself
curl -I https://<device>.<tailnet>.ts.net   # web_app, from any tailnet device
```

Then log in through the browser and send a `--dry-run`-style Preview
before your first real Send, to confirm the byte stream looks right before
it hits the sign.
