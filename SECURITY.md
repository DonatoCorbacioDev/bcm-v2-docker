# Security Policy - Docker Configuration

## 🔒 Security Overview

This repository contains the Docker Compose configuration for the BCM v2.0 application. Security considerations for containerized deployments are critical.

---

## 🐛 Reporting a Vulnerability

**📧 Email:** donatocorbacio92@gmail.com  
**Subject:** `[SECURITY] BCM Docker - [Brief Description]`

**⚠️ DO NOT open a public GitHub issue for security vulnerabilities.**

---

## 🛡️ Security Measures

### Current Implementation

#### Container Security (OWASP Docker Security Cheat Sheet, reviewed 2026-11-18)
- ✅ **Least privilege** - Every container drops all Linux capabilities (`cap_drop: ALL`) and runs with `no-new-privileges`; backend, frontend, ml and MySQL add none back. MySQL starts as its own user (999, `user:` in `docker-compose.yml`), so its entrypoint never switches users. Redis and ClamAV add back only what their entrypoint needs to hand its directories to an unprivileged user (`cap_add`, each tried one by one): Redis `CHOWN SETGID SETUID`, ClamAV five (`DAC_OVERRIDE` and `FOWNER` too, without which freshclam cannot save its state on a new volume). Their servers (`redis-server`, `clamd`, `freshclam`) keep none: effective capabilities `0`
- ✅ **Non-root user** - backend (`spring`), frontend (`nextjs`) and ml (`ml`) run as unprivileged users; their code is owned by root and read-only to them, so a compromised service cannot rewrite it. MySQL runs as `mysql` from the start; Redis switches to its own user at start. ClamAV's init script is the one process left as root, without network access of its own; clamd and freshclam run as `clamav`
- ✅ **Network isolation** - Three networks instead of one: `data` (internal: no route out) holds MySQL and Redis with the backend and ml, the only two that use them; `app` holds backend, ml and ClamAV, which need the internet (mail, Stripe, signature updates) and Ollama on the host; `web` holds the frontend alone, which calls nothing (the browser calls the API). In production MySQL is on `data` only and neither MySQL (3307) nor ml (8000) publishes a port; only the backend (8090) and the frontend (3000) do, on `127.0.0.1`, for Caddy. From the internet the VM accepts 22, 80 and 443 only (firewall). `app` keeps `172.18.0.0/16` in production: the firewall lets that subnet, and no other, reach Ollama
- ✅ **Read-only root filesystem** - `read_only: true` everywhere. What a service writes goes to a volume (database, uploads, signatures) or a tmpfs: `/tmp` (the backend's with `exec`, for the native libraries the JVM extracts there), `/run/mysqld`, ClamAV's `/run/clamav`, `/run/lock`, `/var/log/clamav`. ml's `HOME` is `/tmp` and its bytecode is compiled at build time. Redis no longer writes to disk: it holds only rate-limit counters
- ✅ **Resource limits** - Memory and CPU for each container in production (none can take both CPUs), and a ceiling on processes for each (`deploy.resources.limits.pids`) against a fork bomb
- ✅ **Image scanning** - `.github/workflows/image-scan.yml`: Trivy (the official image, pinned by digest) on the four images we build (backend, frontend, ml, MySQL) and the two we pull (Redis, ClamAV), on every push and every Monday; it fails on a HIGH or CRITICAL vulnerability that has a fix. Each image is handed to Trivy as a file, never through the Docker socket
- ✅ **Docker socket** - No container mounts `/var/run/docker.sock`. On the VM it is `root:docker 660`, and the only member of `docker` is the administrator, who has `sudo` anyway
- ✅ **MySQL accounts (database security, 2026-11-19)** - root only from inside the container (`MYSQL_ROOT_HOST=localhost`; `ops/mysql/harden-accounts.sh` drops `root@'%'`); the schema owner's password only in the `migrate` container, which applies the backend's migrations and exits before the backend starts with its row-only account; a connection limit per account; X Protocol off (`--mysqlx=OFF`). `ops/mysql/check-privileges.sh` compares every account and `SHOW GRANTS` with `ops/mysql/expected-privileges.txt`, weekly from cron and after every deploy
- ✅ **MySQL connections (database security, 2026-11-19)** - TLS 1.3 required on every network connection (`--require-secure-transport=ON`, `--tls-version=TLSv1.3`); in production MySQL uses a certificate from `ops/mysql/issue-tls-cert.sh` (a CA of our own, its key deleted after signing; the server certificate names `mysql` and `bcm-mysql`, valid two years) and every client checks it, CA and name (`sslMode=VERIFY_IDENTITY` for the backend and migrate, the host name for ml); `ops/mysql/check-privileges.sh` fails 30 days before it expires; the three application accounts accept connections only from the `data` network (`DB_ACCOUNT_HOST=172.19.%`, subnet fixed in `docker-compose.prod.yml`); passwords rotated with `ops/mysql/rotate-password.sh`
- ✅ **MySQL hardening (database security, 2026-11-19)** - Features nothing uses are off: no binary log (`--skip-log-bin`; it held 30 days of every change to the data), no event scheduler, no file read or written by SQL (`--secure-file-priv=NULL`), no X Protocol
- ✅ **Redis users (database security, 2026-11-19)** - `ops/redis/create-acl.sh` writes the ACL (`secrets/REDIS_ACL`, the password's SHA-256 only) and the backend's password (`secrets/REDIS_PASSWORD`): without logging in only PING (the healthcheck); the backend's user `bcm` may read, write and run scripts, never a dangerous command (FLUSHALL, CONFIG, KEYS...)
- ✅ **Keys and encryption at rest (database security, 2026-11-20)** - see Keys and Encryption at Rest below: every key's place, rotation and recovery copy; two-factor key rotation without losing 2FA; secrets recovery bundle under a key of its own; a weekly check that what should be encrypted still is
- ✅ **Host (2026-11-19)** - `ops/host/apply-host-hardening.sh`: SSH with keys only, no root login, no forwarding, three attempts; daily security updates (Ubuntu's unattended-upgrades) with an automatic reboot at 02:30 UTC when one needs it, between the backup and the demo reset
- ✅ **Volume Permissions** - Data persisted in named volumes

#### Configuration Security
- ✅ **`.env` git-ignored** - No credentials in version control
- ✅ **`.env.example` provided** - Template without real secrets
- ✅ **Strong password requirements** - Documented in example file
- ✅ **JWT secret generation** - Instructions for secure key creation

---

## ⚠️ Known Limitations

This is a **development/demonstration** configuration. The following should be addressed for production:

### Development Configuration Issues

- ⚠️ **Bind mounts** - SQL init scripts mounted from host filesystem
- ⚠️ **No TLS/SSL** - HTTP only (HTTPS should be enforced in production)

---

## 🚀 Production Security Checklist

Before deploying with Docker in production:

### Container Hardening

- [x] **Non-root users, no capabilities, `no-new-privileges`, read-only root filesystem** - See Container Security above (`x-hardening` in `docker-compose.yml`, applied in development and CI too, so the smoke test runs the stack hardened)
- [x] **No privileged containers** - None
- [ ] **Rootless Docker or user-namespace remapping** - Not done: it changes the ownership of every volume on the VM, a risky migration, for one administrator who has `sudo` in any case

### Resource Limits

- [x] **Memory, CPU and process limits** - `docker-compose.prod.yml` (memory, CPU), `docker-compose.yml` (processes)

### Network Security

- [x] **Internal networks** - Database and Redis on the internal `data` network; no MySQL or ml port in production
- [x] **TLS/SSL** - HTTPS only, certificates by Caddy
- [x] **Reverse proxy** - Caddy on the host (`Caddyfile`)
- [x] **Firewall rules** - Only 22, 80 and 443 from the internet

### Secrets Management

- [x] **Docker Secrets** - Instead of environment variables, in production since 2026-11-17: `docker-compose.prod.yml` (file-based secrets, `!reset` on the development variables), moved from `.env` once with `ops/secrets/move-secrets-from-env.sh`; the ops scripts read and write them through `ops/secrets/lib.sh`
- [x] **Rotate secrets** - Procedure per secret in the backend's `docs/SECURITY.md` ("Secret rotation and revocation")
- [ ] **Secrets Provider** - HashiCorp Vault, AWS Secrets Manager: not for a single VM with one administrator (one more service to run and secure)
- [ ] **Encrypt at rest** - The secret files are plain files on the VM's disk, like `.env` was; Docker encrypts secrets only in Swarm mode

### Images

- [x] **Scan images** - Trivy in CI, on every push and weekly (`image-scan.yml`)
- [x] **Minimal base images** - Alpine for the backend, the frontend and Redis; `python:3.12-slim` for ml (numpy and Prophet need glibc wheels)
- [x] **Multi-stage builds** - Backend and frontend: the runtime image carries no build tool
- [x] **Small build context** - `.dockerignore` in each repo (ml's since 2026-11-18): no `.git`, tests or local `.env` in an image
- [ ] **Image signing** - Not done: images are built on the VM from its own checkout, not pulled from a registry
- [x] **Supported versions** - MySQL 8.4 LTS since 2026-11-18 (8.0 reached its end of life in April 2026), as `mysql/Dockerfile`: the official 8.4.13 image without MySQL Shell and gosu, which the server never uses and which held every known vulnerability left in it
- [ ] **Version pinning by digest** - Tags are pinned to a version (`mysql:8.4.13`, `clamav/clamav:1.5.4-debian`) and Dependabot updates the base images; not by digest

### Monitoring & Logging

- [ ] **Centralized logging**
```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

- [ ] **Log aggregation** - ELK, Splunk, Datadog
- [ ] **Container monitoring** - Prometheus, cAdvisor
- [ ] **Security scanning** - Continuous vulnerability scanning
- [ ] **Audit logs** - Track all Docker operations

### Health Checks & Restarts

- [ ] **Health checks**
```yaml
backend:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8090/api/v1/actuator/health"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 60s
```

- [ ] **Restart policies**
```yaml
restart: unless-stopped
```

- [ ] **Graceful shutdown** - Handle SIGTERM properly
- [ ] **Liveness probes** - Auto-restart unhealthy containers

### Backup & Disaster Recovery

- [x] **Database and uploads backups** - nightly at 01:15 UTC (`ops/backup/backup.sh`), and before every deploy
- [x] **Offsite backups** - OCI Object Storage, checked byte-for-byte after every upload (`ops/backup/offsite.sh`)
- [x] **Backup encryption** - age, to a public key: the private one is never on the VM
- [x] **Key recovery** - `secrets/` and `.env` encrypted to a recovery key of their own, offsite under `recovery/` (`ops/secrets/recovery-bundle.sh`)
- [x] **Restore testing** - `ops/backup/restore-test.sh`, monthly (see Monthly Maintenance), monitored by its own Healthchecks.io check
- [x] **A copy outside Oracle Cloud** - the newest backup set and recovery bundle, monthly, on the owner's computer (`ops/backup/fetch-copy.sh`, newest 3 kept): the VM and the bucket share one cloud account
- [x] **Disaster recovery plan** - [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md): a new VM to the site back in service, RPO 24 hours, RTO half a day; the host's settings, firewall and cron kept in `ops/host/`

---

## 🔍 Security Scanning

### Scan Docker Images

```bash
# Using Docker Scout (built-in)
docker scout cves bcm-backend:latest
docker scout recommendations bcm-backend:latest

# Using Trivy
trivy image bcm-backend:latest

# Using Snyk
snyk container test bcm-backend:latest
```

### Scan Compose File

```bash
# Check for misconfigurations
docker-compose config --quiet

# Lint Compose file
docker-compose config | yamllint -
```

### Audit Running Containers

```bash
# Check container security
docker inspect bcm-backend | grep -i security

# List running processes
docker top bcm-backend

# Check resource usage
docker stats --no-stream
```

---

## 🔑 Keys and Encryption at Rest

Database security, encryption at rest and key management (reviewed 2026-11-20). What is encrypted or hashed, and where each key lives:

| Key | Protects | Where it is | Who reads it | Rotation | Recovery copy |
|---|---|---|---|---|---|
| `TOTP_ENCRYPTION_KEY` | two-factor secrets in `users` (AES-256-GCM, `v2:`) | `secrets/` on the VM | backend only | `ops/secrets/rotate-totp-key.sh`, no one loses 2FA | recovery bundle |
| `JWT_SECRET` | session tokens (signature) | `secrets/` | backend | `JWT_SECRET_PREVIOUS` during the change | recovery bundle |
| MySQL and Redis passwords | database and cache access | `secrets/` | the container of each account | `ops/mysql/rotate-password.sh`, `ops/redis/create-acl.sh` | recovery bundle |
| MySQL TLS certificate and key | connections to MySQL | `secrets/` | mysql (key), clients (CA) | `ops/mysql/issue-tls-cert.sh`, every two years | recovery bundle |
| Backup key (age) | backups of the database and uploads | private half **off the VM**, with the owner; `ops/backup/backup-recipient.pub` on it | the owner, to restore | see below | the owner's password manager |
| Recovery key (age) | the recovery bundle of `secrets/` and `.env` | private half **off the VM**, kept apart from the backup key; `ops/secrets/recovery-recipient.pub` on it | the owner | as the backup key | the owner's password manager |

Not encrypted, by choice: passwords and tokens are never stored in a readable form at all (BCrypt; SHA-256 of refresh, reset and invitation tokens). Contracts, counterparties, IBANs and uploaded files are stored in clear in MySQL and in the uploads volume, on the VM's disk, which Oracle Cloud encrypts. Encrypting them in the application would need the key on the same VM, since the backend must read them: it would protect only from a stolen disk, which the disk encryption already does, while making search and comparison harder (the IBAN anti-fraud check compares them). Their copies outside the VM, the backups, are encrypted with a key the VM does not have.

Kept apart: the backup key opens the data and nothing else, the recovery key the secrets and nothing else; neither private key is ever on the VM.

**The backups bucket** (`bcm-backups`, OCI Object Storage, checked in the console 2026-11-20): private, no pre-authenticated requests, Oracle-managed encryption key, versioning off. The VM's own identity (dynamic group `bcm-backup-vm`) may only create, read and inspect objects there:

```
Allow dynamic-group bcm-backup-vm to manage objects in tenancy where all {target.bucket.name='bcm-backups', any {request.permission='OBJECT_CREATE', request.permission='OBJECT_READ', request.permission='OBJECT_INSPECT'}}
```

so whoever takes the VM cannot delete or overwrite the copies outside it (tested: both refused). A time-bound retention rule of 7 days (`protezione-7-giorni`, not locked, so it can still be changed) refuses deleting or overwriting any object for 7 days, from the console too (tested: `RetentionRuleViolation`). Lifecycle rules then delete `daily/` after 10 days and `weekly/` after 35, by Object Storage itself (`bcm-backup-lifecycle-policy`); `recovery/` is never deleted automatically, so a copy of the current secrets always exists.

**The VM's disk** is encrypted with an Oracle-managed key. In-transit encryption between the VM and its disk is off: it can be chosen only when an instance is created. No boot volume backups, by choice: they would be a copy of every secret outside the backup and recovery keys; the backups, the recovery bundle and the repositories are enough to rebuild the VM.

**Checked weekly** (Monday 06:00 UTC, `ops/maintenance/weekly-checks.sh`, one Healthchecks.io check): `check-privileges.sh`, then `ops/maintenance/check-encryption.sh` (every two-factor secret `v2:`, passwords BCrypt, tokens SHA-256; newest backup under 26 hours and age-encrypted; `secrets/` 700, its files 444; a recovery bundle newer than every secret). It prints counts and formats, never a value.

**Rotating the backup key** (if the private one may have leaked, or every few years): generate a new pair off the VM (`age-keygen`), replace `ops/backup/backup-recipient.pub` with the new public key, take a backup, run a restore test with the new private key. Keep the old private key as long as a backup encrypted with it exists (the weekly copies, in the bucket), then destroy it. The recovery key is rotated the same way, with `recovery-bundle.sh` in place of the backup.

---

## 🔄 Monthly Maintenance

Security updates reach the VM by themselves (daily, rebooting at 02:30 UTC when needed). The containers are rebuilt only when deployed, so once a month, and whenever the weekly image scan fails or Dependabot opens a pull request:

1. Take a backup: `bash ops/backup/backup.sh`.
2. Rebuild every image on its updated base, and pull the others: `docker compose -f docker-compose.yml -f docker-compose.prod.yml build --pull` and `... pull redis clamav`.
3. Recreate the stack: `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d`.
4. Check: `bash ops/maintenance/weekly-checks.sh` (accounts, privileges, TLS certificate expiry, encryption at rest, keys) and the health of every container.
5. If `/var/run/reboot-required` exists, reboot the VM (or let 02:30 do it).
6. Restore test, on the owner's computer: `bash ops/backup/fetch-copy.sh "Q:/Archives/Business Contracts Manager 2.0/backup-copies"` (the copy outside Oracle), then `HEALTHCHECK_URL=<check "BCM prova ripristino"> bash ops/backup/restore-test.sh --key <backup key> --db ... --uploads ...` from that copy (it restores into a throwaway MySQL and counts tables, rows, migrations and files).
7. If a secret changed this month: `bash ops/secrets/recovery-bundle.sh`.

Every two years, before the date `check-privileges.sh` reports: renew MySQL's TLS certificate with `bash ops/mysql/issue-tls-cert.sh`, then `up -d mysql migrate backend ml`.

---

## 🛠️ Hardened Production Configuration

The configuration production runs is the hardened one: `docker-compose.yml` (capabilities, read-only filesystems, tmpfs, process limits, the three networks, MySQL's user) with `docker-compose.prod.yml` on top (Docker secrets, memory and CPU, no MySQL or ml port), and `mysql/Dockerfile`. See Container Security above.

---

## 📚 Security Resources

- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
- [OWASP Docker Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [Docker Secrets](https://docs.docker.com/engine/swarm/secrets/)

---

## 📞 Contact

**Security Contact:** donatocorbacio92@gmail.com  
**Project Maintainer:** Donato Corbacio  
**GitHub:** [@DonatoCorbacioDev](https://github.com/DonatoCorbacioDev)

---

**Last Updated:** February 5, 2026  
**Policy Version:** 1.0
