#!/bin/sh
# Create the HBOX local certificate authority (once) and a server certificate
# signed by it. Clients trust the CA once; renewing the server certificate
# then needs no client changes. Never overwrites an existing server key/cert.
#
# Usage: generate-certs.sh [certificate-directory] [ca-directory]
# The certificate directory is mounted into nginx; the CA directory is not.
set -eu
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${1:-"$ROOT/certs"}
CA_DIR=${2:-"${HBOX_CA_DIR:-$ROOT/ca}"}
LEAF_DAYS=${HBOX_CERT_DAYS:-397}
CA_DAYS=3650

if [ "$#" -gt 2 ]; then
    echo "Usage: $0 [certificate-directory] [ca-directory]" >&2
    exit 1
fi

command -v openssl >/dev/null 2>&1 || {
    echo "OpenSSL is required." >&2
    exit 1
}

mkdir -p -- "$DEST" "$CA_DIR"
if [ -e "$DEST/selfsigned.crt" ] || [ -L "$DEST/selfsigned.crt" ] ||
   [ -e "$DEST/selfsigned.key" ] || [ -L "$DEST/selfsigned.key" ]; then
    echo "Refusing to overwrite an existing certificate or key in $DEST." >&2
    exit 1
fi

ca_present=0
if [ -f "$CA_DIR/ca.crt" ] && [ -f "$CA_DIR/ca.key" ] &&
   [ ! -L "$CA_DIR/ca.crt" ] && [ ! -L "$CA_DIR/ca.key" ]; then
    ca_present=1
elif [ -e "$CA_DIR/ca.crt" ] || [ -L "$CA_DIR/ca.crt" ] ||
     [ -e "$CA_DIR/ca.key" ] || [ -L "$CA_DIR/ca.key" ]; then
    echo "Incomplete or unsafe certificate authority in $CA_DIR; refusing to continue." >&2
    exit 1
fi

# Generate privately, then publish with no-clobber hard links so concurrent
# runs can never replace a key another process already published.
WORK=$(mktemp -d "$DEST/.generate.XXXXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

if [ "$ca_present" -eq 0 ]; then
    CA_WORK=$(mktemp -d "$CA_DIR/.generate.XXXXXXXX")
    trap 'rm -rf -- "$WORK" "$CA_WORK"' EXIT
    cat > "$CA_WORK/ca.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = extensions
[dn]
CN = HBOX Local Certificate Authority
O = HBOX
[extensions]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
    openssl req -x509 -nodes -days "$CA_DAYS" -newkey rsa:3072 \
        -keyout "$CA_WORK/ca.key" -out "$CA_WORK/ca.crt" \
        -config "$CA_WORK/ca.cnf" 2>/dev/null
    ln "$CA_WORK/ca.key" "$CA_DIR/ca.key"
    if ! ln "$CA_WORK/ca.crt" "$CA_DIR/ca.crt"; then
        rm -f -- "$CA_DIR/ca.key"
        exit 1
    fi
fi

cat > "$WORK/leaf.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = dn
[dn]
CN = hbox.local
O = HBOX
[extensions]
subjectAltName = @names
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[names]
DNS.1 = hbox.local
DNS.2 = hbox
DNS.3 = photos.local
DNS.4 = photos
DNS.5 = files.local
DNS.6 = files
DNS.7 = admin.local
DNS.8 = admin
DNS.9 = localhost
IP.1 = 127.0.0.1
EOF

# Extra names and addresses this server is reached by (LAN IP, <host>.local,
# Tailscale IP and tailnet name), comma or space separated in HBOX_CERT_NAMES.
dns_n=9
ip_n=1
for name in $(printf '%s' "${HBOX_CERT_NAMES:-}" | tr ',' ' '); do
    case $name in
        *[!0-9a-fA-F.:]*)
            # Hostnames: letters, digits, dots and hyphens only.
            case $name in *[!A-Za-z0-9.-]* | '') continue ;; esac
            dns_n=$((dns_n + 1))
            printf 'DNS.%s = %s\n' "$dns_n" "$name" >> "$WORK/leaf.cnf"
            ;;
        *)
            ip_n=$((ip_n + 1))
            printf 'IP.%s = %s\n' "$ip_n" "$name" >> "$WORK/leaf.cnf"
            ;;
    esac
done

openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$WORK/selfsigned.key" -out "$WORK/leaf.csr" \
    -config "$WORK/leaf.cnf" 2>/dev/null
openssl x509 -req -in "$WORK/leaf.csr" -days "$LEAF_DAYS" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "$WORK/leaf.cnf" -extensions extensions \
    -out "$WORK/selfsigned.crt" 2>/dev/null

ln "$WORK/selfsigned.key" "$DEST/selfsigned.key"
if ! ln "$WORK/selfsigned.crt" "$DEST/selfsigned.crt"; then
    # Only remove the key this invocation just published.
    rm -f -- "$DEST/selfsigned.key"
    exit 1
fi

# The CA certificate is public: nginx serves it so devices can trust HBOX.
cp -- "$CA_DIR/ca.crt" "$WORK/hbox-ca.crt"
chmod 644 "$WORK/hbox-ca.crt"
mv -f -- "$WORK/hbox-ca.crt" "$DEST/hbox-ca.crt"
# The same certificate as a profile, for iPhones and iPads.
sh "$ROOT/scripts/ca-profile.sh" "$DEST/hbox-ca.crt" "$DEST/hbox-ca.mobileconfig"

echo "Created a server certificate (valid $LEAF_DAYS days) in $DEST."
if [ "$ca_present" -eq 0 ]; then
    echo "Created the HBOX certificate authority in $CA_DIR (keep ca.key private)."
fi
echo "Trust $DEST/hbox-ca.crt on your devices to remove browser warnings."
