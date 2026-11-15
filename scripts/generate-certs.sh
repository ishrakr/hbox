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

# Extra names and addresses this server is reached by (LAN IP, <host>.local,
# Tailscale IP and tailnet name), comma or space separated in HBOX_CERT_NAMES.
extra_names=$(printf '%s' "${HBOX_CERT_NAMES:-}" | tr ',' ' ')
is_ip() { case $1 in *[!0-9a-fA-F.:]* | '') return 1 ;; *[.:]*) return 0 ;; *) return 1 ;; esac; }
is_private_ip() {
    case $1 in
        10.* | 127.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
        100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
        ::1 | [fF][cCdD]*:*) return 0 ;;
    esac
    return 1
}

# The CA may only vouch for these names and addresses (X.509 name
# constraints): devices that trust it reject a certificate it signs for
# anything else, such as a bank's website, even if its key ever leaked.
# Fixed: the .local names, HBOX's short names, the private top-level names
# routers use, and private and Tailscale address ranges. Plus the tailnet and
# any other name the server has when the CA is created.
ca_constraints() {
    dns="local localhost hbox photos files admin lan home home.arpa internal"
    ips="IP:10.0.0.0/255.0.0.0,IP:172.16.0.0/255.240.0.0,IP:192.168.0.0/255.255.0.0"
    ips="$ips,IP:100.64.0.0/255.192.0.0,IP:127.0.0.0/255.0.0.0"
    ips="$ips,IP:0:0:0:0:0:0:0:1/FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF,IP:FC00:0:0:0:0:0:0:0/FE00:0:0:0:0:0:0:0"
    tailnet=''
    for name in $extra_names; do
        if is_ip "$name"; then
            is_private_ip "$name" && continue
            case $name in
                *:*) ips="$ips,IP:$name/FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF" ;;
                *) ips="$ips,IP:$name/255.255.255.255" ;;
            esac
            continue
        fi
        case $name in *[!A-Za-z0-9.-]* | '') continue ;; esac
        name=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
        case $name in
            *.ts.net) tailnet=${name#*.}; name=$tailnet ;;
        esac
        covered=0
        for allowed in $dns; do
            case $name in "$allowed" | *."$allowed") covered=1 ;; esac
        done
        [ "$covered" = 1 ] || dns="$dns $name"
    done
    # Tailscale not connected yet: any tailnet, so enabling it later works.
    [ -n "$tailnet" ] || dns="$dns ts.net"
    out=''
    for name in $dns; do out="$out${out:+,}permitted;DNS:$name"; done
    printf '%s' "$out"
    printf '%s' ",$ips" | sed 's/,IP:/,permitted;IP:/g'
}

if [ "$ca_present" -eq 0 ]; then
    CA_WORK=$(mktemp -d "$CA_DIR/.generate.XXXXXXXX")
    trap 'rm -rf -- "$WORK" "$CA_WORK"' EXIT
    cat > "$CA_WORK/ca.cnf" <<EOF
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
nameConstraints = critical,$(ca_constraints)
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

# One name outside the CA's limits would make devices reject the whole
# certificate, so each extra name is first tried on its own: signed into a
# throwaway certificate and verified against the CA, as a device would.
openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$WORK/probe.key" -out "$WORK/probe.csr" -subj "/CN=probe" 2>/dev/null
ca_permits() {
    printf 'basicConstraints = critical,CA:FALSE\nsubjectAltName = %s:%s\n' "$1" "$2" > "$WORK/probe.cnf"
    openssl x509 -req -in "$WORK/probe.csr" -days 1 -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
        -set_serial 1 -extfile "$WORK/probe.cnf" -out "$WORK/probe.crt" 2>/dev/null &&
        openssl verify -CAfile "$CA_DIR/ca.crt" "$WORK/probe.crt" >/dev/null 2>&1
}

dns_n=9
ip_n=1
excluded=''
for name in $extra_names; do
    if is_ip "$name"; then
        type=IP
    else
        # Hostnames: letters, digits, dots and hyphens only.
        case $name in *[!A-Za-z0-9.-]* | '') continue ;; esac
        type=DNS
    fi
    if ! ca_permits "$type" "$name"; then
        excluded="$excluded $name"
        continue
    fi
    if [ "$type" = IP ]; then
        ip_n=$((ip_n + 1))
        printf 'IP.%s = %s\n' "$ip_n" "$name" >> "$WORK/leaf.cnf"
    else
        dns_n=$((dns_n + 1))
        printf 'DNS.%s = %s\n' "$dns_n" "$name" >> "$WORK/leaf.cnf"
    fi
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

# Names the CA cannot vouch for (added after it was created); hbox reports
# them instead of reissuing for them again and again.
if [ -n "$excluded" ]; then
    printf '%s\n' $excluded > "$WORK/names-excluded"
    chmod 644 "$WORK/names-excluded"
    mv -f -- "$WORK/names-excluded" "$DEST/names-excluded"
    echo "Not covered (outside the HBOX CA's names):$excluded" >&2
else
    rm -f -- "$DEST/names-excluded"
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
