# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a bash-based sandboxing solution for running Claude Code in isolated environments using **bubblewrap**. The script (`claude-code-sandbox.sh`) provides filesystem isolation via whitelist/blacklist and network restrictions.

## Architecture

### Core Components

**Main Script: `claude-code-sandbox.sh`**
- Single executable bash script that wraps Claude Code in a bubblewrap sandbox
- Implements two-tier filesystem access control:
  1. **Whitelist**: Absolute system paths Claude can read (default: `~/.config/claude-sandbox/whitelist.txt`)
  2. **Blacklist**: Relative working directory paths Claude cannot access (default: `~/.config/claude-sandbox/blacklist.txt`)
- Network isolation with three modes:
  1. **Default (slirp4netns)**: Internet-only access, localhost blocked
  2. **Fallback**: Complete network isolation if slirp4netns unavailable
  3. **--allow-local-net**: Full network access including localhost

### Key Design Patterns

**Filesystem Isolation Strategy (lines 214-235)**:
- Uses **tmpfs overlays** to hide blacklisted paths
- Working directory is bind-mounted read-write at line 212
- Blacklisted patterns expanded via `compgen -G` and hidden with `--tmpfs` mounts
- This means blacklist patterns are expanded at sandbox start time, not dynamically
- Unlike overlay filesystems, this doesn't copy files - just hides matching paths

**Network Isolation Modes (lines 270-402)**:
1. **slirp4netns mode** (lines 340-398):
   - Provides internet access while blocking localhost connections
   - Uses `--disable-host-loopback` flag to prevent host access
   - Wrapper script with readiness polling ensures network is configured
   - Background process coordination with proper cleanup traps

2. **Complete isolation** (fallback when slirp4netns unavailable):
   - No network access at all
   - User notified to install slirp4netns or use `--allow-local-net`

3. **Full network access** (lines 298-312):
   - Uses `--share-net` to share host network namespace
   - Binds system `/etc/resolv.conf` and `/etc/hosts`

**Configuration Resolution Order**:
1. Command-line arguments (`--whitelist`, `--blacklist`)
2. Environment variables (`CLAUDE_SANDBOX_WHITELIST`, `CLAUDE_SANDBOX_BLACKLIST`)
3. Default locations (`~/.config/claude-sandbox/{whitelist,blacklist}.txt`)
4. Auto-generated defaults if files don't exist (lines 90-167)

**Bubblewrap Namespace Setup (lines 170-184)**:
- `--unshare-all` creates isolated namespaces (PID, IPC, UTS, cgroup, etc.)
- `--die-with-parent` ensures sandbox terminates if parent dies
- Minimal read-only mounts: `/proc`, `/dev`, `/sys`
- tmpfs for `/tmp` and `$HOME` (lines 180, 209)
- SSH agent is explicitly disabled via `--unsetenv SSH_AUTH_SOCK` (line 317)

**Claude Code Configuration Binding (lines 238-263)**:
- Binds `~/.local/bin/claude` as read-only if exists
- Binds `~/.claude/` directory read-write for config
- Binds/creates `~/.claude.json` for state persistence
- Preserves Claude-specific environment variables (lines 321-326)

## Development Commands

### Testing the Script

```bash
# Run in current directory with default settings (internet-only via slirp4netns)
./claude-code-sandbox.sh

# Test with local network access (for Docker, local servers, etc.)
./claude-code-sandbox.sh --allow-local-net

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

**Network Blocking**:
- **slirp4netns mode** (default): Provides internet access via user-mode networking while blocking localhost via `--disable-host-loopback`
- This is more sophisticated than DNS-level blocking - localhost connections fail at the network layer
- Direct IP connections to 127.0.0.1 are blocked when using slirp4netns
- For complete network isolation, simply don't install slirp4netns

**Blacklist Implementation** (lines 214-235):
- Uses tmpfs mounts to hide paths (no file copying)
- Glob patterns in blacklist are expanded at start time using `compgen -G`
- Pattern matching happens against `$WORKING_DIR/$pattern`
- Non-matching patterns generate warnings but don't fail

**Whitelist Implementation** (lines 187-206):
- Each path validated with `[[ -e "$path" ]]` before binding
- Environment variable expansion via `eval echo "$line"`
- Non-existent paths are skipped with warning, not errors
- All whitelist paths bound read-only via `--ro-bind`

### slirp4netns Process Coordination

The script uses sophisticated process management when slirp4netns is available (lines 340-398):

1. **Wrapper script approach**: Creates temporary wrapper (`/tmp/wrapper.sh`) that polls for network readiness
2. **Background execution**: Runs bwrap in background to get PID for slirp4netns attachment
3. **Timing coordination**: 0.3s delay ensures namespace exists before slirp4netns attaches
4. **Cleanup handlers**: Trap function `cleanup_slirp()` kills both bwrap and slirp4netns processes
5. **Exit code preservation**: Captures bwrap exit code and returns it correctly

### Configuration File Format

**Whitelist** (absolute paths, lines 187-206):
- One path per line
- Environment variable expansion supported: `$HOME` or `${HOME}`
- Paths are validated before binding - non-existent paths are skipped
- Comments start with `#`
- Empty lines ignored

**Blacklist** (relative paths, lines 214-235):
- Paths relative to working directory
- Glob patterns supported (`*`, `?`)
- Patterns expanded using bash `compgen -G`
- Comments start with `#`
- Empty lines ignored

## Modifying the Script

### Adding New Command-Line Options

Options are parsed in the `while` loop at lines 45-73. Pattern:
```bash
--your-option)
    YOUR_VAR="$2"
    shift 2
    ;;
```

### Extending Bubblewrap Arguments

Add to `BWRAP_ARGS` array (initialized at line 170):
```bash
BWRAP_ARGS+=(--ro-bind /your/path /your/path)
```

### Customizing Network Restrictions

Network setup spans lines 270-312:
- Check for slirp4netns availability: `command -v slirp4netns`
- Configure DNS via `TEMP_RESOLV` (line 280-282)
- Configure `/etc/hosts` via `TEMP_HOSTS` (lines 286-291)
- For custom network policies, modify slirp4netns flags at line 377

### Adding Claude Configuration Mounts

Claude Code needs specific paths (lines 238-263):
- Binary: `~/.local/bin/claude` (read-only)
- Config directory: `~/.claude/` (read-write)
- State file: `~/.claude.json` (read-write, auto-created if missing)

When adding mounts, remember:
- Bind after `--tmpfs "$HOME"` (line 209) or they'll be hidden
- Use `--ro-bind` for read-only, `--bind` for read-write
- Non-existent paths should be checked before binding

## Testing Checklist

When modifying the script:
1. Test with non-existent whitelist/blacklist files (should auto-generate)
2. Test with empty working directory
3. Test with glob patterns in blacklist (`*.env`, `.secrets/*`)
4. Test with environment variable expansion in whitelist (`$HOME/.local`)
5. Verify cleanup on clean exit and interrupt (Ctrl+C) - check for temp file leaks
6. Test all three network modes:
   - Default with slirp4netns installed (internet-only)
   - Default without slirp4netns (no network)
   - `--allow-local-net` (full network)
7. Test localhost blocking: `./claude-code-sandbox.sh -- bash test_localhost.sh`
8. Test Claude Code can still access its config: check `~/.claude/` and `~/.claude.json`

## Files in Repository

- `claude-code-sandbox.sh` - Main executable script (403 lines)
- `README.md` - User-facing documentation
- `whitelist-example.txt` - Example whitelist configuration (41 lines)
- `blacklist-example.txt` - Example blacklist configuration (94 lines)
- `.gitignore` - Git ignore patterns
