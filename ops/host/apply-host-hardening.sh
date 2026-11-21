#!/usr/bin/env bash
#
# Copyright (c) 2025 Donato Corbacio. All rights reserved.
# Licensed under the terms of the LICENSE file at the repository root.
#
# Installs the production VM's host settings kept in this directory: SSH
# (10-bcm-hardening.conf), the automatic reboot after security updates
# (51bcm-auto-reboot), the journal's size and retention (journald-bcm.conf), the containers kept away from the instance metadata
# service (bcm-block-metadata.service), the firewall openings the stack needs
# (80, 443, Ollama from the app network) and Ollama's own setting
# (ollama-override.conf). Safe to run again: what is already there is kept. On the VM, from this repository's root:
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

if ! sudo cmp -s "$HERE/journald-bcm.conf" /etc/systemd/journald.conf.d/bcm.conf; then
    sudo install -D -m 644 -o root -g root "$HERE/journald-bcm.conf" /etc/systemd/journald.conf.d/bcm.conf
    sudo systemctl restart systemd-journald
fi

sudo install -m 644 -o root -g root "$HERE/bcm-block-metadata.service" /etc/systemd/system/bcm-block-metadata.service
sudo systemctl daemon-reload
sudo systemctl enable bcm-block-metadata.service
# Restarted, not just started: an already active one-shot service would not
# run again, and its rules may have changed (they are added only if missing).
sudo systemctl restart bcm-block-metadata.service

# Host firewall: Oracle's Ubuntu image accepts SSH and rejects everything else
# (the last INPUT rule); the stack needs these three before that rejection.
# Saved with netfilter-persistent, only when one was missing.
FIREWALL_RULES=(
    "-p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT"
    "-p tcp -m state --state NEW -m tcp --dport 443 -j ACCEPT"
    "-s 172.18.0.0/16 -p tcp -m tcp --dport 11434 -j ACCEPT"
)
changed=no
for rule in "${FIREWALL_RULES[@]}"; do
    # shellcheck disable=SC2086
    if ! sudo iptables -C INPUT $rule 2>/dev/null; then
        reject="$(sudo iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" {print $1; exit}')"
        # shellcheck disable=SC2086
        sudo iptables -I INPUT "${reject:-1}" $rule
        changed=yes
    fi
done
[ "$changed" = yes ] && sudo netfilter-persistent save

if [ -f /etc/systemd/system/ollama.service ]; then
    if ! sudo cmp -s "$HERE/ollama-override.conf" /etc/systemd/system/ollama.service.d/override.conf; then
        sudo install -D -m 644 -o root -g root "$HERE/ollama-override.conf" /etc/systemd/system/ollama.service.d/override.conf
        sudo systemctl daemon-reload
        sudo systemctl restart ollama
    fi
else
    echo "Ollama not installed yet: see DISASTER_RECOVERY.md, then run this again"
fi

echo "SSH now:"
sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication|maxauthtries|allowtcpforwarding|x11forwarding|allowagentforwarding|permittunnel) " | sed 's/^/  /'
echo "Automatic reboot:"
apt-config dump | grep -E "Unattended-Upgrade::Automatic-Reboot" | sed 's/^/  /'
echo "Journal (containers' logs):"
systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E "^(Storage|SystemMaxUse|MaxRetentionSec)=" | sed 's/^/  /'
journalctl --disk-usage 2>/dev/null | sed 's/^/  /'
echo "Metadata service from containers:"
sudo iptables -S DOCKER-USER | grep 169.254 | sed 's/^/  /'
echo "Firewall openings:"
sudo iptables -S INPUT | grep -E -- "--dport (80|443|11434) " | sed 's/^/  /'
