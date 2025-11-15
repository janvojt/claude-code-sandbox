#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
WHITELIST_FILE="${CLAUDE_SANDBOX_WHITELIST:-$HOME/.config/claude-sandbox/whitelist.txt}"
BLACKLIST_FILE="${CLAUDE_SANDBOX_BLACKLIST:-$HOME/.config/claude-sandbox/blacklist.txt}"
ALLOW_LOCAL_NET=false
WORKING_DIR="$(pwd)"

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [-- CLAUDE_ARGS...]

Securely run Claude Code in a sandboxed environment using bubblewrap.

OPTIONS:
    --whitelist FILE        Path to whitelist file (default: $WHITELIST_FILE)
    --blacklist FILE        Path to blacklist file (default: $BLACKLIST_FILE)
    --allow-local-net       Allow access to local network (disabled by default)
    -h, --help             Show this help message

CONFIGURATION FILES:
    Whitelist: Contains absolute paths (one per line) that Claude can read
    Blacklist: Contains paths relative to working directory that Claude cannot access

EXAMPLES:
    $0
    $0 --allow-local-net
    $0 --whitelist /path/to/custom-whitelist.txt
    $0 -- --model claude-sonnet-4-5

EOF
    exit 1
}

# Parse command line arguments
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --whitelist)
            WHITELIST_FILE="$2"
            shift 2
            ;;
        --blacklist)
            BLACKLIST_FILE="$2"
            shift 2
            ;;
        --allow-local-net)
            ALLOW_LOCAL_NET=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            CLAUDE_ARGS=("$@")
            break
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}" >&2
            usage
            ;;
    esac
done

# Check if bubblewrap is installed
if ! command -v bwrap &> /dev/null; then
    echo -e "${RED}Error: bubblewrap (bwrap) is not installed${NC}" >&2
    echo "Install it with: sudo apt install bubblewrap (Debian/Ubuntu) or sudo dnf install bubblewrap (Fedora)" >&2
    exit 1
fi

# Check if claude is installed
if ! command -v claude &> /dev/null; then
    echo -e "${RED}Error: claude is not installed${NC}" >&2
    echo "Install it from: https://docs.claude.com/en/docs/claude-code" >&2
    exit 1
fi

# Create default whitelist if it doesn't exist
if [[ ! -f "$WHITELIST_FILE" ]]; then
    echo -e "${YELLOW}Warning: Whitelist file not found at $WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default whitelist...${NC}" >&2
    mkdir -p "$(dirname "$WHITELIST_FILE")"
    cat > "$WHITELIST_FILE" << 'EOWHITELIST'
# Claude Code Sandbox Whitelist
# Add absolute paths (one per line) that Claude should be able to read
# Lines starting with # are ignored

# Essential system directories
/usr/bin
/usr/lib
/usr/lib64
/usr/share
/lib
/lib64
/bin
/sbin

# Common development tools locations
/usr/local/bin
/usr/local/lib

# Node.js (if installed via package manager)
/usr/lib/node_modules

# System configuration that's generally safe
/etc/alternatives
/etc/ssl/certs

EOWHITELIST
    echo -e "${GREEN}Created default whitelist at $WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Create default blacklist if it doesn't exist
if [[ ! -f "$BLACKLIST_FILE" ]]; then
    echo -e "${YELLOW}Warning: Blacklist file not found at $BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default blacklist...${NC}" >&2
    mkdir -p "$(dirname "$BLACKLIST_FILE")"
    cat > "$BLACKLIST_FILE" << 'EOBLACKLIST'
# Claude Code Sandbox Blacklist
# Add paths relative to working directory that Claude should NOT access
# Lines starting with # are ignored

# Common sensitive files
.env
.env.local
.env.production
secrets.*
.secrets.*
*token*.json

# SSH and crypto keys
.ssh
*.pem
*.key
id_rsa
id_ed25519
*.p12
*.pfx

# AWS credentials
.aws/credentials

# Docker and Kubernetes secrets
docker-compose.override.yml
.kube/config

# Password managers
*.kdbx
*.agilekeychain
.vault_password

EOBLACKLIST
    echo -e "${GREEN}Created default blacklist at $BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Build bubblewrap arguments
BWRAP_ARGS=(
    # Create new namespaces
    --unshare-all
    --share-net  # We'll handle network filtering via iptables/hosts
    --die-with-parent
    
    # Proc and dev
    --proc /proc
    --dev /dev
    
    # Tmp directories
    --tmpfs /tmp

    # Make root readonly
    --ro-bind /sys /sys
)

