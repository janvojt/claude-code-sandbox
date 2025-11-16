#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
DEFAULT_WHITELIST_FILE="${CLAUDE_SANDBOX_WHITELIST:-$HOME/.config/claude-sandbox/whitelist.txt}"
DEFAULT_BLACKLIST_FILE="${CLAUDE_SANDBOX_BLACKLIST:-$HOME/.config/claude-sandbox/blacklist.txt}"
WHITELIST_FILES=()
BLACKLIST_FILES=()
EXPLICIT_WHITELIST=false
EXPLICIT_BLACKLIST=false
QUIET=false
WORKING_DIR="$(pwd)"

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [-- CLAUDE_ARGS...]

Securely run Claude Code in a sandboxed environment using bubblewrap.

OPTIONS:
    --whitelist FILE        Add whitelist file (can be specified multiple times)
                           Default file is always included: $DEFAULT_WHITELIST_FILE
    --blacklist FILE        Add blacklist file (can be specified multiple times)
                           Default file is always included: $DEFAULT_BLACKLIST_FILE
    --quiet, -q            Suppress informational output (faster startup)
    --verbose, -v          Show detailed output (default)
    -h, --help             Show this help message

CONFIGURATION FILES:
    Whitelist: Contains absolute paths (one per line) that Claude can read
    Blacklist: Contains paths relative to working directory that Claude cannot access

EXAMPLES:
    $0
    $0 --whitelist /path/to/custom-whitelist.txt
    $0 --whitelist file1.txt --whitelist file2.txt
    $0 -- --model claude-sonnet-4-5

EOF
    exit 1
}

# Parse command line arguments
CLAUDE_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --whitelist)
            WHITELIST_FILES+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --blacklist)
            BLACKLIST_FILES+=("$2")
            EXPLICIT_BLACKLIST=true
            shift 2
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

# Create default whitelist if it doesn't exist and no explicit whitelist was given
if [[ ! -f "$DEFAULT_WHITELIST_FILE" ]] && [[ "$EXPLICIT_WHITELIST" = false ]]; then
    echo -e "${YELLOW}Warning: Whitelist file not found at $DEFAULT_WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default whitelist...${NC}" >&2
    mkdir -p "$(dirname "$DEFAULT_WHITELIST_FILE")"
    cat > "$DEFAULT_WHITELIST_FILE" << 'EOWHITELIST'
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
    echo -e "${GREEN}Created default whitelist at $DEFAULT_WHITELIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Create default blacklist if it doesn't exist and no explicit blacklist was given
if [[ ! -f "$DEFAULT_BLACKLIST_FILE" ]] && [[ "$EXPLICIT_BLACKLIST" = false ]]; then
    echo -e "${YELLOW}Warning: Blacklist file not found at $DEFAULT_BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Creating default blacklist...${NC}" >&2
    mkdir -p "$(dirname "$DEFAULT_BLACKLIST_FILE")"
    cat > "$DEFAULT_BLACKLIST_FILE" << 'EOBLACKLIST'
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
    echo -e "${GREEN}Created default blacklist at $DEFAULT_BLACKLIST_FILE${NC}" >&2
    echo -e "${YELLOW}Please review and customize it for your needs${NC}" >&2
fi

# Always include default files in the arrays (at the beginning)
if [[ -f "$DEFAULT_WHITELIST_FILE" ]]; then
    WHITELIST_FILES=("$DEFAULT_WHITELIST_FILE" "${WHITELIST_FILES[@]}")
fi
if [[ -f "$DEFAULT_BLACKLIST_FILE" ]]; then
    BLACKLIST_FILES=("$DEFAULT_BLACKLIST_FILE" "${BLACKLIST_FILES[@]}")
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

# Process all whitelist files and add to bubblewrap
if [[ ${#WHITELIST_FILES[@]} -eq 0 ]]; then
    echo -e "${RED}Error: No whitelist files found${NC}" >&2
    exit 1
fi

for WHITELIST_FILE in "${WHITELIST_FILES[@]}"; do
    if [[ ! -f "$WHITELIST_FILE" ]]; then
        echo -e "${YELLOW}Warning: Whitelist file not found: $WHITELIST_FILE (skipping)${NC}" >&2
        continue
    fi

    log_info "${GREEN}Processing whitelist:${NC} $WHITELIST_FILE"

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
done

# Setup minimal home directory using tmpfs
BWRAP_ARGS+=(--tmpfs "$HOME")

# Bind working directory (after tmpfs home, so it's visible)
BWRAP_ARGS+=(--bind "$WORKING_DIR" "$WORKING_DIR")

# Process all blacklist files and hide patterns with tmpfs overlays
if [[ ${#BLACKLIST_FILES[@]} -gt 0 ]]; then
    log_info "\n${YELLOW}Processing blacklist patterns:${NC}"
    for BLACKLIST_FILE in "${BLACKLIST_FILES[@]}"; do
        if [[ ! -f "$BLACKLIST_FILE" ]]; then
            log_info "${YELLOW}Warning: Blacklist file not found: $BLACKLIST_FILE (skipping)${NC}"
            continue
        fi

        log_info "${YELLOW}Processing blacklist:${NC} $BLACKLIST_FILE"

        while IFS= read -r pattern || [[ -n "$pattern" ]]; do
            [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${pattern// }" ]] && continue

            # Find matching files/directories in working directory
            if compgen -G "$WORKING_DIR/$pattern" > /dev/null 2>&1; then
                for match in "$WORKING_DIR"/$pattern; do
                    if [[ -e "$match" ]]; then
                        if [[ -d "$match" ]]; then
                            # Hide directories with tmpfs overlay
                            BWRAP_ARGS+=(--tmpfs "$match")
                            log_info "${RED}✗${NC} Blacklisted (dir): ${match#$WORKING_DIR/}"
                        else
                            # Hide files by binding /dev/null over them
                            BWRAP_ARGS+=(--ro-bind /dev/null "$match")
                            log_info "${RED}✗${NC} Blacklisted (file): ${match#$WORKING_DIR/}"
                        fi
                    fi
                done
            else
                log_info "${YELLOW}⚠${NC} No matches for pattern: $pattern"
            fi
        done < "$BLACKLIST_FILE"
    done
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

# Network configuration - allow all network access
log_info "\n${GREEN}Network: Full access enabled (local and internet)${NC}"

# Share the network namespace to allow all network access
BWRAP_ARGS+=(--share-net)

# Use system DNS configuration
if [[ -f /etc/resolv.conf ]]; then
    BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
fi

# Bind /etc/hosts for name resolution
if [[ -f /etc/hosts ]]; then
    BWRAP_ARGS+=(--ro-bind /etc/hosts /etc/hosts)
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
log_info "Whitelist Files (${#WHITELIST_FILES[@]}):"
for wfile in "${WHITELIST_FILES[@]}"; do
    log_info "  ${YELLOW}$wfile${NC}"
done
log_info "Blacklist Files (${#BLACKLIST_FILES[@]}):"
for bfile in "${BLACKLIST_FILES[@]}"; do
    log_info "  ${YELLOW}$bfile${NC}"
done
log_info "${GREEN}=========================================${NC}\n"

# Execute Claude Code in sandbox
exec "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}"
