# Claude Code Sandbox Script

A secure bubblewrap-based sandboxing solution for running Claude Code with strict filesystem isolation.

## Features

- ✅ **Whitelist-based filesystem access** - Only explicitly allowed paths are readable
- ✅ **Blacklist protection** - Block sensitive files within working directory
- ✅ **Full network access** - Both local and internet access enabled
- ✅ **Minimal environment** - Clean environment variables, no SSH agent access
- ✅ **Working directory isolation** - Full read-write only in current directory

## Requirements

- **bubblewrap** - Install with:
  - Debian/Ubuntu: `sudo apt install bubblewrap`
  - Fedora: `sudo dnf install bubblewrap`
  - Arch: `sudo pacman -S bubblewrap`
- **Claude Code** - Install from https://docs.claude.com/en/docs/claude-code

## Installation

1. Make the script executable:
```bash
chmod +x claude-code-sandbox.sh
```

2. (Optional) Move to a directory in your PATH:
```bash
sudo mv claude-code-sandbox.sh /usr/local/bin/claude-sandbox
```

3. Create configuration directory:
```bash
mkdir -p ~/.config/claude-sandbox
```

4. Copy and customize the whitelist and blacklist files:
```bash
cp whitelist-example.txt ~/.config/claude-sandbox/whitelist.txt
cp blacklist-example.txt ~/.config/claude-sandbox/blacklist.txt
```

5. Edit the files to match your needs:
```bash
nano ~/.config/claude-sandbox/whitelist.txt
nano ~/.config/claude-sandbox/blacklist.txt
```

## Usage

### Basic usage:
```bash
./claude-code-sandbox.sh
```

### Custom whitelist/blacklist:
```bash
# Single custom file (default file is still included)
./claude-code-sandbox.sh \
  --whitelist /path/to/my-whitelist.txt \
  --blacklist /path/to/my-blacklist.txt

# Multiple whitelist/blacklist files
./claude-code-sandbox.sh \
  --whitelist ~/shared-whitelist.txt \
  --whitelist ./project-whitelist.txt \
  --blacklist ~/shared-blacklist.txt \
  --blacklist ./project-blacklist.txt
```

**Note:** The default whitelist and blacklist files (`~/.config/claude-sandbox/{whitelist,blacklist}.txt`) are always included automatically. Additional files specified via `--whitelist` and `--blacklist` are merged with the defaults.

### Pass arguments to Claude Code:
```bash
./claude-code-sandbox.sh -- --model claude-sonnet-4-5
```

### Using environment variables:
```bash
export CLAUDE_SANDBOX_WHITELIST=/path/to/whitelist.txt
export CLAUDE_SANDBOX_BLACKLIST=/path/to/blacklist.txt
./claude-code-sandbox.sh
```

## Configuration

### Multiple Configuration Files

The script supports **multiple whitelist and blacklist files**, which are processed in order:

1. **Default files** (always included if they exist):
   - `~/.config/claude-sandbox/whitelist.txt`
   - `~/.config/claude-sandbox/blacklist.txt`

2. **Additional files** specified via `--whitelist` and `--blacklist` flags

All files are merged together, allowing you to:
- Maintain a base configuration in the default files
- Add project-specific rules via additional files
- Share common configurations across multiple projects

**Auto-generation:** Default files are only created automatically if they don't exist **and** no explicit files are provided via command-line flags.

### Whitelist Format

The whitelist file contains **absolute paths** (one per line) that Claude can read:

```
# System binaries
/usr/bin
/usr/lib

# Java tools (for Java developers)
/usr/lib/jvm
/opt/maven

# Your custom paths
/opt/company/shared-libraries
```

**Important:**
- Paths must be absolute (start with `/`)
- Lines starting with `#` are ignored
- Environment variables like `$HOME` are expanded
- When using multiple whitelist files, all paths from all files are allowed

### Blacklist Format

The blacklist file contains **relative paths** from the working directory that Claude cannot access:

```
# Environment files
.env
.env.*

# SSH keys
.ssh
*.pem
*.key

# Cloud credentials
.aws
.gcp
```

**Important:**
- Paths are relative to the working directory
- Supports glob patterns (`*`, `?`)
- Lines starting with `#` are ignored
- When using multiple blacklist files, all patterns from all files are blocked

