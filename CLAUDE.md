# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a bash-based sandboxing solution for running Claude Code in isolated environments using **bubblewrap**. The script (`claude-code-sandbox.sh`) provides filesystem isolation via whitelist/blacklist. Full network access (both local and internet) is enabled.

## Architecture

### Core Components

**Main Script: `claude-code-sandbox.sh`**
- Single executable bash script that wraps Claude Code in a bubblewrap sandbox
- Implements two-tier filesystem access control with **multi-file support**:
  1. **Whitelist**: Absolute or relative paths Claude can read (relative paths resolved relative to working directory)
     - User-level: `~/.config/claude-sandbox/whitelist.txt` (always included, auto-generated)
     - Project-level: `.claude/whitelist.txt` in working directory (included if exists)
     - Additional files via `--whitelist` flag (can be specified multiple times)
  2. **Blacklist**: Relative working directory paths Claude cannot access
     - User-level: `~/.config/claude-sandbox/blacklist.txt` (always included, auto-generated)
     - Project-level: `.claude/blacklist.txt` in working directory (included if exists)
     - Additional files via `--blacklist` flag (can be specified multiple times)

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

**Configuration Resolution Order (Multi-File Support)**:
1. **User-level files** (always included if they exist):
   - `~/.config/claude-sandbox/whitelist.txt`
   - `~/.config/claude-sandbox/blacklist.txt`
   - Environment variables `CLAUDE_SANDBOX_WHITELIST` and `CLAUDE_SANDBOX_BLACKLIST` set the default file locations
   - **Auto-generated** if they don't exist and no explicit files were provided (lines 111-191)
2. **Project-level files** (automatically included if they exist, lines 201-207):
   - `.claude/whitelist.txt` (in working directory)
   - `.claude/blacklist.txt` (in working directory)
   - **Never auto-generated** - create manually for project-specific rules
3. **Additional files** via `--whitelist` and `--blacklist` command-line arguments (can be specified multiple times)
4. All files are merged - paths from all whitelist files are allowed, patterns from all blacklist files are blocked

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
# Run in current directory with default settings
./claude-code-sandbox.sh

# Test with single additional whitelist/blacklist (defaults still included)
./claude-code-sandbox.sh \
  --whitelist ./whitelist-example.txt \
  --blacklist ./blacklist-example.txt

# Test with multiple whitelist/blacklist files
./claude-code-sandbox.sh \
  --whitelist ~/shared-whitelist.txt \
  --whitelist ./project-whitelist.txt \
  --blacklist ~/shared-blacklist.txt \
  --blacklist ./project-blacklist.txt

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

**Pattern Matching Implementation** (find_matches function, lines 147-183):
- **Unified approach**: All pattern matching uses `find` command for consistency
- **Ant-style support**: Detects `**` patterns and handles them recursively
- Simple patterns: Uses `-name` or `-path` with `-maxdepth 1` for performance
- Recursive patterns: Uses `-name` or `-path` without depth limit
- Complex patterns: Converts `**` to `*` for path matching (e.g., `src/**/test/**/*.java`)
- Returns list of absolute paths matching the pattern

**Blacklist Implementation** (blacklist_pattern function, lines 246-271):
- **Multi-file processing**: Loops through all blacklist files in the array
- Uses `find_matches()` to expand patterns (supports ant-style `**`)
- Uses tmpfs mounts to hide directories (no file copying)
- Uses `/dev/null` binding to hide files
- Pattern matching happens against `$WORKING_DIR/$pattern`
- Non-matching patterns generate warnings but don't fail
- Missing blacklist files are skipped with warning (non-fatal)

**Whitelist Implementation** (whitelist_path function, lines 191-246):
- **Multi-file processing**: Loops through all whitelist files in the array
- Uses `find_matches()` to expand patterns (supports ant-style `**`)
- Environment variable expansion: `${line/#\~/$HOME}` and `${path//\$HOME/$HOME}`
- **Relative path support**: Paths not starting with `/`, `~`, or `$HOME` are converted to absolute by prepending `$WORKING_DIR`
- Extracts base directory from pattern for efficient find starting point
- Non-existent paths are skipped with warning, not errors
- Supports read-only (default) and read-write (`:rw` suffix) binding
- Missing whitelist files are skipped with warning, but at least one file must exist

### Configuration File Format

