#!/bin/sh
# Wrap the HBOX CA certificate in an Apple configuration profile. iPhones and
# iPads install a profile far more reliably than a bare certificate file.
# Its identifiers come from the CA's fingerprint, so the same CA always gives
# the same profile and installing it again replaces the old one.
#
# Usage: ca-profile.sh CA-CERTIFICATE OUTPUT
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 CA-CERTIFICATE OUTPUT" >&2
    exit 1
fi
CA=$1
OUT=$2

fingerprint=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
# A UUID (version 4 layout) from 32 hex digits of the fingerprint.
uuid() {
    printf '%s' "$1" | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-8\4-\5/' | tr 'a-f' 'A-F'
}
cert_uuid=$(uuid "$fingerprint")
profile_uuid=$(uuid "$(printf '%s' "$fingerprint" | cut -c33-64)")
data=$(openssl x509 -in "$CA" -outform DER | openssl base64)
pretty=$(printf '%s' "$fingerprint" | cut -c1-16 | tr 'a-f' 'A-F' | sed -E 's/(..)/\1:/g; s/:$//')

tmp=$(mktemp "$OUT.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>hbox-ca.cer</string>
      <key>PayloadContent</key>
      <data>
$data
      </data>
      <key>PayloadDisplayName</key>
      <string>HBOX Local Certificate Authority</string>
      <key>PayloadIdentifier</key>
      <string>local.hbox.ca.certificate</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$cert_uuid</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Lets this device open the HBOX apps securely (certificate ${pretty}…).</string>
  <key>PayloadDisplayName</key>
  <string>HBOX</string>
  <key>PayloadIdentifier</key>
  <string>local.hbox.ca</string>
  <key>PayloadOrganization</key>
  <string>HBOX</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$profile_uuid</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF
chmod 644 "$tmp"
mv -f -- "$tmp" "$OUT"
trap - EXIT
