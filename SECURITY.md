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

#### Container Security
- ✅ **Environment Variables** - Secrets in `.env` (git-ignored)
- ✅ **Network Isolation** - Custom bridge network `bcm-network`
- ✅ **Non-default Ports** - MySQL on 3307 (not standard 3306)
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

- ⚠️ **Containers run as root** - Acceptable for local dev, not for production
- ⚠️ **No resource limits** - Containers can consume all system resources
- ⚠️ **Bind mounts** - SQL init scripts mounted from host filesystem
- ⚠️ **No secrets management** - Using `.env` file instead of Docker secrets
- ⚠️ **No TLS/SSL** - HTTP only (HTTPS should be enforced in production)
- ⚠️ **Exposed ports** - Database accessible from host (0.0.0.0:3307)
- ⚠️ **No health checks** - Containers may accept traffic before ready
- ⚠️ **No restart policies** - Containers don't auto-restart on failure

---

## 🚀 Production Security Checklist

Before deploying with Docker in production:

### Container Hardening

- [ ] **Run as non-root user**
```yaml
user: "1000:1000"
```

- [ ] **Read-only root filesystem**
```yaml
read_only: true
tmpfs:
  - /tmp
  - /var/run
```

- [ ] **Drop unnecessary capabilities**
```yaml
cap_drop:
  - ALL
cap_add:
  - NET_BIND_SERVICE
```

- [ ] **No privileged containers**
```yaml
privileged: false
```

- [ ] **Security options**
```yaml
security_opt:
  - no-new-privileges:true
  - apparmor:docker-default
```

### Resource Limits

- [ ] **Memory limits**
```yaml
deploy:
  resources:
    limits:
      memory: 2G
    reservations:
      memory: 1G
```

- [ ] **CPU limits**
```yaml
deploy:
  resources:
    limits:
      cpus: '2.0'
    reservations:
      cpus: '1.0'
```

### Network Security

- [ ] **Internal networks** - Database not exposed externally
```yaml
mysql:
  networks:
    - internal
  # Remove ports section

networks:
  internal:
    internal: true  # No external access
```

- [ ] **TLS/SSL** - HTTPS only with valid certificates
- [ ] **Reverse proxy** - Nginx/Traefik with SSL termination
- [ ] **Firewall rules** - Restrict access to known IPs

### Secrets Management

- [ ] **Docker Secrets** - Instead of environment variables
```yaml
secrets:
  db_password:
    external: true
  jwt_secret:
    external: true

services:
  backend:
    secrets:
      - db_password
      - jwt_secret
```

- [ ] **Secrets Provider** - HashiCorp Vault, AWS Secrets Manager
- [ ] **Rotate secrets** - Regular rotation schedule
- [ ] **Encrypt at rest** - Use Docker secret encryption

### Images

- [ ] **Scan images** - Docker Scout, Trivy, Clair
```bash
docker scout cves bcm-backend:latest
```

- [ ] **Minimal base images** - Use Alpine or Distroless
- [ ] **Multi-stage builds** - Reduce attack surface
- [ ] **Image signing** - Docker Content Trust
```bash
export DOCKER_CONTENT_TRUST=1
```

- [ ] **Private registry** - Don't use public Docker Hub for production
- [ ] **Version pinning** - Use specific image tags (not `latest`)

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

## 🛠️ Hardened Production Example

```yaml
version: '3.9'

services:
  mysql:
    image: mysql:8.0.39
    container_name: bcm-mysql
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - SETGID
      - SETUID
    networks:
      - internal
    volumes:
      - mysql_data:/var/lib/mysql
      - /var/run/mysqld  # tmpfs for socket
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /run/secrets/db_root_password
      MYSQL_DATABASE: bcm
      MYSQL_USER: bcm_user
      MYSQL_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_root_password
      - db_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '2.0'
        reservations:
          memory: 1G
          cpus: '0.5'

  backend:
    build:
      context: ../bcm-v2-backend
      dockerfile: Dockerfile
    image: bcm-backend:1.0.0
    container_name: bcm-backend
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - internal
      - external
    environment:
      SPRING_PROFILES_ACTIVE: prod
    secrets:
      - db_password
      - jwt_secret
      - mail_password
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '2.0'

  frontend:
    build:
      context: ../bcm-v2-frontend
      dockerfile: Dockerfile
    image: bcm-frontend:1.0.0
    container_name: bcm-frontend
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    networks:
      - external
    environment:
      NODE_ENV: production
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: unless-stopped
    depends_on:
      backend:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '1.0'

networks:
  internal:
    driver: bridge
    internal: true  # No external access
  external:
    driver: bridge

volumes:
  mysql_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /secure/path/mysql

secrets:
  db_root_password:
    external: true
  db_password:
    external: true
  jwt_secret:
    external: true
  mail_password:
    external: true
```

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
