# BCM - Business Contracts Manager 🚀

Full-stack application for managing business contracts with automated workflows and real-time analytics.

![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.5-brightgreen)
![Next.js](https://img.shields.io/badge/Next.js-15-black)
![Docker](https://img.shields.io/badge/Docker-Ready-blue)
![License](https://img.shields.io/badge/license-MIT-blue)

## 📦 Architecture

This is the Docker orchestration repository for the BCM project.

### Components

- **Backend**: [bcm-v2-backend](https://github.com/DonatoCorbacioDev/bcm-v2-backend)
  - Spring Boot 3.5, Java 21
  - JWT Authentication & Authorization
  - MySQL 8.0 with Flyway migrations
  - JUnit 5 with 100% test coverage
  - Scheduled jobs for contract expiration
  - Email notifications
  
- **Frontend**: [bcm-v2-frontend](https://github.com/DonatoCorbacioDev/bcm-v2-frontend)
  - Next.js 15, TypeScript, React 19
  - React Query for data fetching
  - Tailwind CSS + shadcn/ui components
  - Responsive design
  - PDF/Excel export functionality

## 🚀 Quick Start with Docker

### Prerequisites
- Docker & Docker Compose installed
- Git

### Installation

1. **Clone all repositories:**
git clone https://github.com/DonatoCorbacioDev/bcm-v2-backend
git clone https://github.com/DonatoCorbacioDev/bcm-v2-frontend
git clone https://github.com/DonatoCorbacioDev/bcm-v2-docker
cd bcm-v2-docker
