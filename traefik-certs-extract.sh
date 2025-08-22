#!/bin/sh
# traefik-certs-extract.sh - Extracts certificates from Traefik acme.json

echo "------------------------------"
echo "Traefik Certificate Extractor"
echo "------------------------------"

# -------------------------------
# Constants
# -------------------------------
WATCH_INTERVAL=10
SEARCH_RANGE=50

# -------------------------------
# Parse command line arguments
# -------------------------------
WATCH_MODE=false
if [ "$1" = "--watch" ]; then
    WATCH_MODE=true
fi

# -------------------------------
# Load environment variables
# -------------------------------
if [ -f .env ]; then
    # shellcheck source=/dev/null
    . ./.env
else
    echo ".env file not found"
fi

# -------------------------------
# Set directory paths
# -------------------------------
if [ -z "$DATA_DIR" ]; then
    echo "DATA_DIR is not set in .env. Using current directory..."
    DATA_DIR=.
fi

ACME_FILE="$DATA_DIR/acme/acme.json"
CERTS_DIR="$DATA_DIR/certs"

# -------------------------------
# Ensure certificates directory exists
# -------------------------------
if [ ! -d "$CERTS_DIR" ]; then
    echo "CERTS_DIR ($CERTS_DIR) not found → creating..."
    mkdir -p "$CERTS_DIR"
    echo "Created $CERTS_DIR"
fi

echo "Input:  $ACME_FILE"
echo "Output: $CERTS_DIR"
echo "Mode:   $([ "$WATCH_MODE" = true ] && echo "Watch mode (--watch)" || echo "Single run")"

last_mtime=0

# -------------------------------
# Helper functions
# -------------------------------
decode_and_write() {
    domain="$1"
    key_b64="$2"
    cert_b64="$3"
    
    if [ -n "$domain" ] && [ -n "$key_b64" ] && [ -n "$cert_b64" ]; then
        echo "$key_b64" | base64 -d > "$CERTS_DIR/$domain.key" 2>/dev/null || {
            echo "Failed to decode key for $domain"
            return 1
        }
        echo "$cert_b64" | base64 -d > "$CERTS_DIR/$domain.crt" 2>/dev/null || {
            echo "Failed to decode certificate for $domain"
            return 1
        }
        
        # Split certificate chain if multiple certificates are present
        if [ -s "$CERTS_DIR/$domain.crt" ]; then
            awk 'BEGIN{c=0}/-----BEGIN CERTIFICATE-----/{c++}{print > "'$CERTS_DIR'/'$domain'_part"c".pem"}' "$CERTS_DIR/$domain.crt"
            if [ -f "$CERTS_DIR/${domain}_part1.pem" ]; then
                mv "$CERTS_DIR/${domain}_part1.pem" "$CERTS_DIR/$domain.crt"
            fi
            if [ -f "$CERTS_DIR/${domain}_part2.pem" ]; then
                mv "$CERTS_DIR/${domain}_part2.pem" "$CERTS_DIR/$domain.chain.pem"
            fi
        fi
        
        echo "Extracted successfully"
        return 0
    else
        echo "Missing data for domain: $domain"
        return 1
    fi
}

parse_acme_json() {
    local file="$1"
    local cert_count=0
    
    echo "traefik-certs-extract.sh starting..."
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo "File $file not found"
        return 1
    fi
    
    # Find all lines containing domain names
    echo "Searching for certificates..."
    echo "---"
	
    local domains=$(grep -n '"main"[[:space:]]*:' "$file" | cut -d: -f1)
    
    if [ -z "$domains" ]; then
        echo "No domains found"
        return 1
    fi
    
    for line_num in $domains; do
        echo "Processing certificate at line $line_num..."
        
        # Extract domain name
        local domain=$(sed -n "${line_num}p" "$file" | sed -n 's/.*"main"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        
        if [ -z "$domain" ]; then
            echo "Could not extract domain at line $line_num"
            continue
        fi
        
        echo "Domain:      $domain"
        
        # Search for certificate and key within range
        local start_line=$((line_num - SEARCH_RANGE))
        local end_line=$((line_num + SEARCH_RANGE))
        
        if [ $start_line -lt 1 ]; then
            start_line=1
        fi
        
        # Extract certificate and private key
        local cert=$(sed -n "${start_line},${end_line}p" "$file" | grep '"certificate"[[:space:]]*:' | head -1 | sed -n 's/.*"certificate"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        local key=$(sed -n "${start_line},${end_line}p" "$file" | grep '"key"[[:space:]]*:' | head -1 | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        
        echo "Key:         $([ -n "$key" ] && echo "yes (${#key} chars)" || echo "no")"
        echo "Certificate: $([ -n "$cert" ] && echo "yes (${#cert} chars)" || echo "no")"
        
        if [ -n "$key" ] && [ -n "$cert" ]; then
            if decode_and_write "$domain" "$key" "$cert"; then
                cert_count=$((cert_count + 1))
            fi
        else
            echo "Missing certificate or key data for $domain"
            
            # Additional diagnostics
            echo "Debug: Searching in lines ${start_line}-${end_line}"
            local debug_cert=$(sed -n "${start_line},${end_line}p" "$file" | grep -n '"certificate"')
            local debug_key=$(sed -n "${start_line},${end_line}p" "$file" | grep -n '"key"')
            echo "Certificate line: $debug_cert"
            echo "Key line: $debug_key"
        fi
        
        echo "---"
    done
    
    echo "Total certificates processed: $cert_count"
    
    if [ $cert_count -eq 0 ]; then
        echo "No certificates were successfully extracted"
        echo "Fallback: searching for certificate patterns in entire file..."
        
        echo "Certificate lines found:"
        grep -n '"certificate"' "$file" | head -5
        echo "---"
        echo "Key lines found:"
        grep -n '"key"' "$file" | head -5
        
        return 1
    fi
    
    return 0
}

extract_certificates() {
    if [ -f "$ACME_FILE" ]; then
        echo "Processing $ACME_FILE..."
        
        # Clear certificates directory
        rm -f "$CERTS_DIR"/* 2>/dev/null || true
        
        # Parse JSON and extract certificates
        if parse_acme_json "$ACME_FILE"; then
        echo "Certificate extraction completed successfully"
            return 0
        else
        echo "Certificate extraction failed or no certificates found"
            return 1
        fi
    else
        echo "acme.json not found: $ACME_FILE"
        return 1
    fi
}

# -------------------------------
# Main execution logic
# -------------------------------
if [ "$WATCH_MODE" = true ]; then
    echo "Starting watch mode..."
    
    # Watch mode: monitor file changes
    while true; do
        if [ -f "$ACME_FILE" ]; then
            # Cross-platform way to get modification time
            if command -v stat >/dev/null 2>&1; then
                mtime=$(stat -c %Y "$ACME_FILE" 2>/dev/null || stat -f %m "$ACME_FILE" 2>/dev/null || echo 0)
            else
                mtime=$(ls -l "$ACME_FILE" | awk '{print $6$7$8}' 2>/dev/null || echo 0)
            fi
            
            if [ "$mtime" != "$last_mtime" ]; then
                echo "Detected change in acme.json → extracting certificates..."
                last_mtime=$mtime
                extract_certificates
            fi
        else
            echo "Waiting for $ACME_FILE to appear..."
        fi
        
        sleep $WATCH_INTERVAL
    done
else
    # Single run mode
    if extract_certificates; then
        echo "Done!"
        exit 0
    else
        echo "Certificate extraction failed"
        exit 1
    fi
fi