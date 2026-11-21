# 🧯 Disaster Recovery

How to bring BCM back on a **new VM** when the production one is lost: deleted, broken beyond repair, compromised, or gone with the cloud account. Written 2026-11-20 (Database security, backup, restore and disaster recovery); walked through step by step against the repositories, not yet rehearsed on a real new VM.

## Objectives

| | Target | Why |
|---|---|---|
| **RPO** (data that can be lost) | 24 hours at most | one backup every night at 01:15 UTC, plus one before every deploy |
| **RTO** (time to be back) | half a working day | a new VM, the host set up, the data restored; nothing waits on a third party except DNS |

## What survives the VM, and where

| Needed | Where | Without it |
|---|---|---|
| Code, compose files, scripts, host settings | the four GitHub repositories, and the owner's clones | — |
| Database and uploaded files | the bucket `bcm-backups` (`daily/` 10 days, `weekly/` 35 days); a copy **outside Oracle** on the owner's computer (`ops/backup/fetch-copy.sh`, monthly) | no data |
| `secrets/` and `.env` | the bucket under `recovery/`; the same copy on the owner's computer | the stack does not start, and the two-factor secrets cannot be read |
| Backup private key (age) | the owner only: password manager, offline copy | the backups cannot be opened |
| Recovery private key (age, a different one) | the owner only, kept apart from the backup key | `secrets/` cannot be opened |
| Accounts: Oracle Cloud, Porkbun (domain and DNS), GitHub, Healthchecks.io, UptimeRobot | the owner | — |

If the Oracle account itself is gone, the bucket is gone with it: use the copy on the owner's computer (`Q:\Archives\Business Contracts Manager 2.0\backup-copies\<stamp>\`), at most a month old, and the nightly backups in between are lost.

## 1. A new VM

