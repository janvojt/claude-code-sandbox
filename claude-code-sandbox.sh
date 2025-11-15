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
QUIET=false
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
    --quiet, -q            Suppress informational output (faster startup)
    --verbose, -v          Show detailed output (default)
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
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --verbose|-v)
            QUIET=false
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

# Helper function for conditional output
log_info() {
    [[ "$QUIET" = false ]] && echo -e "$@" >&2
}

# Cache command availability checks
BWRAP_BIN=$(command -v bwrap 2>/dev/null)
CLAUDE_BIN=$(command -v claude 2>/dev/null)
SLIRP4NETNS_BIN=$(command -v slirp4netns 2>/dev/null)

# Check if bubblewrap is installed
if [[ -z "$BWRAP_BIN" ]]; then
    echo -e "${RED}Error: bubblewrap (bwrap) is not installed${NC}" >&2
    echo "Install it with: sudo apt install bubblewrap (Debian/Ubuntu) or sudo dnf install bubblewrap (Fedora)" >&2
    exit 1
fi

# Check if claude is installed
if [[ -z "$CLAUDE_BIN" ]]; then
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
    # Create new namespaces (including network namespace for isolation)
    --unshare-all
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

        # Expand environment variables without eval (faster)
        path="${line/#\~/$HOME}"
        path="${path//\$HOME/$HOME}"

        if [[ -e "$path" ]]; then
            BWRAP_ARGS+=(--ro-bind "$path" "$path")
            log_info "${GREEN}✓${NC} Whitelisted: $path"
        else
            log_info "${YELLOW}⚠${NC} Skipping non-existent path: $path"
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
if [[ -f "$BLACKLIST_FILE" ]]; then
    log_info "\n${YELLOW}Processing blacklist patterns:${NC}"
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${pattern// }" ]] && continue

        # Find matching files/directories in working directory
        if compgen -G "$WORKING_DIR/$pattern" > /dev/null 2>&1; then
            for match in "$WORKING_DIR"/$pattern; do
                if [[ -e "$match" ]]; then
                    # Add tmpfs to hide each blacklisted path
                    BWRAP_ARGS+=(--tmpfs "$match")
                    log_info "${RED}✗${NC} Blacklisted: ${match#$WORKING_DIR/}"
                fi
            done
        else
            log_info "${YELLOW}⚠${NC} No matches for pattern: $pattern"
        fi
    done < "$BLACKLIST_FILE"
fi

# Bind claude binary
if [[ -x "$HOME/.local/bin/claude" ]]; then
    BWRAP_ARGS+=(--ro-bind "$HOME/.local/bin/claude" "$HOME/.local/bin/claude")
    log_info "${GREEN}✓${NC} Mounted ~/.local/bin/claude (read-only)"
fi

# Bind ~/.claude directory (main config location)
if [[ -d "$HOME/.claude" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude" "$HOME/.claude")
    log_info "${GREEN}✓${NC} Mounted ~/.claude (read-write)"
fi

# Bind ~/.claude.json file (state file in home directory)
if [[ -f "$HOME/.claude.json" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    log_info "${GREEN}✓${NC} Mounted ~/.claude.json (read-write)"
else
    # Create empty file if it doesn't exist so Claude can write to it
    touch "$HOME/.claude.json"
    BWRAP_ARGS+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    log_info "${YELLOW}✓${NC} Created and mounted ~/.claude.json (read-write)"
fi

# Bind ~/.claude.json.backup if it exists
if [[ -f "$HOME/.claude.json.backup" ]]; then
    BWRAP_ARGS+=(--bind "$HOME/.claude.json.backup" "$HOME/.claude.json.backup")
fi

BWRAP_ARGS+=(--setenv HOME "$HOME")
BWRAP_ARGS+=(--setenv PWD "$WORKING_DIR")
BWRAP_ARGS+=(--chdir "$WORKING_DIR")

# Network namespace isolation
USE_SLIRP4NETNS=false
if [[ "$ALLOW_LOCAL_NET" = false ]]; then
    log_info "\n${GREEN}Network restrictions active - blocking local networks${NC}"

    # Check if slirp4netns is available for internet-only access (using cached value)
    if [[ -n "$SLIRP4NETNS_BIN" ]]; then
        log_info "${GREEN}Using slirp4netns for internet-only access (localhost blocked)${NC}"
        USE_SLIRP4NETNS=true

        # Configure DNS for slirp4netns
        TEMP_RESOLV=$(mktemp)
        echo "nameserver 10.0.2.3" > "$TEMP_RESOLV"  # slirp4netns default DNS
        BWRAP_ARGS+=(--ro-bind "$TEMP_RESOLV" /etc/resolv.conf)
        trap 'rm -rf $TEMP_RESOLV' EXIT

        # Add minimal /etc/hosts
        TEMP_HOSTS=$(mktemp)
        cat > "$TEMP_HOSTS" << 'EOHOSTS'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOHOSTS
        BWRAP_ARGS+=(--ro-bind "$TEMP_HOSTS" /etc/hosts)
        trap 'rm -rf $TEMP_RESOLV $TEMP_HOSTS' EXIT
    else
        log_info "${YELLOW}slirp4netns not found - using complete network isolation${NC}"
        log_info "${YELLOW}No network access (including internet) in sandbox${NC}"
        log_info "${YELLOW}Install slirp4netns for internet-only access, or use --allow-local-net${NC}"
    fi
else
    log_info "\n${YELLOW}Warning: Local network access is ALLOWED${NC}"
    # Share the network namespace to allow all network access
    BWRAP_ARGS+=(--share-net)

    # Use system resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
    fi

    # Bind /etc/hosts for name resolution
    if [[ -f /etc/hosts ]]; then
        BWRAP_ARGS+=(--ro-bind /etc/hosts /etc/hosts)
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
log_info "\n${GREEN}=== Claude Code Sandbox Configuration ===${NC}"
log_info "Working Directory: ${YELLOW}$WORKING_DIR${NC}"
log_info "Whitelist File: ${YELLOW}$WHITELIST_FILE${NC}"
log_info "Blacklist File: ${YELLOW}$BLACKLIST_FILE${NC}"
log_info "Local Network: ${YELLOW}$(if $ALLOW_LOCAL_NET; then echo 'ALLOWED'; else echo 'BLOCKED'; fi)${NC}"
log_info "${GREEN}=========================================${NC}\n"

# Execute Claude Code in sandbox with optional slirp4netns
if [[ "$USE_SLIRP4NETNS" = true ]]; then
    # Create a wrapper script that will be executed inside the sandbox
    WRAPPER_SCRIPT=$(mktemp)
    cat > "$WRAPPER_SCRIPT" << 'EOWRAPPER'
#!/bin/bash
# Wait for network to be ready (slirp4netns needs time to attach)
# Optimized: faster polling with reduced total wait time
for i in {1..100}; do
    if ip link show tap0 &>/dev/null 2>&1; then
        break
    fi
    sleep 0.02
done
# Execute Claude Code
exec "$@"
EOWRAPPER
    chmod +x "$WRAPPER_SCRIPT"
    trap 'rm -rf $WRAPPER_SCRIPT $TEMP_RESOLV $TEMP_HOSTS' EXIT

    # Enable job control to allow foregrounding
    set -m

    # Run bwrap in background to get PID for slirp4netns
    "$BWRAP_BIN" "${BWRAP_ARGS[@]}" \
        --ro-bind "$WRAPPER_SCRIPT" /tmp/wrapper.sh \
        -- \
        /tmp/wrapper.sh "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" &

    BWRAP_PID=$!

    # Reduced delay for faster startup (namespace creation is usually instant)
    sleep 0.05

    # Attach slirp4netns to the sandbox
    # Use --disable-host-loopback to prevent connections to 127.0.0.1 on the host
    "$SLIRP4NETNS_BIN" --configure --mtu=65520 --disable-host-loopback "$BWRAP_PID" tap0 >/dev/null 2>&1 &
    SLIRP_PID=$!

    # Cleanup function
    cleanup_slirp() {
        kill "$SLIRP_PID" 2>/dev/null || true
        kill "$BWRAP_PID" 2>/dev/null || true
        wait "$SLIRP_PID" 2>/dev/null || true
        wait "$BWRAP_PID" 2>/dev/null || true
        rm -rf "$WRAPPER_SCRIPT" "$TEMP_RESOLV" "$TEMP_HOSTS"
    }
    trap cleanup_slirp EXIT INT TERM

    # Bring bwrap back to foreground to restore TTY access
    fg %1 1>/dev/null
    EXIT_CODE=$?

    # Cleanup
    kill "$SLIRP_PID" 2>/dev/null || true
    wait "$SLIRP_PID" 2>/dev/null || true

    exit "$EXIT_CODE"
else
    # Execute directly without slirp4netns
    exec "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}"
fi
