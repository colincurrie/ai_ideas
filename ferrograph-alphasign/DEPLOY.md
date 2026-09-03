# Deploying to the Raspberry Pi

Two independent services, both running on the Pi that's physically wired
to the sign:

```
[Browser] --HTTPS, login+session--> [web_app :4567] --localhost HTTP--> [serial_api :4568] --RS232--> [Sign]
                                    (Tailscale-reachable)                 (127.0.0.1 only)
```

## 0. Flashing a fresh card

Do this from your laptop with the spare card; the running Pi is untouched
until you swap them, so nothing is lost if you change your mind.

**First, check which Pi you have** - it decides which image. On the current
Pi:

```
cat /proc/device-tree/model
```

- Pi 2 / 3 / 4 / 5 / Zero 2 W: 64-bit Raspberry Pi OS.
- Pi 1 / Zero / Zero W: these are ARMv6 and the 64-bit build won't boot -
  take the 32-bit image.

**Anything worth rescuing off the old card?** Probably not - the code comes
from git and the secrets are regenerated below - but if you already made a
`.env`, copy it somewhere now. Same for any config belonging to whatever
else the Pi was doing.

**Flash it** with [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

1. Choose the OS. **Raspberry Pi OS Lite** is the right fit here: this is an
   appliance driving a sign, and you'll reach it over SSH and the web app.
   Take the full desktop version instead if you want to keep using VNC on
   it directly.
2. Before writing, open the settings (the gear icon, or "Edit Settings" when
   it offers to customise). Set the hostname, username and password, enable
   SSH, and add your WiFi if it isn't on Ethernet. **Don't skip this** - it
   is the difference between the Pi appearing on the network by itself and
   an evening with a keyboard and monitor attached.
3. Write to the spare card.

Swap the cards, power up, and you should be able to reach it:

```
ssh <username>@<hostname>.local
```

Then carry on below.

## 1. Prerequisites on the Pi

**This needs Ruby 3.0 or newer** (puma and dotenv both require it), which
in practice means a Raspberry Pi OS of Bullseye vintage or later. Check
first:

```
ruby -v
cat /etc/os-release
```

Bookworm ships Ruby 3.1 and needs nothing special. If you're on something
older, read "If the Pi is on an old OS" below before going further - it
will save you an afternoon.

```
sudo apt update
sudo apt install ruby-full build-essential ruby-dev libudev-dev
```

`libudev-dev` (or `libudev1`/`libudev0` depending on your Raspberry Pi OS
version) is needed to build the `serialport` gem's native extension.

### If the Pi is on an old OS

A Pi that's been sitting in a drawer may be on Raspbian Stretch (Debian 9,
2017) or Buster. Stretch gives itself away like this:

```
E: The repository 'http://raspbian.raspberrypi.org/raspbian stretch Release'
   does no longer have a Release file.
```

Those repositories have been removed - Stretch went end-of-life in 2020 -
so `apt update` fails and nothing can be installed until it's pointed at an
archive mirror. Stretch also ships Ruby 2.3, well below the 3.0 floor, and
building a modern Ruby there tends to founder on its OpenSSL being too old
for Ruby 3.1+.

**The quick way out is a fresh SD card with current Raspberry Pi OS.** The
old card stays exactly as it is, so it's reversible: swap it back whenever
you like. If the Pi is doing something else that ties it to its current OS
(a Patchbox OS audio setup, say), check whether that distribution has a
current release built on Bookworm rather than fighting the old one.

Staying on the old OS is possible - repoint `/etc/apt/sources.list` at the
archive (`legacy.raspbian.org` is where Raspbian's retired releases went)
and build Ruby from source with `rbenv` - but it's hours of compiling for a
machine that will still have no security updates, on a service you're about
to expose over Tailscale behind a login. Not a trade I'd make.

## 1b. Getting the code onto the Pi

**If the repository is public, clone over HTTPS and skip the key business
entirely:**

```
git clone https://github.com/colincurrie/ai_ideas.git
```

`git clone git@github.com:...` uses SSH, which needs a key GitHub knows
about - hence `Permission denied (publickey)` on a fresh Pi. HTTPS needs
nothing for a public repo.

**If it's private**, the Pi needs a credential. An SSH deploy key is the
tidy option for a machine that will sit there for years: it's read-only and
scoped to this one repository, so a compromised Pi can't touch anything
else in the account.

On the Pi:

```
ssh-keygen -t ed25519 -C "patchbox-sign" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Copy that one line, then on GitHub go to the **repository** (not your
account) → Settings → Deploy keys → Add deploy key, paste it, and leave
"Allow write access" **unchecked** - the Pi only ever needs to pull.

Then:

```
ssh -T git@github.com          # expect "successfully authenticated"
git clone git@github.com:colincurrie/ai_ideas.git
```

An account-wide key (Settings → SSH and GPG keys) works too and is fine if
the Pi is only ever yours, but it grants the Pi everything you can reach.

Either way, from `ferrograph-alphasign/`:

```
bundle install
```

### Updating later

```
cd ~/Documents/ai_ideas && git pull
sudo systemctl restart ferrograph-serial-api ferrograph-web-app
```

Restart **both**: `serial_api` keeps the sign's file layout in memory, so a
half-updated pair will disagree about what the sign is holding.

## 1c. Letting the Pi talk to the sign

Plug the USB-serial adapter in and find it:

```
ls -l /dev/ttyUSB*
```

Expect `/dev/ttyUSB0` - not the `/dev/tty.usbserial-…` name macOS uses.

Note the group in that listing: `dialout`. An ordinary user isn't in it, so
opening the port fails with `Permission denied @ rb_sysopen -
/dev/ttyUSB0`, and it fails identically whether you're running the CLI by
hand or under systemd. Fix it once:

```
sudo usermod -aG dialout $USER
```

Then **log out and back in** - group membership only applies to new
sessions, which is why this often looks like it didn't work. Check with
`groups`. Whichever user the systemd units run as needs to be in `dialout`
too.

Confirm the whole path before going further:

```
bundle exec bin/alphasign send -d /dev/ttyUSB0 "HELLO FROM THE PI"
```

### Optional: a name that doesn't move

`/dev/ttyUSB0` is assigned in plug order, so a second USB-serial device
would renumber it. If that ever matters, give the adapter a fixed name.
Find its identifiers:

```
udevadm info -a -n /dev/ttyUSB0 | grep -m2 -E "idVendor|idProduct"
```

Then `/etc/udev/rules.d/99-ferrograph-sign.rules`, with your own values:

```
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", SYMLINK+="ferrograph-sign"
```

```
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Now set `SERIAL_DEVICE=/dev/ferrograph-sign` below and it stays correct
whatever else gets plugged in.

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
units below). Note these are systemd `EnvironmentFile`s, not `.env` files -
paste values in **unquoted** (unlike the `.env`/`dotenv` convention used
for local development in the README, systemd doesn't strip quote
characters, so quoting here would make them part of the literal value).

`/etc/ferrograph/serial-api.env`:

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
# Where the record of what the sign is holding lives. systemd creates
# /var/lib/ferrograph and hands it to this service; keeping it out of the
# checkout means a fresh clone or redeploy doesn't lose track of the sign.
StateDirectory=ferrograph
Environment=SERIAL_API_STATE_FILE=/var/lib/ferrograph/layout.json
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

`User=` must be a user in the `dialout` group (see 1c) - systemd doesn't
care that *you* can open the port, only that the service's user can.

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