1. Oracle Cloud (or any provider with Ubuntu 24.04 on arm64 or amd64): `VM.Standard.A1.Flex`, 2 OCPU, 12 GB, 100 GB boot volume, Canonical Ubuntu 24.04, your SSH public key.
2. **Instance metadata service: Version 2 only.** Security list: only 22, 80 and 443 in.
3. Backups to the bucket authenticate as the VM itself: open the dynamic group `bcm-backup-vm` (Identity → Domains → Default → Dynamic groups) and make its matching rule cover the new instance (its OCID, or the compartment). The policy `bcm-backup-vm-policy` stays as it is (`SECURITY.md`, Keys and Encryption at Rest).
4. Point the DNS record of `bcm.donatocorbacio.dev` to the new public IP now, at Porkbun (the domain's registrar and DNS: Domain Management → DNS, the `A` record of `bcm`): Caddy needs it to obtain the HTTPS certificate.

## 2. The host

On the new VM, as `ubuntu`:

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get -y install git age iptables-persistent unattended-upgrades python3-venv curl
# Docker Engine and the compose plugin: https://docs.docker.com/engine/install/ubuntu/
sudo usermod -aG docker ubuntu          # then log out and back in
# Caddy: https://caddyserver.com/docs/install#debian-ubuntu-raspbian
# Ollama, and the two models ml uses:
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text && ollama pull llama3.2:1b
# OCI CLI, for the offsite copies (no keys: the VM's identity is used):
python3 -m venv ~/.oci-cli-venv && ~/.oci-cli-venv/bin/pip install oci-cli
```

Versions in production on 2026-11-20: Docker 29.6, Caddy 2.11, Ollama 0.40, age 1.1, OCI CLI 3.94.

```bash
mkdir -p ~/bcm-v2 && cd ~/bcm-v2
for r in backend frontend ml docker; do git clone https://github.com/DonatoCorbacioDev/bcm-v2-$r.git; done
cd bcm-v2-docker
bash ops/host/apply-host-hardening.sh     # SSH, reboots, firewall, metadata block, Ollama setting
sudo install -m 644 Caddyfile /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Before closing the SSH session, open a second one: `apply-host-hardening.sh` allows keys only and three attempts.

## 3. The keys

On the owner's computer, from the newest recovery bundle (bucket `recovery/`, or the copy in `backup-copies/`). It is decrypted there and unpacked on the VM: the private key never reaches the VM and the secrets are never written in clear on the computer.

```bash
age -d -i bcm-recovery-key.txt bcm-recovery-<stamp>.tar.gz.age \
  | ssh -i ~/.ssh/bcm_prod_key ubuntu@<new IP> 'cd ~/bcm-v2/bcm-v2-docker && tar -xz'
```

Then on the VM: `stat -c '%a %n' secrets secrets/*` must show `700` and `444`. In `.env`, check the values tied to the old VM: `DB_ACCOUNT_HOST` (the `data` network, fixed in `docker-compose.prod.yml`) stays the same.

## 4. The database

```bash
C="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
$C build
$C up -d mysql redis          # MySQL creates the schema owner from .env and secrets/
```

From the owner's computer, the newest backup set (bucket `daily/`, or `backup-copies/`), again decrypted there and loaded on the VM:

```bash
age -d -i bcm-backup-key.txt bcm-db-<stamp>.sql.gz.age | gunzip \
  | ssh -i ~/.ssh/bcm_prod_key ubuntu@<new IP> \
    'docker exec -i bcm-mysql sh -c "MYSQL_PWD=\$(cat /run/secrets/DB_ROOT_PASSWORD) exec mysql -uroot --default-character-set=utf8mb4"'
```

The dump names its database itself (`mysqldump --databases`), as `restore-test.sh` loads it. It holds the data and the migration history, not the MySQL accounts. On the VM:

```bash
bash ops/mysql/harden-accounts.sh
bash ops/mysql/create-app-runtime-user.sh
bash ops/mysql/create-ml-readonly-user.sh
$C up -d                      # migrate validates, then backend, ml, frontend, clamav
```

## 5. The uploaded files

```bash
age -d -i bcm-backup-key.txt bcm-uploads-<stamp>.tar.gz.age \
  | ssh -i ~/.ssh/bcm_prod_key ubuntu@<new IP> 'docker exec -i bcm-backend tar -xz -C /app/uploads'
```

Run inside the backend container, so the files belong to its own user.

## 6. Back in service

1. `docker ps`: every container `healthy`; `https://bcm.donatocorbacio.dev` answers; sign in as `demo`.
2. `bash ops/maintenance/weekly-checks.sh`: accounts, privileges, TLS certificate, encryption, keys, configuration, logs. It fails on the recovery bundle and the offsite copy until step 4 below. The healthcheck's MySQL account comes with the new data volume (`mysql/healthcheck-account.sql`); the journal's limits with `apply-host-hardening.sh`.
3. Cron: `crontab -e` with the lines of `ops/host/crontab.example`, the `<UUID>`s from the Healthchecks.io dashboard (same checks as before).
4. `bash ops/backup/backup.sh` and `bash ops/secrets/recovery-bundle.sh` by hand: both must end with the offsite copy verified.
5. UptimeRobot and Healthchecks.io: both turn green by themselves once the site answers and the next pings arrive.

## 7. If the old VM was compromised

The restored secrets are the ones the attacker may have read. Once the new VM is in service, rotate all of them: `JWT_SECRET` (with `JWT_SECRET_PREVIOUS`), the MySQL passwords (`ops/mysql/rotate-password.sh`), Redis (`ops/redis/create-acl.sh`), `TOTP_ENCRYPTION_KEY` (`ops/secrets/rotate-totp-key.sh`), the internal API keys, ML's signing key; at the providers, the Stripe keys and the mail password. Then a new recovery bundle. Terminate the old VM, after copying anything needed to understand what happened.

## Rehearsal

The data part is rehearsed every month (`restore-test.sh`, monitored by its own Healthchecks.io check). The whole procedure has not been run on a real new VM: doing it on the owner's computer would start the backend with production's mail and Stripe credentials, and its schedulers could send real email. It should be rehearsed on a throwaway VM with those two replaced by dummy values.
