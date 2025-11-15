# Claude Code Sandbox Script

A secure bubblewrap-based sandboxing solution for running Claude Code with strict filesystem and network isolation.

## Features

- ✅ **Whitelist-based filesystem access** - Only explicitly allowed paths are readable
- ✅ **Blacklist protection** - Block sensitive files within working directory
- ✅ **Network isolation** - Block local network access by default
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

### Basic usage (blocks local network):
```bash
./claude-code-sandbox.sh
```

### Allow local network access:
```bash
./claude-code-sandbox.sh --allow-local-net
```

### Custom whitelist/blacklist:
```bash
./claude-code-sandbox.sh \
  --whitelist /path/to/my-whitelist.txt \
  --blacklist /path/to/my-blacklist.txt
```

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

## Security Considerations

### What This Script Protects Against

1. ✅ **Filesystem access outside working directory** - Only whitelisted system paths are readable
2. ✅ **Sensitive files in working directory** - Blacklisted patterns are hidden
3. ✅ **Local network access** - DNS-level blocking of local networks (when not using `--allow-local-net`)
4. ✅ **SSH agent access** - SSH_AUTH_SOCK is removed from environment
5. ✅ **Home directory access** - Only minimal Claude config is exposed

### Limitations and Considerations

1. ⚠️ **Network blocking is DNS-level only** - The current implementation blocks local networks via `/etc/hosts`. For complete IP-level blocking, you would need to use `--unshare-net` with `slirp4netns` for internet access, which is more complex.

2. ⚠️ **Blacklist uses file removal** - Files matching blacklist patterns are removed from the overlaid view. This is effective but means:
   - Large working directories may have performance overhead
   - Glob patterns are expanded at sandbox start time

3. ⚠️ **Working directory is still read-write** - Claude has full access to create/modify/delete files in the working directory (except blacklisted ones). This is necessary for Claude Code to function.

4. ⚠️ **No process isolation** - While filesystem and network are isolated, Claude Code processes run on the host system (though in separate namespaces).

### Recommended Additional Hardening

For maximum security, consider:

1. **Network namespace with slirp4netns**:
```bash
# Use --unshare-net and slirp4netns for full network isolation
# with selective internet access
```

2. **Resource limits**:
```bash
# Use systemd-run or ulimit to restrict CPU/memory
systemd-run --scope -p CPUQuota=200% -p MemoryMax=4G ./claude-code-sandbox.sh
```

3. **Read-only working directory option**:
```bash
# For analysis tasks where Claude shouldn't modify files
# (Would need script modification to support this use case)
```

4. **Audit logging**:
```bash
# Monitor file access patterns
auditctl -w /path/to/project -p rwa
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

### Network requests failing to local services
This is by design. Use `--allow-local-net` if you need Claude to access:
- Local Docker containers
- Local development servers
- Local databases
- Local API endpoints

### Performance issues with large working directories
The blacklist implementation copies the entire working directory to create an overlay. For large projects:
1. Run from a subdirectory if possible
2. Minimize blacklist patterns
3. Consider running from a tmpfs mount for I/O intensive operations

## Examples

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
# Allow local network for Docker daemon access
./claude-code-sandbox.sh --allow-local-net

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
1. IP-level network filtering with iptables
2. More sophisticated overlay filesystem handling
3. Integration with security audit tools
4. Preset profiles for common development stacks

## Security Disclosure

If you find security issues with this sandboxing approach, please consider responsible disclosure practices.