# Process whitelist and add to bubblewrap
if [[ -f "$WHITELIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Expand and validate path
        path=$(eval echo "$line")
        
        if [[ -e "$path" ]]; then
            BWRAP_ARGS+=(--ro-bind "$path" "$path")
            echo -e "${GREEN}✓${NC} Whitelisted: $path" >&2
        else
            echo -e "${YELLOW}⚠${NC} Skipping non-existent path: $path" >&2
        fi
    done < "$WHITELIST_FILE"
else
    echo -e "${RED}Error: Whitelist file not found: $WHITELIST_FILE${NC}" >&2
    exit 1
fi

# Setup minimal home directory using tmpfs
BWRAP_ARGS+=(--tmpfs "$HOME")

# Bind working directory (after tmpfs home, so it's visible)
BWRAP_ARGS+=(--bind "$WORKING_DIR" "$WORKING_DIR")

# Process blacklist patterns and hide them with tmpfs overlays
BLACKLISTED_PATHS=()
if [[ -f "$BLACKLIST_FILE" ]]; then
    echo -e "\n${YELLOW}Processing blacklist patterns:${NC}" >&2
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${pattern// }" ]] && continue

        # Find matching files/directories in working directory
        if compgen -G "$WORKING_DIR/$pattern" > /dev/null 2>&1; then
            for match in "$WORKING_DIR"/$pattern; do
                if [[ -e "$match" ]]; then
                    # Add tmpfs to hide each blacklisted path
                    BWRAP_ARGS+=(--tmpfs "$match")
                    echo -e "${RED}✗${NC} Blacklisted: ${match#$WORKING_DIR/}" >&2
                fi
            done
        else
            echo -e "${YELLOW}⚠${NC} No matches for pattern: $pattern" >&2
        fi
    done < "$BLACKLIST_FILE"
fi

# Bind claude binary
if [[ -x "$HOME/.local/bin/claude" ]]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin/claude" "$HOME/.local/bin/claude")
    echo -e "${GREEN}✓${NC} Mounted ~/.local/bin/claude (read-only)" >&2
fi

# Bind ~/.claude directory (main config location)
if [[ -d "$HOME/.claude" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude" "$HOME/.claude")
    echo -e "${GREEN}✓${NC} Mounted ~/.claude (read-write)" >&2
fi

# Bind ~/.claude.json file (state file in home directory)
if [[ -f "$HOME/.claude.json" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    echo -e "${GREEN}✓${NC} Mounted ~/.claude.json (read-write)" >&2
else
    # Create empty file if it doesn't exist so Claude can write to it
    touch "$HOME/.claude.json"
    BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    echo -e "${YELLOW}✓${NC} Created and mounted ~/.claude.json (read-write)" >&2
fi

# Bind ~/.claude.json.backup if it exists
if [[ -f "$HOME/.claude.json.backup" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude.json.backup" "$HOME/.claude.json.backup")
fi

BWRAP_ARGS+=(--setenv HOME "$HOME")
BWRAP_ARGS+=(--setenv PWD "$WORKING_DIR")
BWRAP_ARGS+=(--chdir "$WORKING_DIR")

# Network restrictions via /etc/hosts
if [[ "$ALLOW_LOCAL_NET" = false ]]; then
    echo -e "\n${GREEN}Network restrictions active - blocking local networks${NC}" >&2
    
    TEMP_HOSTS=$(mktemp)
    cat > "$TEMP_HOSTS" << 'EOHOSTS'
# Localhost
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback

# Block common local network ranges via DNS resolution
127.0.0.1 10.0.0.1 10.0.0.2 10.255.255.254
127.0.0.1 172.16.0.1 172.31.255.254
127.0.0.1 192.168.0.1 192.168.1.1 192.168.255.254
127.0.0.1 169.254.0.1 169.254.255.254

# Block localhost alternatives
127.0.0.1 localhost.localdomain
127.0.0.1 127.0.0.2 127.0.0.3 127.255.255.254

EOHOSTS
    
    BWRAP_ARGS+=(--ro-bind "$TEMP_HOSTS" /etc/hosts)
    trap "rm -rf $TEMP_HOSTS" EXIT

    # Create resolv.conf that blocks local DNS
    TEMP_RESOLV=$(mktemp)
    echo "nameserver 8.8.8.8" > "$TEMP_RESOLV"
    echo "nameserver 1.1.1.1" >> "$TEMP_RESOLV"
    BWRAP_ARGS+=(--ro-bind "$TEMP_RESOLV" /etc/resolv.conf)
    trap "rm -rf $TEMP_HOSTS $TEMP_RESOLV" EXIT
    
    echo -e "${YELLOW}Note: Network blocking via /etc/hosts is DNS-level only.${NC}" >&2
    echo -e "${YELLOW}For complete IP-level blocking, use --unshare-net with slirp4netns.${NC}" >&2
else
    echo -e "\n${YELLOW}Warning: Local network access is ALLOWED${NC}" >&2
    # Use system resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
    fi
fi

# Set minimal environment
BWRAP_ARGS+=(--setenv TERM "${TERM:-xterm-256color}")
BWRAP_ARGS+=(--setenv PATH "$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin")
BWRAP_ARGS+=(--unsetenv SSH_AUTH_SOCK)
BWRAP_ARGS+=(--unsetenv SSH_AGENT_PID)

# Preserve Claude-specific environment variables
if [[ -n "${CLAUDECODE:-}" ]]; then
    BWRAP_ARGS+=(--setenv CLAUDECODE "$CLAUDECODE")
fi
if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    BWRAP_ARGS+=(--setenv CLAUDE_CODE_ENTRYPOINT "$CLAUDE_CODE_ENTRYPOINT")
fi

# Display configuration summary
echo -e "\n${GREEN}=== Claude Code Sandbox Configuration ===${NC}" >&2
echo -e "Working Directory: ${YELLOW}$WORKING_DIR${NC}" >&2
echo -e "Whitelist File: ${YELLOW}$WHITELIST_FILE${NC}" >&2
echo -e "Blacklist File: ${YELLOW}$BLACKLIST_FILE${NC}" >&2
echo -e "Local Network: ${YELLOW}$(if $ALLOW_LOCAL_NET; then echo 'ALLOWED'; else echo 'BLOCKED'; fi)${NC}" >&2
echo -e "${GREEN}=========================================${NC}\n" >&2

# Find claude executable
CLAUDE_BIN=$(command -v claude)

# Execute Claude Code in sandbox
exec bwrap "${BWRAP_ARGS[@]}" -- "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}"
