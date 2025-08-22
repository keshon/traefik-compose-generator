#!/bin/sh
# traefik-basic-auth.sh - Pure shell password hash generator (no dependencies)

echo "------------------------------"
echo "Traefik Basic Auth Generator"
echo "------------------------------"

# -------------------------------
# Constants
# -------------------------------
DEFAULT_USERNAME="admin"
PASSWORD_LENGTH=16

# -------------------------------
# Parse command line arguments
# -------------------------------
SKIP_RESTART=false
if [ "$1" = "--skip-restart" ]; then
    SKIP_RESTART=true
    shift
fi

# -------------------------------
# Ensure .env file exists
# -------------------------------
if [ -f .env ]; then
    # shellcheck source=/dev/null
    . ./.env
else
    echo "Error: .env file not found. Please create it from .env.example"
    exit 1
fi

# -------------------------------
# Check dependencies
# -------------------------------
if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: 'openssl' is not available. This script requires OpenSSL."
    exit 1
fi

# -------------------------------
# Helper functions
# -------------------------------
generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-$PASSWORD_LENGTH
}

apr1_hash() {
    PASSWORD="$1"
    SALT=$(openssl rand -base64 8 | tr -d "=+/" | cut -c1-8)
    HASH=$(echo -n "$PASSWORD$SALT" | openssl dgst -md5 | cut -d' ' -f2)
    echo "\$apr1\$${SALT}\$${HASH}"
}

# -------------------------------
# Collect user input
# -------------------------------
printf "Enter username (default: %s): " "$DEFAULT_USERNAME"
read username
username=${username:-$DEFAULT_USERNAME}

printf "Enter password (leave empty to auto-generate): "
stty -echo
read password
stty echo
echo

if [ -z "$password" ]; then
    password=$(generate_password)
    echo "Generated password: $password"
fi

# -------------------------------
# Generate authentication hash
# -------------------------------
echo "Generating hash..."
hashed_password=$(apr1_hash "$password")
escaped_hash=$(echo "$hashed_password" | sed 's/\$/\$\$/g')

echo
echo "=== Results ==="
echo "Username: $username"
echo "Password: $password"
echo "Hash: $hashed_password"
echo "Escaped for Docker: $escaped_hash"
echo

# -------------------------------
# Save to .env file
# -------------------------------
printf "Save to .env file? (y/N): "
read save
case "$save" in
    y|Y)
        touch .env
        if grep -q "^DASHBOARD_LOGIN=" .env; then
            sed -i "s/^DASHBOARD_LOGIN=.*/DASHBOARD_LOGIN=$username/" .env
        else
            echo "DASHBOARD_LOGIN=$username" >> .env
        fi
        if grep -q "^DASHBOARD_PASSWORD_HASH=" .env; then
            sed_escaped=$(echo "$escaped_hash" | sed -e 's/[\/&]/\\&/g')
            sed -i "s/^DASHBOARD_PASSWORD_HASH=.*/DASHBOARD_PASSWORD_HASH=$sed_escaped/" .env
        else
            echo "DASHBOARD_PASSWORD_HASH=$escaped_hash" >> .env
        fi
        echo "Credentials saved to .env file"
        ;;
esac

echo
echo "To test the auth:"
echo "  curl -u '$username:$password' http://${DASHBOARD_HOSTNAME}"
echo

# -------------------------------
# Docker restart logic
# -------------------------------
if [ "$SKIP_RESTART" = false ]; then
    if command -v docker >/dev/null 2>&1; then
        if command -v docker-compose >/dev/null 2>&1; then
            DOCKER_COMPOSE="docker-compose"
        elif docker compose version >/dev/null 2>&1; then
            DOCKER_COMPOSE="docker compose"
        else
            echo "Docker found, but neither docker-compose nor docker compose available"
            exit 1
        fi
        
        echo "Docker environment found ($DOCKER_COMPOSE)"
        echo "Restarting containers..."
        $DOCKER_COMPOSE up -d --force-recreate
        echo "Traefik restarted successfully"
    else
        echo "Docker not found - skipping restart"
        echo "To restart manually:"
        echo "  $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d"
    fi
fi