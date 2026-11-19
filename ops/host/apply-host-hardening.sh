#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Installs the production VM's host settings kept in this directory: SSH
# (10-bcm-hardening.conf) and the automatic reboot after security updates
# (51bcm-auto-reboot). Safe to run again. On the VM, from this repository's root:
#   bash ops/host/apply-host-hardening.sh
# The SSH configuration is checked (sshd -t) before it is loaded, and the
# running session is kept: test a NEW connection before closing this one.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo install -m 644 -o root -g root "$HERE/10-bcm-hardening.conf" /etc/ssh/sshd_config.d/10-bcm-hardening.conf
if ! sudo sshd -t; then
    sudo rm -f /etc/ssh/sshd_config.d/10-bcm-hardening.conf
    echo "ERROR: sshd rejected the configuration; removed it, SSH unchanged" >&2
    exit 1
fi
sudo systemctl reload ssh

sudo install -m 644 -o root -g root "$HERE/51bcm-auto-reboot" /etc/apt/apt.conf.d/51bcm-auto-reboot

echo "SSH now:"
sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication|maxauthtries|allowtcpforwarding|x11forwarding|allowagentforwarding|permittunnel) " | sed 's/^/  /'
echo "Automatic reboot:"
apt-config dump | grep -E "Unattended-Upgrade::Automatic-Reboot" | sed 's/^/  /'
