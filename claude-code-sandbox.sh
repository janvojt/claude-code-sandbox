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
WORKING_DIR="$(pwd)"
PROJECT_WHITELIST_FILE="$WORKING_DIR/.claude/whitelist.txt"
PROJECT_BLACKLIST_FILE="$WORKING_DIR/.claude/blacklist.txt"
WHITELIST_FILES=()
BLACKLIST_FILES=()
WHITELIST_PATHS_RO=()
WHITELIST_PATHS_RW=()
BLACKLIST_PATHS=()
EXPLICIT_WHITELIST=false
EXPLICIT_BLACKLIST=false
QUIET=false
DRY_RUN=false
AGENT="claudecode"

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [-- AGENT_ARGS...]

Securely run AI coding agents in a sandboxed environment using bubblewrap.

OPTIONS:
    --agent, -a AGENT      AI coding agent to use: claudecode (default) or opencode
    --whitelist FILE        Add whitelist file (can be specified multiple times)
    --blacklist FILE        Add blacklist file (can be specified multiple times)
    --whitelist-path PATH   Directly whitelist a path (read-only, can be specified multiple times)
    --whitelist-path-rw PATH Directly whitelist a path (read-write, can be specified multiple times)
    --blacklist-path PATH   Directly blacklist a path (relative to working dir, can be specified multiple times)
    --dry-run              Start bash shell instead of agent (for testing)
    --quiet, -q            Suppress informational output (faster startup)
    --verbose, -v          Show detailed output (default)
    -h, --help             Show this help message

IMPLICIT CONFIGURATION FILES (automatically included if they exist):
    1. User-level (always):
       - $DEFAULT_WHITELIST_FILE
       - $DEFAULT_BLACKLIST_FILE
    2. Project-level (if present):
       - .claude/whitelist.txt (in working directory)
       - .claude/blacklist.txt (in working directory)

