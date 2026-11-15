# Remote access

HBOX includes [Tailscale](https://tailscale.com) for private access from
anywhere, without opening ports on your router.

## Turn on

```sh
sudo hbox enable tailscale                              # prints a sign-in link
sudo hbox enable tailscale --authkey tskey-auth-...     # unattended
```

Or during install: `--tailscale-authkey tskey-auth-...`.

Devices on your tailnet then reach HBOX by tailnet name or Tailscale IP, with
the same ports as on the LAN:

```text
https://hbox.<tailnet>.ts.net/         Dashboard
https://hbox.<tailnet>.ts.net:2443/    Photos
https://hbox.<tailnet>.ts.net:3443/    Files
https://hbox.<tailnet>.ts.net:5443/    Admin
https://hbox.<tailnet>.ts.net:6443/    Backups
https://100.x.y.z:3443/                the same, by Tailscale IP
```

The tailnet name needs MagicDNS (on by default). The certificate is reissued
with the Tailscale name and IP as soon as Tailscale connects; devices that
already trust HBOX's CA need nothing else.

Tip: in the Immich and Nextcloud phone apps, use the tailnet addresses so they
work both at home and away.

## Settings

| `.env` | Meaning |
| --- | --- |
| `TS_HOSTNAME` | Machine name on the tailnet (default `hbox`) |
| `TS_ROUTES` | Subnets to advertise, e.g. `192.168.1.0/24` (approve them in the Tailscale admin console) |
| `TS_AUTHKEY` | Auth key for unattended sign-in |

Tailscale's identity is kept in `/DATA/tailscale` and included in backups.

## Turn off

```sh
sudo hbox disable tailscale
```

The identity is kept for turning it on again.

## Tailscale on the host

If Tailscale already runs on the host itself, don't enable HBOX's. Add the
host's tailnet name and Tailscale IP to `HBOX_EXTRA_NAMES` instead (see
[Addresses and HTTPS](Addresses-and-HTTPS.md#other-names)).
