# SSH Access Persistent Issue

## Problem
Despite multiple attempts to configure SSH access:
- Port 22 is OPEN (sshd running)
- authorized_keys installed correctly in /root/.ssh/ (600, root:root, 95 bytes)
- ssh.service enabled in systemd
- SSH still returns: Permission denied (publickey)

## Attempts Made
1. Initial install: /root/.ssh/authorized_keys
2. Retry after device reboot
3. Clean reinstall in recovery mode with verified permissions

## Likely Root Causes
1. **PermitRootLogin** may be set to "no" in /etc/ssh/sshd_config
2. **AppArmor profile** may block sshd from reading /root/.ssh/
3. **/root** home directory may be on a read-only mount or have wrong permissions
4. **Ubuntu Touch specific restriction** - may require developer mode or special config

## Workaround Needed
Since SSH consistently fails, peripheral investigation must use:
- HTTP 8080 status endpoint (limited info)
- Or modify approach to enable password auth or different user
