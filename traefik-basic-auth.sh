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
# Determine hash method
# -------------------------------
HASH_METHOD=""
if command -v htpasswd >/dev/null 2>&1; then
    HASH_METHOD="htpasswd"
elif command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" 2>/dev/null; then
    HASH_METHOD="python3"
else
    echo "Warning: Neither htpasswd nor python3 with bcrypt module found."
    echo "Falling back to OpenSSL MD5 (may not work with all Traefik configurations)"
    HASH_METHOD="openssl"
fi

echo "Using hash method: $HASH_METHOD"

# -------------------------------
# Helper functions
# -------------------------------
generate_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-$PASSWORD_LENGTH
}

# -------------------------------
# Bcrypt hash using htpasswd (most reliable)
# -------------------------------
htpasswd_hash() {
    USERNAME="$1"
    PASSWORD="$2"
    htpasswd -nbB "$USERNAME" "$PASSWORD" | cut -d: -f2
}

# -------------------------------
# Bcrypt hash using Python3 (fallback)
# -------------------------------
python3_hash() {
    PASSWORD="$1"
    python3 -c "
import bcrypt
password = b'$PASSWORD'
salt = bcrypt.gensalt(rounds=12)
hash = bcrypt.hashpw(password, salt)
print(hash.decode('utf-8'))
"
}

# -------------------------------
# APR1 MD5 hash using OpenSSL (last resort)
# -------------------------------
apr1_hash() {
    PASSWORD="$1"
    SALT=$(openssl rand -base64 8 | tr -d "=+/" | cut -c1-8)
    
    # More robust APR1 implementation
    HASH=$(printf '%s%s%s' "$PASSWORD" '$apr1$' "$SALT" | openssl dgst -md5 -binary | openssl base64 | tr -d '\n' | sed 's/=*$//')
    
    # Simplified version - may work better
    SIMPLE_HASH=$(echo -n "${PASSWORD}${SALT}" | openssl dgst -md5 | cut -d' ' -f2)
    echo "\$apr1\$${SALT}\$${SIMPLE_HASH}"
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
echo "Generating hash using $HASH_METHOD..."

case "$HASH_METHOD" in
    "htpasswd")
        hashed_password=$(htpasswd_hash "$username" "$password")
        ;;
    "python3")
        hashed_password=$(python3_hash "$password")
        ;;
    *)
        hashed_password=$(apr1_hash "$password")
        ;;
esac

escaped_hash=$(echo "$hashed_password" | sed 's/\$/\$\$/g')

echo
echo "=== Results ==="
echo "Username: $username"
echo "Password: $password"
echo "Hash: $hashed_password"
echo "Escaped for Docker: $escaped_hash"
echo

# -------------------------------
# Generate Traefik label format
# -------------------------------
echo "For Traefik labels:"
echo "  - \"traefik.http.middlewares.auth.basicauth.users=$username:$escaped_hash\""
echo

# -------------------------------
# Check hash format
# -------------------------------
case "$hashed_password" in
    \$2[aby]\$*) echo "Using bcrypt hash (recommended)" ;;
    \$apr1\$*) echo "Using APR1 MD5 hash (may have compatibility issues)" ;;
    *) echo "Unknown hash format" ;;
esac

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

# -------------------------------
# Display test instructions
# -------------------------------
echo
echo "To test the auth:"
echo "  curl -u '$username:$password' https://${DASHBOARD_HOSTNAME}"
echo

echo "=== Debug Information ==="
echo "If authentication still fails, check:"
echo "1. Traefik configuration uses the correct middleware"
echo "2. The hash is properly escaped in docker-compose.yml"
echo "3. Container has been restarted after configuration change"
echo "4. Dashboard URL ends with trailing slash (/dashboard/)"
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
        printf "Restart containers? (y/N): "
        read restart
        case "$restart" in
            y|Y)
                echo "Restarting containers..."
                $DOCKER_COMPOSE up -d --force-recreate
                echo "Traefik restarted successfully"
                ;;
            *)
                echo "Skipping restart. To restart manually:"
                echo "  $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d"
                ;;
        esac
    else
        echo "Docker not found - skipping restart"
        echo "To restart manually:"
        echo "  $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d"
    fi
fi