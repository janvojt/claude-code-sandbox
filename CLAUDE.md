# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a bash-based sandboxing solution for running Claude Code in isolated environments using **bubblewrap**. The script (`claude-code-sandbox.sh`) provides filesystem isolation via whitelist/blacklist. Full network access (both local and internet) is enabled.

## Architecture

### Core Components

**Main Script: `claude-code-sandbox.sh`**
- Single executable bash script that wraps Claude Code in a bubblewrap sandbox
- Implements two-tier filesystem access control:
  1. **Whitelist**: Absolute system paths Claude can read (default: `~/.config/claude-sandbox/whitelist.txt`)
  2. **Blacklist**: Relative working directory paths Claude cannot access (default: `~/.config/claude-sandbox/blacklist.txt`)
- Network configuration:
  - Full network access enabled (both local and internet)
  - Uses `--share-net` to share host network namespace

### Key Design Patterns

**Filesystem Isolation Strategy (lines 236-262)**:
- Uses **tmpfs overlays** to hide blacklisted paths
- Working directory is bind-mounted read-write at line 234
- Blacklisted patterns expanded via `compgen -G` and hidden with `--tmpfs` mounts
- This means blacklist patterns are expanded at sandbox start time, not dynamically
- Unlike overlay filesystems, this doesn't copy files - just hides matching paths

**Network Configuration (lines 288-302)**:
- Full network access enabled by default
- Uses `--share-net` to share host network namespace
- Binds system `/etc/resolv.conf` and `/etc/hosts` for DNS resolution

**Configuration Resolution Order**:
1. Command-line arguments (`--whitelist`, `--blacklist`)
2. Environment variables (`CLAUDE_SANDBOX_WHITELIST`, `CLAUDE_SANDBOX_BLACKLIST`)
3. Default locations (`~/.config/claude-sandbox/{whitelist,blacklist}.txt`)
4. Auto-generated defaults if files don't exist (lines 110-188)

**Bubblewrap Namespace Setup (lines 191-205)**:
- `--unshare-all` creates isolated namespaces (PID, IPC, UTS, cgroup, etc.) but network is shared
- `--die-with-parent` ensures sandbox terminates if parent dies
- Minimal read-only mounts: `/proc`, `/dev`, `/sys`
- tmpfs for `/tmp` and `$HOME` (lines 201, 230)
- SSH agent is explicitly disabled via `--unsetenv SSH_AUTH_SOCK` (line 307)

**Claude Code Configuration Binding (lines 264-285)**:
- Binds `~/.local/bin/claude` as read-only if exists
- Binds `~/.claude/` directory read-write for config
- Binds/creates `~/.claude.json` for state persistence
- Preserves Claude-specific environment variables (lines 311-316)

## Development Commands

### Testing the Script

```bash
# Run in current directory with default settings (full network access)
./claude-code-sandbox.sh

# Test with custom configurations
./claude-code-sandbox.sh \
  --whitelist ./whitelist-example.txt \
  --blacklist ./blacklist-example.txt

# Pass arguments to underlying Claude Code
./claude-code-sandbox.sh -- --model claude-sonnet-4-5
```

### Script Validation

```bash
# Check bash syntax
bash -n claude-code-sandbox.sh

# Check for common issues with shellcheck (if available)
shellcheck claude-code-sandbox.sh
```

## Important Implementation Details

### Security Considerations

**Network Access**:
- Full network access is enabled (both local and internet)
- The sandbox shares the host network namespace via `--share-net`
- System DNS configuration is used for name resolution

**Blacklist Implementation** (lines 236-262):
- Uses tmpfs mounts to hide paths (no file copying)
- Glob patterns in blacklist are expanded at start time using `compgen -G`
- Pattern matching happens against `$WORKING_DIR/$pattern`
- Non-matching patterns generate warnings but don't fail

**Whitelist Implementation** (lines 208-224):
- Each path validated with `[[ -e "$path" ]]` before binding
- Environment variable expansion (e.g., `$HOME`, `~`)
- Non-existent paths are skipped with warning, not errors
- All whitelist paths bound read-only via `--ro-bind`

### Configuration File Format

**Whitelist** (absolute paths, lines 208-224):
- One path per line
- Environment variable expansion supported: `$HOME` or `~`
- Paths are validated before binding - non-existent paths are skipped
- Comments start with `#`
- Empty lines ignored

**Blacklist** (relative paths, lines 236-262):
- Paths relative to working directory
- Glob patterns supported (`*`, `?`)
- Patterns expanded using bash `compgen -G`
- Comments start with `#`
- Empty lines ignored

## Modifying the Script

### Adding New Command-Line Options

Options are parsed in the `while` loop at lines 48-76. Pattern:
```bash
--your-option)
    YOUR_VAR="$2"
    shift 2
    ;;
```

### Extending Bubblewrap Arguments

Add to `BWRAP_ARGS` array (initialized at line 191):
```bash
BWRAP_ARGS+=(--ro-bind /your/path /your/path)
```

### Network Configuration

Network setup is at lines 288-302:
- Uses `--share-net` to share host network namespace
- Binds `/etc/resolv.conf` for DNS resolution
- Binds `/etc/hosts` for hostname resolution

### Adding Claude Configuration Mounts

Claude Code needs specific paths (lines 264-285):
- Binary: `~/.local/bin/claude` (read-only)
- Config directory: `~/.claude/` (read-write)
- State file: `~/.claude.json` (read-write, auto-created if missing)

When adding mounts, remember:
- Bind after `--tmpfs "$HOME"` (line 230) or they'll be hidden
- Use `--ro-bind` for read-only, `--bind` for read-write
- Non-existent paths should be checked before binding

## Testing Checklist

When modifying the script:
1. Test with non-existent whitelist/blacklist files (should auto-generate)
2. Test with empty working directory
3. Test with glob patterns in blacklist (`*.env`, `.secrets/*`)
4. Test with environment variable expansion in whitelist (`$HOME/.local`)
5. Verify cleanup on clean exit and interrupt (Ctrl+C)
6. Test network access (both local and internet should work)
7. Test Claude Code can still access its config: check `~/.claude/` and `~/.claude.json`

## Files in Repository

- `claude-code-sandbox.sh` - Main executable script (~327 lines)
- `README.md` - User-facing documentation
- `whitelist-example.txt` - Example whitelist configuration
- `blacklist-example.txt` - Example blacklist configuration
- `.gitignore` - Git ignore patterns
