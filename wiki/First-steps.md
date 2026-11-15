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
show a warning and apps such as Immich and Nextcloud may refuse to connect.

**On each device, open the dashboard and choose _Trust this device_ at the
bottom.** It picks the device you are on, offers the right download and shows
the steps. Accept the browser's warning once to reach the dashboard.

| Device | Download | Then |
| --- | --- | --- |
| iPhone / iPad | Profile (`/hbox-ca.mobileconfig`), in Safari | Settings > Profile Downloaded > Install; then Settings > General > About > Certificate Trust Settings > enable HBOX |
| Android | `/hbox-ca.crt` | Settings > Security > Encryption & credentials > Install a certificate > CA certificate |
| macOS | `/hbox-ca.crt` | Open it in Keychain Access, then set "Always Trust" |
| Windows | `/hbox-ca.crt` | Open the file > Install Certificate > Local Machine > "Trusted Root Certification Authorities" |
| Linux | `/hbox-ca.crt` | Copy to `/usr/local/share/ca-certificates/`, run `sudo update-ca-certificates` |

Both files are also served over plain HTTP, for example
`http://hbox.local/hbox-ca.mobileconfig`. On an iPhone, the profile works where
the bare `.crt` file can fail with "unknown error". The last step on the
iPhone (Certificate Trust Settings) is easy to miss: without it, Safari still
warns and apps still refuse.

`sudo hbox ca` prints the same instructions. Trust is kept when the
certificate is renewed.

## 3. Phone apps

| App | Server address |
| --- | --- |
| Immich | `https://photos.hbox.local` or `https://<server-ip>:2443` |
| Nextcloud | `https://files.hbox.local` or `https://<server-ip>:3443` |

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
