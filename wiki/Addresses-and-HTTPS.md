# Addresses and HTTPS

## Addresses

Every way of reaching the server serves the same ports: `hbox.local`, the LAN
IP, the Tailscale IP and the tailnet name.

| Address | Serves |
| --- | --- |
| `https://<address>/` | Dashboard |
| `https://<address>:2443/` | Photos |
| `https://<address>:3443/` | Files |
| `https://<address>:5443/` | Admin |
| `https://<address>:6443/` | Backups (once set up) |
| `https://<address>:<port>/` | Each enabled [optional app](Optional-apps.md) |
| `/photos`, `/files`, `/admin`, `/backups` | Redirect to the matching port |
| `http://<address>/hbox-ca.crt` | HBOX's CA certificate |
| `http://<address>/hbox-ca.mobileconfig` | The same, as a profile for iPhone and iPad |
| `https://<address>/#trust` | Dashboard: steps to trust HBOX on this device |

On the LAN, `photos.local`, `files.local` and `admin.local` also serve their
app on the normal port 443.

Each app runs at the root of its own port because that works for IP
addresses and tailnet names, where per-app subdomains cannot.

## `.local` names

HBOX announces `hbox.local`, `photos.local`, `files.local` and `admin.local`
over mDNS (avahi). This works on Windows 10+, macOS, iOS, Linux and most
Android 12+ devices. For other devices, add the names to your router's DNS
pointing at the server's IP, or use the IP.

Turn announcements off with `HBOX_MDNS=0` in `.env`.

## Other names

Nextcloud automatically accepts the server's `.local` names, hostname, LAN IP,
`*.ts.net` names and `100.*` Tailscale addresses. Add any other name or IP
(a router DNS name, a second network) comma-separated to `HBOX_EXTRA_NAMES`
in `/opt/hbox/.env`, then:

```sh
sudo hbox certs renew
sudo hbox update
```

## Certificates

HBOX creates its own certificate authority at install (`/etc/hbox/ca`) and
issues the server's certificate from it. The certificate covers the `.local`
names, hostname, LAN IP, Tailscale IP and tailnet name, and
`HBOX_EXTRA_NAMES`.

- It is reissued automatically when an address changes (weekly check, and
  immediately after `hbox enable tailscale`) and 30 days before it expires.
- Devices trust the CA once ([First steps](First-steps.md#2-trust-hboxs-https));
  renewals need nothing more.
- `sudo hbox certs names` lists the covered names; `sudo hbox certs renew`
  reissues now.

The CA is included in backups, so a restored server is trusted by the same
devices.
