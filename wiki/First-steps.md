# First steps

## 1. Turn on backups

Attach a USB disk or a second internal disk (an empty one is fine) and run:

```sh
sudo hbox backup disk
```

Pick the disk; for an empty disk you type its name to confirm. HBOX prepares
it and prints a **repository password: store it off the server** (password
manager or paper). Without it, backups cannot be restored on another machine.

NAS and cloud storage also work: see [Backups](Backups.md).

## 2. Trust HBOX's HTTPS

HBOX uses its own certificate authority. Until a device trusts it, browsers
show a warning. On each device, open `http://hbox.local/hbox-ca.crt` (or
`http://<server-ip>/hbox-ca.crt`) and install it:

| Device | How |
| --- | --- |
| Windows | Open the file > Install Certificate > Local Machine > "Trusted Root Certification Authorities" |
| macOS | Open it in Keychain Access, then set "Always Trust" |
| iPhone / iPad | Install the profile, then Settings > General > About > Certificate Trust Settings > enable HBOX |
| Android | Settings > Security > Encryption & credentials > Install a certificate > CA certificate |
| Linux | Copy to `/usr/local/share/ca-certificates/hbox-ca.crt`, run `sudo update-ca-certificates` |

`sudo hbox ca` prints the same instructions. Trust is kept when the
certificate is renewed.

## 3. Phone apps

| App | Server address |
| --- | --- |
| Immich | `https://photos.local` or `https://<server-ip>:2443` |
| Nextcloud | `https://files.local` or `https://<server-ip>:3443` |

With [remote access](Remote-access.md), use the tailnet name instead
(`https://hbox.<tailnet>.ts.net:2443`) so the apps work at home and away.

If `.local` names don't resolve on a device (some Android versions, guest
Wi-Fi), use the IP address.

## 4. Check everything

```sh
sudo hbox doctor
```

It checks every app, the certificate, disk space and backups, and says how to
fix anything it finds.