CONFIGURATION FILE FORMAT:
    Whitelist: Contains absolute or relative paths/patterns (one per line) that Claude can read
               Relative paths are resolved relative to working directory
               Default: read-only bind mount
               Suffix with :rw for read-write bind (e.g., /path/to/dir:rw or data/:rw)
               Supports glob patterns: /etc/java* or src/** will expand to all matching paths
    Blacklist: Contains paths relative to working directory that Claude cannot access

EXAMPLES:
    $0
    $0 --agent opencode
    $0 --whitelist /path/to/custom-whitelist.txt
    $0 --whitelist file1.txt --whitelist file2.txt
    $0 --whitelist-path /var/run/docker.sock
    $0 --whitelist-path-rw /shared/data
    $0 --blacklist-path .env --blacklist-path secrets/
    $0 -- --model claude-sonnet-4-5
    $0 -a opencode -- --model deepseek-chat

EOF
    exit 1
}

# Parse command line arguments
AGENT_ARGS=()
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
        --blacklist-path)
            BLACKLIST_PATHS+=("$2")
            EXPLICIT_BLACKLIST=true
            shift 2
            ;;
        --whitelist-path)
            WHITELIST_PATHS_RO+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --whitelist-path-rw)
            WHITELIST_PATHS_RW+=("$2")
            EXPLICIT_WHITELIST=true
            shift 2
            ;;
        --agent|-a)
            AGENT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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
            AGENT_ARGS=("$@")
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

# Strip inline comments and trim whitespace from a line
# Usage: result=$(strip_inline_comment "$line")
strip_inline_comment() {
    local line="$1"
    # Strip inline comments (anything after #)
    line="${line%%#*}"
    # Trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    # Trim trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"
    echo "$line"
}

# Find matches for a pattern (supports ant-style ** patterns)
# Usage: find_matches <base_dir> <pattern>
# Returns: list of matching absolute paths (one per line)
find_matches() {
    local base_dir="$1"
    local pattern="$2"
    local find_args=()

    # If no pattern, just return the base_dir itself (literal path)
    if [[ -z "$pattern" ]]; then
        echo "$base_dir"
        return
    fi

    # Convert ant-style pattern to find command
    if [[ "$pattern" == *"**"* ]]; then
        # Ant-style recursive pattern
        # Extract the filename part after the last **
        if [[ "$pattern" =~ \*\*/([^/]+)$ ]]; then
            # Pattern like **/wallet.dat or src/**/wallet.dat
            local filename="${BASH_REMATCH[1]}"
            find_args=(-name "$filename")
        else
            # Complex pattern like src/**/test/**/*.java
            # Convert ** to */ for path matching
            local path_pattern="${pattern//\*\*/\*}"
            find_args=(-path "$base_dir/$path_pattern")
        fi
    else
        # Simple glob pattern - limit to single level
        if [[ "$pattern" == */* ]]; then
            # Pattern has directory components like dir/*.txt
            local path_pattern="$pattern"
            find_args=(-path "$base_dir/$path_pattern")
        else
            # Simple filename pattern like *.txt
            find_args=(-maxdepth 1 -name "$pattern")
        fi
    fi

    # Execute find and return results
    find "$base_dir" "${find_args[@]}" 2>/dev/null
}

# Whitelist a single path (with glob and ant-style pattern support)
# Usage: whitelist_path <path> <bind_mode>
# bind_mode: "ro" for read-only, "rw" for read-write
# Supports both absolute paths and relative paths (relative to working directory)
whitelist_path() {
    local path="$1"
    local bind_mode="$2"

    # Expand environment variables without eval (faster)
    path="${path/#\~/$HOME}"
    path="${path//\$HOME/$HOME}"

    # Convert relative paths to absolute (relative to working directory)
    if [[ "$path" != /* ]]; then
        path="$WORKING_DIR/$path"
    fi

    # Use find for all paths (patterns and literals)
    local base_dir="/"
    local pattern="$path"

    # Extract base directory if path starts with absolute path
    if [[ "$path" == /* ]]; then
        # For patterns, find the first directory component before any wildcard
        if [[ "$path" =~ [\*\?\[]|\*\* ]]; then
            local prefix="${path%%[*?[]*}"
            if [[ -d "$prefix" ]]; then
                base_dir="$prefix"
                pattern="${path#$prefix}"
                pattern="${pattern#/}"
            fi
        else
            # For literal paths, use the path itself as base_dir
            base_dir="$path"
            pattern=""
        fi
    fi

    local match_count=0
    while IFS= read -r match; do
        if [[ -e "$match" ]]; then
            if [[ "$bind_mode" = "rw" ]]; then
                BWRAP_ARGS+=(--bind "$match" "$match")
                log_info "${GREEN}✓${NC} Whitelisted (rw): $match"
            else
                BWRAP_ARGS+=(--ro-bind "$match" "$match")
                log_info "${GREEN}✓${NC} Whitelisted: $match"
            fi
            ((match_count++)) || true
        fi
    done < <(find_matches "$base_dir" "$pattern")

    if [[ $match_count -eq 0 ]]; then
        log_info "${YELLOW}⚠${NC} No matches for pattern: $path"
    fi
}

# Blacklist a single pattern (relative to working directory, supports ant-style patterns)
# Usage: blacklist_pattern <pattern>
blacklist_pattern() {
    local pattern="$1"

    # Use find to match patterns (supports ant-style **)
    local match_count=0
    while IFS= read -r match; do
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
            ((match_count++)) || true
        fi
    done < <(find_matches "$WORKING_DIR" "$pattern")

    if [[ $match_count -eq 0 ]]; then
        log_info "${YELLOW}⚠${NC} No matches for pattern: $pattern"
    fi
}

# Validate agent selection
if [[ "$AGENT" != "claudecode" ]] && [[ "$AGENT" != "opencode" ]]; then
    echo -e "${RED}Error: Invalid agent '$AGENT'. Must be 'claudecode' or 'opencode'${NC}" >&2
    exit 1
fi

# Cache command availability checks
BWRAP_BIN=$(command -v bwrap 2>/dev/null)

# Check if bubblewrap is installed
if [[ -z "$BWRAP_BIN" ]]; then
    echo -e "${RED}Error: bubblewrap (bwrap) is not installed${NC}" >&2
    echo "Install it with: sudo apt install bubblewrap (Debian/Ubuntu) or sudo dnf install bubblewrap (Fedora)" >&2
    exit 1
fi

# Detect agent binary based on selection
if [[ "$AGENT" = "claudecode" ]]; then
    AGENT_BIN=$(command -v claude 2>/dev/null)
    if [[ -z "$AGENT_BIN" ]]; then
        echo -e "${RED}Error: claude is not installed${NC}" >&2
        echo "Install it from: https://docs.claude.com/en/docs/claude-code" >&2
        exit 1
    fi
elif [[ "$AGENT" = "opencode" ]]; then
    AGENT_BIN="$HOME/.opencode/bin/opencode"
    if [[ ! -x "$AGENT_BIN" ]]; then
        echo -e "${RED}Error: opencode is not installed at $AGENT_BIN${NC}" >&2
        echo "Install it from: https://opencode.dev" >&2
        exit 1
    fi
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
**/.env

# SSH and crypto keys
**/.ssh
**/*.pem
**/*.key
**/id_rsa
**/id_ed25519
**/*.p12
**/*.pfx

# AWS credentials
**/.aws/credentials

# Docker and Kubernetes secrets
**/docker-compose.override.yml
**/.kube/config

# Password managers
**/*.kdbx
**/*.agilekeychain
**/.vault_password

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

# Include project-level files if they exist (after default, before explicit)
if [[ -f "$PROJECT_WHITELIST_FILE" ]]; then
    WHITELIST_FILES+=("$PROJECT_WHITELIST_FILE")
fi
if [[ -f "$PROJECT_BLACKLIST_FILE" ]]; then
    BLACKLIST_FILES+=("$PROJECT_BLACKLIST_FILE")
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

# Setup minimal home directory using tmpfs
BWRAP_ARGS+=(--tmpfs "$HOME")

# Bind working directory (after tmpfs home, so it's visible)
BWRAP_ARGS+=(--bind "$WORKING_DIR" "$WORKING_DIR")

# Process all whitelist files and add to bubblewrap (after tmpfs so HOME paths work)
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

        line=$(strip_inline_comment "$line")
        [[ -z "$line" ]] && continue

        # Check for read-write suffix (:rw)
        bind_mode="ro"
        if [[ "$line" =~ :rw$ ]]; then
            bind_mode="rw"
            line="${line%:rw}"  # Strip :rw suffix
        fi

        # Process the path using the helper function
        whitelist_path "$line" "$bind_mode"
    done < "$WHITELIST_FILE"
done

# Process direct whitelist paths (read-only)
if [[ ${#WHITELIST_PATHS_RO[@]} -gt 0 ]]; then
    log_info "${GREEN}Processing direct whitelist paths (read-only):${NC}"
    for path in "${WHITELIST_PATHS_RO[@]}"; do
        whitelist_path "$path" "ro"
    done
fi

# Process direct whitelist paths (read-write)
if [[ ${#WHITELIST_PATHS_RW[@]} -gt 0 ]]; then
    log_info "${GREEN}Processing direct whitelist paths (read-write):${NC}"
    for path in "${WHITELIST_PATHS_RW[@]}"; do
        whitelist_path "$path" "rw"
    done
fi

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

            pattern=$(strip_inline_comment "$pattern")
            [[ -z "$pattern" ]] && continue

            # Process the pattern using the helper function
            blacklist_pattern "$pattern"
        done < "$BLACKLIST_FILE"
    done
fi

# Process direct blacklist paths
if [[ ${#BLACKLIST_PATHS[@]} -gt 0 ]]; then
    log_info "\n${YELLOW}Processing direct blacklist paths:${NC}"
    for pattern in "${BLACKLIST_PATHS[@]}"; do
        blacklist_pattern "$pattern"
    done
fi

# Agent-specific configuration bindings
if [[ "$AGENT" = "claudecode" ]]; then
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
elif [[ "$AGENT" = "opencode" ]]; then
    # Bind opencode binary and directory
    if [[ -d "$HOME/.opencode" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.opencode" "$HOME/.opencode")
        log_info "${GREEN}✓${NC} Mounted ~/.opencode (read-write)"
    fi

    # Bind ~/.opencode.json file (state file in home directory)
    if [[ -f "$HOME/.opencode.json" ]]; then
        BWRAP_ARGS+=(--bind "$HOME/.opencode.json" "$HOME/.opencode.json")
        log_info "${GREEN}✓${NC} Mounted ~/.opencode.json (read-write)"
    else
        # Create empty file if it doesn't exist so opencode can write to it
        touch "$HOME/.opencode.json"
        BWRAP_ARGS+=(--bind "$HOME/.opencode.json" "$HOME/.opencode.json")
        log_info "${YELLOW}✓${NC} Created and mounted ~/.opencode.json (read-write)"
    fi
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
if [[ "$AGENT" = "claudecode" ]]; then
    BWRAP_ARGS+=(--setenv PATH "$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin")
elif [[ "$AGENT" = "opencode" ]]; then
    BWRAP_ARGS+=(--setenv PATH "$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin")
fi
BWRAP_ARGS+=(--unsetenv SSH_AUTH_SOCK)
BWRAP_ARGS+=(--unsetenv SSH_AGENT_PID)

# Preserve agent-specific environment variables
if [[ "$AGENT" = "claudecode" ]]; then
    if [[ -n "${CLAUDECODE:-}" ]]; then
        BWRAP_ARGS+=(--setenv CLAUDECODE "$CLAUDECODE")
    fi
    if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
        BWRAP_ARGS+=(--setenv CLAUDE_CODE_ENTRYPOINT "$CLAUDE_CODE_ENTRYPOINT")
    fi
fi

# Display configuration summary
log_info "\n${GREEN}=== AI Coding Agent Sandbox Configuration ===${NC}"
log_info "Agent: ${YELLOW}$AGENT${NC}"
log_info "Working Directory: ${YELLOW}$WORKING_DIR${NC}"
log_info "Whitelist Files (${#WHITELIST_FILES[@]}):"
for wfile in "${WHITELIST_FILES[@]}"; do
    log_info "  ${YELLOW}$wfile${NC}"
done
log_info "Blacklist Files (${#BLACKLIST_FILES[@]}):"
for bfile in "${BLACKLIST_FILES[@]}"; do
    log_info "  ${YELLOW}$bfile${NC}"
done
log_info "${GREEN}=============================================${NC}\n"

# Execute agent or bash (for dry-run) in sandbox
if [[ "$DRY_RUN" = true ]]; then
    log_info "${YELLOW}=== DRY RUN MODE: Starting bash shell in sandbox ===${NC}\n"
    exec "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- /bin/bash
else
    exec "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$AGENT_BIN" "${AGENT_ARGS[@]}"
fi