## Security Considerations

### What This Script Protects Against

1. ✅ **Filesystem access outside working directory** - Only whitelisted system paths are readable
2. ✅ **Sensitive files in working directory** - Blacklisted patterns are hidden
3. ✅ **SSH agent access** - SSH_AUTH_SOCK is removed from environment
4. ✅ **Home directory access** - Only minimal Claude config is exposed

### Limitations and Considerations

1. ⚠️ **Full network access** - The sandbox has complete network access (both local and internet). If you need network isolation, you'll need to modify the script to use `--unshare-net` with `slirp4netns`.

2. ⚠️ **Blacklist uses tmpfs mounts** - Files matching blacklist patterns are hidden via tmpfs. This means:
   - Glob patterns are expanded at sandbox start time
   - Performance impact is minimal

3. ⚠️ **Working directory is still read-write** - Claude has full access to create/modify/delete files in the working directory (except blacklisted ones). This is necessary for Claude Code to function.

4. ⚠️ **No process isolation** - While filesystem is isolated, Claude Code processes run on the host system (though in separate namespaces).

### Recommended Additional Hardening

For maximum security, consider:

1. **Resource limits**:
```bash
# Use systemd-run or ulimit to restrict CPU/memory
systemd-run --scope -p CPUQuota=200% -p MemoryMax=4G ./claude-code-sandbox.sh
```

2. **Read-only working directory option**:
```bash
# For analysis tasks where Claude shouldn't modify files
# (Would need script modification to support this use case)
```

3. **Audit logging**:
```bash
# Monitor file access patterns
auditctl -w /path/to/project -p rwa
```

4. **Network isolation**:
```bash
# Modify the script to use --unshare-net with slirp4netns
# for selective internet access while blocking local networks
```

## Troubleshooting

### "bubblewrap is not installed"
Install bubblewrap using your package manager (see Requirements section).

### "claude is not installed"
Install Claude Code from https://docs.claude.com/en/docs/claude-code

### Claude can't access necessary system libraries
Add the required paths to your whitelist file. Common additions:
- `/usr/lib/x86_64-linux-gnu` (Debian/Ubuntu)
- `/usr/lib64` (RedHat/Fedora)
- `/opt/custom-tools`

### Claude needs to access a specific sensitive file
If you genuinely need Claude to access a file that's blacklisted:
1. Remove it from the blacklist, or
2. Create a copy outside the blacklisted pattern, or
3. Use `--blacklist /dev/null` to disable blacklist (not recommended)

## Examples

### Using multiple configuration files

You can maintain a base configuration and add project-specific rules:

```bash
# ~/.config/claude-sandbox/whitelist.txt (base configuration)
/usr/bin
/usr/lib
/usr/share

# ~/projects/myproject/project-whitelist.txt (project-specific)
/opt/custom-compiler
/home/user/shared-libs

# Run with both configurations
cd ~/projects/myproject
claude-code-sandbox.sh --whitelist ./project-whitelist.txt
```

This approach allows you to:
- Keep common system paths in the default file
- Add project-specific paths without modifying the default
- Share project configurations via version control

### Java developer setup:
```bash
# whitelist.txt
/usr/bin
/usr/lib
/usr/lib/jvm
/opt/maven
/opt/gradle
~/.m2/repository  # Maven cache (read-only)

# blacklist.txt
.env
application-secrets.yml
keystore.jks
```

### DevOps/Ansible setup:
```bash
# whitelist.txt
/usr/bin
/usr/lib
/usr/share/ansible
/etc/ansible
/opt/ansible

# blacklist.txt
.env
*vault*.yml
ansible-vault.key
inventory/production
.ssh
*.pem
```

### Docker development:
```bash
# Full network access is enabled by default
./claude-code-sandbox.sh

# blacklist.txt
.env
.env.production
docker-compose.override.yml
secrets/
```

## License

This script is provided as-is for security-conscious Claude Code users. Modify as needed for your use case.

## Contributing

Suggestions for improvements:
1. More sophisticated overlay filesystem handling
2. Integration with security audit tools
3. Preset profiles for common development stacks
4. Optional network isolation modes

## Security Disclosure

If you find security issues with this sandboxing approach, please consider responsible disclosure practices.
