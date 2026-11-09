# 🐳 BCM — Docker Orchestration

> The whole BCM stack with one command on your machine, and the same compose files, with a production override and the nightly scripts, on the live server.

[![CI](https://github.com/DonatoCorbacioDev/bcm-v2-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/DonatoCorbacioDev/bcm-v2-docker/actions/workflows/ci.yml)
[![Spring Boot](https://img.shields.io/badge/Spring%20Boot-4.1-brightgreen?logo=spring)](https://spring.io/)
[![Next.js](https://img.shields.io/badge/Next.js-16-black?logo=next.js)](https://nextjs.org/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0-blue?logo=mysql)](https://www.mysql.com/)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-Custom-blue)](./LICENSE)

---

## 🎯 Overview

This repository holds the **Docker Compose configuration** of BCM, the multi-tenant contracts manager:

- **On your machine** — `docker compose up` builds and starts MySQL, Redis, the backend API, the web app and the ML service from the sibling repositories; Flyway creates the schema on the backend's first start
- **In production** — the same file plus [`docker-compose.prod.yml`](./docker-compose.prod.yml), behind Caddy ([`Caddyfile`](./Caddyfile)), with the nightly scripts in [`ops/`](./ops): encrypted off-site backups and the public demo reset

Live demo: [bcm.donatocorbacio.dev](https://bcm.donatocorbacio.dev) (`demo` / `BcmDemo#2026`). Screenshots in the [bcm-v2-frontend README](https://github.com/DonatoCorbacioDev/bcm-v2-frontend#-screenshots).

---

## 🏗️ Architecture

### On your machine

```mermaid
flowchart LR
    dev(["Browser<br/>localhost:3000"]) --> fe["frontend<br/>Next.js :3000"]
    fe --> api["backend<br/>Spring Boot :8090"]
    api --> db[("mysql<br/>:3307 on the host")]
    api --> redis[("redis<br/>internal only")]
    api -.->|optional| ml["ml<br/>FastAPI :8000"]
    ml -.->|read only| db
    api -.->|optional, on the host| ollama["Ollama"]
```

### In production

```mermaid
flowchart LR
    internet(["Internet"]) --> caddy["Caddy on the VM<br/>HTTPS, Let's Encrypt"]
    caddy --> fe["frontend"]
    caddy --> api["backend"]
    subgraph data["data on the VM"]
        db[("mysql")]
        files[("uploads volume")]
        redis[("redis")]
    end
    api --> data
    subgraph nightly["cron on the VM, every night"]
        backup["03:15 backup.sh<br/>dump + files, encrypted,<br/>copied off-site and verified"]
        reset["04:15 demo-reset.sh<br/>rebuilds the demo company"]
    end
    backup -.-> data
    reset -.->|SQL and the real API| api
```

Only Caddy is reachable from outside; the containers listen on `127.0.0.1`. Caddy also keeps the metrics endpoint private.

### Project Structure

```
bcm-v2/
├── bcm-v2-backend/        # Spring Boot REST API
│   ├── src/
│   ├── pom.xml
│   └── Dockerfile
├── bcm-v2-frontend/       # Next.js Web Application
│   ├── app/
│   ├── components/
│   ├── package.json
│   └── Dockerfile
└── bcm-v2-docker/         # 👉 This repository
    ├── docker-compose.yml
    ├── .env               # Your credentials (git-ignored)
    └── .env.example       # Template file
```

---

## 📦 Services

| Service | Container Name | Port | Technology | Description |
|---------|----------------|------|------------|-------------|
| **MySQL** | `bcm-mysql` | `3307` | MySQL 8.0 | Database server with persistent volume |
| **Redis** | `bcm-redis` | internal only | Redis 7 | Backs the distributed login/register rate limiter |
| **Backend** | `bcm-backend` | `8090` | Spring Boot 4.1 + Java 21 | REST API with JWT authentication |
| **Frontend** | `bcm-frontend` | `3000` | Next.js 16 + React 19 | Web UI with Tailwind CSS |
| **ML** | `bcm-ml` | `8000` | Python + FastAPI | Optional: the features using it are off in the demo |

**Network:** All services communicate via `bcm-network` (bridge driver)

---

## 🚀 Quick Start

### Prerequisites

Ensure you have installed:
- ✅ [Docker Desktop](https://www.docker.com/products/docker-desktop) (Windows/Mac) or Docker Engine (Linux)
- ✅ [Docker Compose](https://docs.docker.com/compose/install/) (usually included with Docker Desktop)
- ✅ [Git](https://git-scm.com/downloads)
- ✅ `openssl` to generate the JWT secret (bundled with Git for Windows, macOS and most Linux distributions)
- ✅ Minimum 4GB RAM available for Docker
- ✅ 10GB free disk space
- ➖ *Optional:* [Ollama](https://ollama.com/) on the host, only for the AI features that are off by default (semantic document search with `nomic-embed-text`, clause analysis with `llama3.2`); both services reach it through `host.docker.internal`. Without it everything else works.

**Verify installation:**

```bash
docker --version          # Should show: Docker version 20.10+
docker compose --version  # Should show: Docker Compose version 2.0+
```

---

### Step 1: Clone All Repositories

**Option A: Clone into a single parent directory (recommended)**

```bash
# Create project directory
mkdir bcm-v2 && cd bcm-v2

# Clone all four repositories: docker-compose.yml builds every service
# from the sibling folders below, it doesn't pull prebuilt images
git clone https://github.com/DonatoCorbacioDev/bcm-v2-backend.git
git clone https://github.com/DonatoCorbacioDev/bcm-v2-frontend.git
git clone https://github.com/DonatoCorbacioDev/bcm-v2-ml.git
git clone https://github.com/DonatoCorbacioDev/bcm-v2-docker.git

# Your structure should now be:
# bcm-v2/
#   ├── bcm-v2-backend/
#   ├── bcm-v2-frontend/
#   ├── bcm-v2-ml/
#   └── bcm-v2-docker/

cd bcm-v2-docker
```

**Option B: Clone separately (adjust paths in docker-compose.yml)**

If you clone repositories in different locations, update the `context` paths in `docker-compose.yml`:

```yaml
backend:
  build:
    context: /path/to/your/bcm-v2-backend  # Update this
    
frontend:
  build:
    context: /path/to/your/bcm-v2-frontend  # Update this

ml:
  build:
    context: /path/to/your/bcm-v2-ml  # Update this
```

---

### Step 2: Configure Environment Variables

**Create your `.env` file from the template:**

```bash
# Copy the example file
cp .env.example .env

# Edit with your credentials (Windows)
notepad .env

# Edit with your credentials (Linux/Mac)
nano .env
# or
vim .env
```

**Minimum required configuration:**

```env
# Database
DB_ROOT_PASSWORD=your_secure_password_here
DB_USERNAME=bcm_user
DB_PASSWORD=your_db_password_here

# JWT (generate with: openssl rand -base64 64)
JWT_SECRET=your_base64_encoded_secret_here
```

Everything else in `.env.example` (mail, ML keys, Stripe) can stay empty for a local run: the related features are simply off.

**Email in a local run:** this stack starts the backend with the `dev` profile, which never sends real email. Every message (registration code, password reset, invites) is written to the backend log instead, e.g. `docker compose logs backend | grep "registration code"`. You don't need to register at all to try BCM: the demo account in [Step 5](#step-5-access-the-application) is created automatically.

**⚠️ IMPORTANT:** 
- Generate a **strong JWT secret** (minimum 256 bits)
- Use **complex passwords** (16+ characters), but keep `@ : / # ?` out of `DB_PASSWORD`: the ML service puts it inside a database URL (`mysql+pymysql://user:password@mysql/...`), where those characters change its meaning
- **NEVER** commit `.env` to Git

---

### Step 3: Start All Services

```bash
# Build and start all containers (first time: 5-10 minutes)
docker compose up -d

# View logs in real-time
docker compose logs -f

# Or view logs for specific service
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs -f mysql
```

**What happens during startup:**

1. 🗄️ MySQL and Redis containers start; MySQL creates the empty `bcm` database
2. 🔧 Backend builds with Maven and starts Spring Boot; **Flyway** creates the schema by applying every migration, then the demo account is seeded
3. 🧠 ML service builds and starts FastAPI
4. 🎨 Frontend builds with npm and starts Next.js
5. ✅ All services become healthy

**Expected build time:**
- First build: 5-10 minutes (downloads dependencies)
- Subsequent builds: 1-2 minutes (uses cache)

---

### Step 4: Verify Services

**Check all containers are running:**

```bash
docker compose ps
```

**Expected output:**

```
NAME            STATUS              PORTS
bcm-mysql       Up (healthy)        127.0.0.1:3307->3306/tcp
bcm-redis       Up (healthy)        6379/tcp
bcm-backend     Up (healthy)        127.0.0.1:8090->8090/tcp
bcm-ml          Up (healthy)        127.0.0.1:8000->8000/tcp
bcm-frontend    Up (healthy)        127.0.0.1:3000->3000/tcp
```

**Health checks:**

```bash
# Backend API health
curl http://localhost:8090/api/v1/actuator/health

# Frontend (should return HTML)
curl http://localhost:3000

# ML service health
curl http://localhost:8000/health

# MySQL (uses the client inside the container, nothing to install)
docker exec -it bcm-mysql mysql -u bcm_user -p bcm
```

---

### Step 5: Access the Application

Once all services are running:

| Service | URL | Description |
|---------|-----|-------------|
| 🌐 **Frontend** | [http://localhost:3000](http://localhost:3000) | Web application login page |
| 🔌 **Backend API** | [http://localhost:8090/api/v1](http://localhost:8090/api/v1) | REST API base URL |
| 📚 **Swagger UI** | [http://localhost:8090/api/v1/swagger-ui.html](http://localhost:8090/api/v1/swagger-ui.html) | Interactive API documentation |
| 🩺 **Health Check** | [http://localhost:8090/api/v1/actuator/health](http://localhost:8090/api/v1/actuator/health) | Backend health status |
| 🗄️ **MySQL** | `localhost:3307` | Connect with MySQL Workbench or CLI |

**Demo login:** on a fresh database, `username: demo` / `password: Demo12345!` (ADMIN role). Seeded automatically by the backend on first startup — the `bcm-v2-backend` repo's `DevDataSeeder` (dev profile only, never runs in a `prod` deployment) creates this account because the migration-seeded default admin is intentionally disabled for security (see that repo's `V14__neutralize_default_admin.sql`). Check `docker compose logs backend | grep "Demo account"` if you don't see it — it's a no-op if the account already exists, so it only prints once.

---

## 🎮 Common Commands

### Container Management

```bash
# Start all services
docker compose up -d

# Stop all services (keeps data)
docker compose down

# Stop and remove all data (fresh start)
docker compose down -v

# Restart a specific service
docker compose restart backend
docker compose restart frontend

# Rebuild after code changes
docker compose up -d --build

# Rebuild specific service
docker compose up -d --build backend
```

### Viewing Logs

```bash
# All logs (real-time)
docker compose logs -f

# Last 100 lines from backend
docker compose logs --tail=100 backend

# Follow only errors
docker compose logs -f | grep ERROR

# Export logs to file
docker compose logs > logs.txt
```

### Database Operations

```bash
# Connect to MySQL CLI
docker exec -it bcm-mysql mysql -uroot -p

# Backup database
docker exec bcm-mysql mysqldump -uroot -p bcm > backup.sql

# Restore database
docker exec -i bcm-mysql mysql -uroot -p bcm < backup.sql

# View database size
docker exec bcm-mysql mysql -uroot -p -e "SELECT table_schema AS 'Database', ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)' FROM information_schema.tables WHERE table_schema='bcm' GROUP BY table_schema;"
```

### Container Shell Access

```bash
# Access backend container shell
docker exec -it bcm-backend /bin/bash

# Access frontend container shell
docker exec -it bcm-frontend /bin/sh

# Access MySQL container shell
docker exec -it bcm-mysql /bin/bash
```

---

## 🐛 Troubleshooting

### Problem: Backend won't start

**Symptoms:**
- `bcm-backend` container exits immediately
- Logs show "Connection refused" or "Access denied"

**Solution:**

```bash
# 1. Check MySQL is running
docker compose ps mysql

# 2. Verify MySQL is healthy (wait 30 seconds after start)
docker compose logs mysql | grep "ready for connections"

# 3. Check environment variables
docker exec bcm-backend printenv | grep DB

# 4. Test MySQL connection from backend container
docker exec bcm-backend mysql -h bcm-mysql -u bcm_user -p

# 5. Restart backend after MySQL is ready
docker compose restart backend
```

---

### Problem: Frontend can't connect to backend

**Symptoms:**
- Login fails with "Network Error"
- Frontend shows "Failed to fetch"

**Solution:**

```bash
# 1. Verify backend is accessible
curl http://localhost:8090/api/v1/actuator/health

# 2. Check frontend environment variable
docker exec bcm-frontend printenv | grep NEXT_PUBLIC_API_URL

# 3. Verify network connectivity
docker exec bcm-frontend ping bcm-backend

# 4. Check CORS configuration in backend
docker compose logs backend | grep CORS

# 5. Restart frontend
docker compose restart frontend
```

---

### Problem: Port already in use

**Symptoms:**
- `Error: bind: address already in use`

**Solution:**

```bash
# Windows: Find and kill process using port 3000/8090/3307
netstat -ano | findstr :3000
taskkill /PID <PID> /F

# Linux/Mac: Find and kill process
lsof -ti:3000 | xargs kill -9

# Or change ports in docker-compose.yml:
# ports:
#   - "3001:3000"  # Use 3001 instead of 3000
```

---

### Problem: Database schema not created

**Symptoms:**
- Backend logs: "Table 'bcm.users' doesn't exist"

**Solution:**

The schema is created automatically by **Flyway** on backend startup (not by MySQL init scripts). If the tables are missing:

```bash
# 1. Check Flyway migration logs
docker compose logs backend | grep -i flyway

# 2. Verify MySQL is healthy before backend starts
docker compose logs mysql | grep "ready for connections"

# 3. Restart with a fresh volume (Flyway will re-run all migrations)
docker compose down -v
docker compose up -d
```

---

### Problem: Changes not reflected after rebuild

**Symptoms:**
- Code changes don't appear after `docker compose up --build`

**Solution:**

```bash
# Full rebuild without cache
docker compose build --no-cache backend
docker compose up -d

# Or remove everything and rebuild
docker compose down -v --rmi all
docker compose up -d --build
```

---

### Problem: Out of memory / containers crashing

**Symptoms:**
- Containers exit with code 137 or 143
- Docker Desktop shows high memory usage

**Solution:**

1. **Increase Docker memory limit:**
   - Docker Desktop → Settings → Resources → Memory → Set to 6GB+

2. **Limit container resources in docker-compose.yml:**

```yaml
backend:
  deploy:
    resources:
      limits:
        memory: 2G
      reservations:
        memory: 1G
```

3. **Clean up unused resources:**

```bash
# Remove unused images, containers, volumes
docker system prune -a --volumes

# Check disk usage
docker system df
```

---

### Problem: JWT token errors

**Symptoms:**
- Backend logs: "DecodingException: Illegal base64 character"
- Login returns 401 Unauthorized

**Solution:**

```bash
# 1. Verify JWT_SECRET is base64 encoded
docker exec bcm-backend printenv JWT_SECRET

# 2. Generate new valid key
openssl rand -base64 64

# 3. Update .env file with new key

# 4. Restart backend
docker compose restart backend
```

---

## 🔧 Development Workflow

### Making Code Changes

**Backend changes:**

```bash
# 1. Edit code in bcm-v2-backend/src/...

# 2. Rebuild and restart backend
docker compose up -d --build backend

# 3. View logs for errors
docker compose logs -f backend
```

**Frontend changes:**

```bash
# 1. Edit code in bcm-v2-frontend/app/... or components/...

# 2. Rebuild and restart frontend
docker compose up -d --build frontend

# 3. View logs
docker compose logs -f frontend
```

**Hot reload alternative (faster development):**

For rapid development, run services locally instead of in Docker:

```bash
# Terminal 1: MySQL only in Docker
docker compose up -d mysql

# Terminal 2: Backend locally
cd ../bcm-v2-backend
mvn spring-boot:run

# Terminal 3: Frontend locally
cd ../bcm-v2-frontend
npm run dev
```

---

## 🧹 Cleanup

### Remove containers but keep data

```bash
docker compose down
```

### Remove containers AND all data (fresh start)

```bash
docker compose down -v
```

### Remove everything including images

```bash
docker compose down -v --rmi all
```

### Complete Docker cleanup (all projects)

```bash
# ⚠️ WARNING: This removes ALL Docker resources on your machine

# Stop all running containers
docker stop $(docker ps -aq)

# Remove all containers
docker rm $(docker ps -aq)

# Remove all images
docker rmi $(docker images -q)

# Remove all volumes
docker volume prune -a

# Remove all networks
docker network prune

# Clean build cache
docker builder prune -a
```

---

## 🌐 Production

How the live demo runs, on one cloud VM:

| | |
|---|---|
| **Start** | `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build` — the override switches the backend to the `prod` profile; every port is already bound to `127.0.0.1` in the base file |
| **HTTPS** | Caddy on the VM, certificates from Let's Encrypt; routes `/api/v1/*` to the backend and the rest to the frontend; the metrics endpoint answers only the private network |
| **Backups** | [`ops/backup/backup.sh`](./ops/backup/backup.sh) every night: database dump and uploaded files, encrypted for a key kept off the server, copied off-site and verified byte by byte; [`restore-test.sh`](./ops/backup/restore-test.sh) proves a backup actually restores |
| **Public demo** | [`ops/demo/demo-reset.sh`](./ops/demo/demo-reset.sh) every night: rebuilds the demo company from `seed-demo-org.sql`, removes its old files, attaches the sample invoices and contract PDF through the real API, and checks the result |
| **ML database account** | [`ops/mysql/create-ml-readonly-user.sh`](./ops/mysql/create-ml-readonly-user.sh), once: the ML service reads through its own account with `SELECT` on three tables only |
| **Tenant isolation check** | [`ops/smoke/bola_two_orgs.py`](./ops/smoke/bola_two_orgs.py) registers two organizations and two managers on a dev-profile stack and tries every cross-organization and cross-manager access over plain HTTP; it runs in CI on every push. Never against production |
| **Deploy** | `git pull` in the repositories, then rebuild only the service that changed (`up -d --build --no-deps backend`); Flyway migrates on start, health checks confirm |
| **Monitoring** | External uptime checks on the site and the API, with alerts |

## 🔒 Security Notes

- ✅ Containers run as non-root users (`spring`, `nextjs`, `ml`)
- ✅ Secrets only in `.env`, git-ignored; `.env.example` holds no real values
- ✅ In production only Caddy is exposed, with TLS; containers listen on `127.0.0.1`
- ✅ Health checks and restart policies on every service
- ✅ Encrypted, verified off-site backups; rate limiting on login and registration (Redis)
- ⚠️ Still open: secrets in `.env` rather than a secrets manager, a single VM (no orchestration, no failover), no container resource limits — see [SECURITY.md](./SECURITY.md)

---

## 📚 Additional Resources

### Related Repositories

- **Backend:** [bcm-v2-backend](https://github.com/DonatoCorbacioDev/bcm-v2-backend) - Spring Boot REST API, with the product story and the architecture
- **Frontend:** [bcm-v2-frontend](https://github.com/DonatoCorbacioDev/bcm-v2-frontend) - Next.js web application
- **ML service:** [bcm-v2-ml](https://github.com/DonatoCorbacioDev/bcm-v2-ml) - FastAPI service for risk scoring, forecasting, anomaly detection and LLM-based clause analysis

### Documentation

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Spring Boot Docker Guide](https://spring.io/guides/topicals/spring-boot-docker/)
- [Next.js Docker Deployment](https://nextjs.org/docs/deployment#docker-image)

---

## 👨‍💻 About

**Author:** Donato Corbacio  
**Email:** donatocorbacio92@gmail.com  
**LinkedIn:** [linkedin.com/in/donato-corbacio](https://www.linkedin.com/in/donato-corbacio/)  
**GitHub:** [@DonatoCorbacioDev](https://github.com/DonatoCorbacioDev)

---

## 📄 License

This project is licensed under a **Custom Non-Commercial License** - see the [LICENSE](./LICENSE) file for full details.

> **This project itself is NOT open source.** It is published as a personal portfolio project under a custom restrictive license. See [LICENSE](./LICENSE) for details.

- ✅ Available for educational and portfolio purposes
- ✅ Free to review and learn from
- ❌ Commercial use prohibited without permission

For commercial licensing: donatocorbacio92@gmail.com

---

## 🙏 Acknowledgments

Thanks to:
- Docker and Docker Compose teams
- Spring Boot and Next.js communities
- MySQL and open-source contributors

---

**⭐ If you're a recruiter or technical reviewer**, this Docker setup demonstrates:
- Multi-service orchestration (MySQL, backend, frontend, ML) with health checks and dependency ordering
- Non-root containers and environment-based secrets (`.env`, git-ignored)
- Database initialization automation via Flyway on backend startup
- Named volumes for data persistence across `docker compose down`

The base compose file is meant for your machine; production adds `docker-compose.prod.yml`, Caddy and the `ops/` scripts (see [Production](#-production)). What is still open is listed in `SECURITY.md`.

**💬 Questions?** Open an issue or reach out via email!
