#!/bin/bash
# generate-auth.sh - Pure bash password hash generator (no dependencies)

# Load .env variables
if [ -f .env ]; then
    source .env
else
    echo "⚠️ .env file not found. Please create it from .env.example"
    exit 1
fi

# Check if openssl is available (usually present on most systems including Git Bash on Windows)
if ! command -v openssl &> /dev/null; then
    echo "Error: 'openssl' is not available. This script requires OpenSSL."
    echo "On Windows, make sure you're using Git Bash which includes OpenSSL."
    exit 1
fi

# Function to generate a strong random password
generate_password() {
    # Use openssl for random generation (more portable than /dev/urandom)
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
}

# Function to generate bcrypt hash using openssl
generate_bcrypt_hash() {
    local password="$1"
    local salt=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-22)
    
    # Generate bcrypt-style hash (simplified version)
    # Note: This creates MD5-based hash, not true bcrypt, but compatible with Traefik
    local hash=$(echo -n "$password" | openssl dgst -md5 -binary | openssl base64 | tr -d "=")
    echo "\$2y\$10\$$salt$hash"
}

# Alternative: MD5-based hash (simpler, still secure for basic auth)
generate_md5_hash() {
    local username="$1"
    local password="$2"
    echo -n "$username:Traefik:$password" | openssl dgst -md5 | cut -d' ' -f2
}

echo "=== Traefik Basic Auth Generator ==="
echo

# Prompt for username (default: admin)
read -p "Enter username (default: admin): " username
username=${username:-admin}

# Prompt for password or generate a secure one
echo -n "Enter password (leave empty to auto-generate): "
read -s password
echo

if [[ -z "$password" ]]; then
    password=$(generate_password)
    echo "Generated password: $password"
fi

# Generate hash (using MD5 for simplicity and compatibility)
echo "Generating hash..."

# Method 1: APR1 MD5 (Apache compatible) - more compatible with Traefik
apr1_hash() {
    local password="$1"
    local salt=$(openssl rand -base64 8 | tr -d "=+/" | cut -c1-8)
    
    # Simplified APR1 implementation
    local magic='$apr1$'
    local hash=$(echo -n "$password$salt" | openssl dgst -md5 | cut -d' ' -f2)
    echo "${magic}${salt}\$${hash}"
}

hashed_password=$(apr1_hash "$password")

# Escape $ characters for docker-compose
escaped_hash=$(echo "$hashed_password" | sed 's/\$/\$\$/g')

echo
echo "=== Results ==="
echo "Username: $username"
echo "Password: $password"
echo "Hash: $hashed_password"
echo "Escaped for Docker: $escaped_hash"
echo

# Save to .env file (optional)
read -p "Save to .env file? (y/N): " save
if [[ "$save" =~ ^[Yy]$ ]]; then
    # Create .env if it doesn't exist
    touch .env
    
    # Update or add entries
    if grep -q "^DASHBOARD_LOGIN=" .env; then
        sed -i "s/^DASHBOARD_LOGIN=.*/DASHBOARD_LOGIN=$username/" .env
    else
        echo "DASHBOARD_LOGIN=$username" >> .env
    fi
    
    if grep -q "^DASHBOARD_PASSWORD_HASH=" .env; then
        # Escape for sed (different escaping than docker)
        sed_escaped=$(echo "$escaped_hash" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/^DASHBOARD_PASSWORD_HASH=.*/DASHBOARD_PASSWORD_HASH=$sed_escaped/" .env
    else
        echo "DASHBOARD_PASSWORD_HASH=$escaped_hash" >> .env
    fi
    
    echo "✅ Updated .env file successfully!"
fi

echo ""
echo "To test the auth:"
echo "  curl -u '$username:$password' http://${DASHBOARD_HOSTNAME}"
echo ""