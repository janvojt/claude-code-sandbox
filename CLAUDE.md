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
- Network isolation via DNS-level blocking using custom `/etc/hosts` (when `--allow-local-net` is not used)

### Key Design Patterns

**Filesystem Isolation Strategy (lines 210-243)**:
- Uses overlay filesystem approach: copies working directory to temp location (`$OVERLAY_MERGED`)
- Removes blacklisted files from the overlay before binding
- This means blacklist patterns are expanded at sandbox start time, not dynamically

**Configuration Resolution Order**:
1. Command-line arguments (`--whitelist`, `--blacklist`)
2. Environment variables (`CLAUDE_SANDBOX_WHITELIST`, `CLAUDE_SANDBOX_BLACKLIST`)
3. Default locations (`~/.config/claude-sandbox/{whitelist,blacklist}.txt`)
4. Auto-generated defaults if files don't exist

**Bubblewrap Namespace Setup (lines 169-186)**:
- `--unshare-all` creates isolated namespaces
- `--share-net` keeps network namespace (with DNS-level filtering)
- Minimal environment: only Claude config from `~/.config/claude` is preserved
- SSH agent is explicitly disabled via `--unsetenv SSH_AUTH_SOCK`

## Development Commands

### Testing the Script

```bash
# Run in current directory with default settings
./claude-code-sandbox.sh

# Test with local network access
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

### Security Limitations

**Network Blocking** (lines 264-303):
- Current implementation uses `/etc/hosts` for blocking - this is **DNS-level only**
- Direct IP connections can bypass this blocking
- For production use, consider implementing `--unshare-net` with `slirp4netns`

**Blacklist Performance** (lines 216-217):
- Entire working directory is copied to create overlay
- Large directories (>10GB) may cause performance issues
- Glob patterns in blacklist are expanded at start time, not monitored dynamically

### Trap Cleanup Chain

The script builds cleanup traps incrementally (lines 214, 250, 286, 293):
```bash
trap "rm -rf $OVERLAY_WORK $OVERLAY_UPPER $OVERLAY_MERGED" EXIT
trap "rm -rf $TEMP_HOME $OVERLAY_WORK ..." EXIT  # Adds to previous
```
This pattern ensures all temp files/directories are cleaned up on exit.

### Configuration File Format

**Whitelist** (absolute paths, lines 189-208):
- One path per line
- Environment variable expansion supported: `$HOME` or `${HOME}`
- Paths are validated before binding - non-existent paths are skipped
- Comments start with `#`

**Blacklist** (relative paths, lines 220-243):
- Paths relative to working directory
- Glob patterns supported (`*`, `?`)
- Patterns expanded using bash `compgen -G`
- Comments start with `#`

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

Network setup is at lines 264-303. Key sections:
- `TEMP_HOSTS`: Custom `/etc/hosts` for blocking DNS resolution
- `TEMP_RESOLV`: Custom `/etc/resolv.conf` for DNS servers

## Testing Checklist

When modifying the script:
1. Test with non-existent whitelist/blacklist files (should auto-generate)
2. Test with empty working directory
3. Test with large working directory (>1GB) for performance
4. Test with glob patterns in blacklist (`*.env`, `.secrets/*`)
5. Test with environment variable expansion in whitelist (`$HOME/.local`)
6. Verify temp directory cleanup on both clean exit and interrupt (Ctrl+C)
7. Test network isolation with and without `--allow-local-net`

## Files in Repository

- `claude-code-sandbox.sh` - Main executable script
- `README.md` - User-facing documentation
- `whitelist-example.txt` - Example whitelist configuration (21 lines)
- `blacklist-example.txt` - Example blacklist configuration (34+ lines)
- `.gitignore` - Git ignore patterns