**Whitelist** (absolute or relative paths/patterns):
- One path or pattern per line
- Supports both absolute paths (e.g., `/usr/bin`) and relative paths (e.g., `data/`, `src/**/*.txt`)
- Relative paths are resolved relative to the working directory
- Environment variable expansion supported: `$HOME` or `~`
- **Pattern support**:
  - Simple glob: `*`, `?`, `[]` (e.g., `/etc/java*` or `*.json`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `/usr/**/lib64` or `src/**`)
  - Complex: Multiple `**` segments (e.g., `/opt/**/bin/**/tools` or `data/**/cache`)
- Patterns are expanded at sandbox start time using `find` command
- Literal paths are validated before binding - non-existent paths are skipped
- Read-write access: Append `:rw` to path/pattern (e.g., `/opt/cache:rw` or `data/:rw`)
- Comments start with `#`
- Empty lines ignored
- **Multi-file support**: All paths from all whitelist files are merged and allowed
  - User-level: `~/.config/claude-sandbox/whitelist.txt`
  - Project-level: `.claude/whitelist.txt` (if exists)
  - Additional: via `--whitelist` flags

**Blacklist** (relative paths or patterns):
- Paths relative to working directory
- **Pattern support**:
  - Simple glob: `*`, `?` (e.g., `*.env`)
  - **Ant-style recursive**: `**` for recursive matching (e.g., `**/wallet.dat` blocks wallet.dat anywhere)
  - Complex: Multiple `**` segments (e.g., `**/test/**/secrets.json`)
- Patterns are expanded at sandbox start time using `find` command
- Comments start with `#`
- Empty lines ignored
- **Multi-file support**: All patterns from all blacklist files are merged and blocked
  - User-level: `~/.config/claude-sandbox/blacklist.txt`
  - Project-level: `.claude/blacklist.txt` (if exists)
  - Additional: via `--blacklist` flags

**Common Ant-Style Pattern Examples**:
- `**/wallet.dat` - (blacklist) Matches wallet.dat in any subdirectory at any depth
- `**/.env` - (blacklist) Matches .env files anywhere in the tree
- `src/**/test/**/*.java` - (blacklist) Matches .java files in test directories under src
- `/usr/**/lib64` - (whitelist, absolute) Matches any lib64 directory under /usr
- `data/**` - (whitelist, relative) Matches all files under the data/ directory in working directory
- `src/**/*.json` - (whitelist, relative) Matches all .json files anywhere under src/ directory

## Modifying the Script

### Adding New Command-Line Options

Options are parsed in the `while` loop at lines 51-86. Patterns:

**Single-value option:**
```bash
--your-option)
    YOUR_VAR="$2"
    shift 2
    ;;
```

**Multi-value option (array):**
```bash
--your-option)
    YOUR_ARRAY+=("$2")
    EXPLICIT_YOUR_OPTION=true
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
1. Test with non-existent user-level whitelist/blacklist files (should auto-generate)
2. Test with explicit whitelist/blacklist files (should NOT auto-generate user-level defaults)
3. Test with project-level files (`.claude/whitelist.txt`, `.claude/blacklist.txt`) - verify they're included
4. Test without project-level files (should work normally, no errors)
5. Test with multiple whitelist files (verify all paths are merged)
6. Test with multiple blacklist files (verify all patterns are merged)
7. Test with empty working directory
8. Test with glob patterns in blacklist (`*.env`, `.secrets/*`)
9. Test with environment variable expansion in whitelist (`$HOME/.local`, `~/.local`)
10. Test with relative paths in whitelist (`data/`, `src/**/*.txt`)
11. Test with ant-style patterns in both absolute and relative whitelist paths
12. Verify cleanup on clean exit and interrupt (Ctrl+C) - check for temp file leaks
13. Test with missing additional files (should skip with warning, not fail)
14. Test Claude Code can still access its config: check `~/.claude/` and `~/.claude.json`
15. Verify configuration summary shows all whitelist/blacklist files being used (user, project, and explicit)

## Files in Repository

- `claude-code-sandbox.sh` - Main executable script (383 lines)
- `README.md` - User-facing documentation
- `whitelist-example.txt` - Example whitelist configuration
- `blacklist-example.txt` - Example blacklist configuration
- `.gitignore` - Git ignore patterns
- `CLAUDE.md` - Developer documentation (this file)

## Project-Level Configuration

Projects can include their own whitelist/blacklist files in the `.claude/` directory:
- These files are automatically detected and used when present
- They are never auto-generated
- Ideal for version-controlled, team-shared configurations
- Merged with user-level and explicit files
