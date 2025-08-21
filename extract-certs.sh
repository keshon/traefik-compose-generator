#!/bin/bash
# extract-certs.sh - Extracts certificates from acme.json. Should be run inside Traefik container
set -e

ACME_FILE="/acme/acme.json"
CERTS_DIR="/certs"

mkdir -p "$CERTS_DIR"

echo "🔍 Traefik cert extractor started"
echo "Watching: $ACME_FILE"
echo "Output:   $CERTS_DIR"

last_mtime=0

while true; do
    if [ -f "$ACME_FILE" ]; then
        mtime=$(stat -c %Y "$ACME_FILE")
        if [ "$mtime" != "$last_mtime" ]; then
            echo "📦 Detected change in acme.json → extracting certs..."
            last_mtime=$mtime

            # Clean old files
            rm -f "$CERTS_DIR"/*

            # Extract certificates (works for acme v2 json)
            awk '
                /"main":/    { gsub(/[",]/,"",$2); domain=$2 }
                /"sans":/    { sans=""; getline; while ($0 !~ /]/) { gsub(/[",]/,""); sans=sans" "$1; getline } }
                /"certificate":/ { cert=$2; getline; while ($0 !~ /],/ && $0 !~ /],?$/) { cert=cert$0; getline } gsub(/[" ,]/,"",cert) }
                /"key":/    { key=$2; getline; while ($0 !~ /],/ && $0 !~ /],?$/) { key=key$0; getline } gsub(/[" ,]/,"",key)
                               printf("%s\n%s\n", key, cert) | "bash -c \"decode_and_write " domain " '"$CERTS_DIR"' \"" }
            ' "$ACME_FILE"
        fi
    fi
    sleep 10
done

decode_and_write() {
    domain="$1"
    outdir="$2"
    key_b64=$(echo "$3" | head -n1)
    cert_b64=$(echo "$3" | tail -n1)

    echo "$key_b64" | base64 -d > "$outdir/$domain.key" 2>/dev/null || true
    echo "$cert_b64" | base64 -d > "$outdir/$domain.crt" 2>/dev/null || true

    # Split chain
    if [ -s "$outdir/$domain.crt" ]; then
        awk 'BEGIN{c=0}/-----BEGIN CERTIFICATE-----/{c++}{print > "'$outdir'/'$domain'_part"c".pem"}' "$outdir/$domain.crt"
        mv "$outdir/${domain}_part1.pem" "$outdir/$domain.crt"
        [ -f "$outdir/${domain}_part2.pem" ] && mv "$outdir/${domain}_part2.pem" "$outdir/$domain.chain.pem"
    fi

    echo "✅ Extracted cert for $domain"
}
