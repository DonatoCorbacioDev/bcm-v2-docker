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

- [ ] **Volume backups** - Automated database backups
```bash
docker run --rm \
  --volumes-from bcm-mysql \
  -v $(pwd):/backup \
  alpine tar czf /backup/mysql-backup.tar.gz /var/lib/mysql
```

- [ ] **Offsite backups** - S3, Azure Blob, Google Cloud Storage
- [ ] **Backup encryption** - Encrypt backups at rest
- [ ] **Restore testing** - Regularly test backup restoration
- [ ] **Disaster recovery plan** - Documented procedures

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
