# E2E Testing

## Overview

E2E tests run the full stack (postgres, backend, reverse-proxy, frontend) via Docker Compose and exercise the app with Playwright against Firefox.

Tests live in `packages/send/e2e/` and are tagged `@dev-desktop`. The entry point is `scripts/e2e.sh`, invoked by `lerna run test:e2e:ci --scope=send-suite-e2e`.

---

## Why `compose.e2e.yml` exists

The default `compose.yml` mounts named Docker volumes over the node_modules directories inside each container:

```yaml
volumes:
  - ./:/app
  - frontend-node-modules:/app/node_modules
```

This is useful for local development — it preserves `node_modules` across `docker compose down/up` cycles so you don't reinstall on every restart.

**However, in Docker-in-Docker environments** (e.g. devpod, GitHub Actions with DinD), named volumes initialise empty instead of copying from the image layer. The empty volume shadows the node_modules that were installed during `docker build`, leaving packages like `@sentry/vite-plugin` missing at runtime:

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@sentry/vite-plugin'
```

The frontend container exits immediately, the reverse-proxy has nothing to forward to, and the e2e script waits forever for `https://localhost:8088/`.

### Solution

`compose.e2e.yml` is a variant of `compose.yml` with all named node_modules volumes and source bind mounts removed. Containers run directly from their built image layers, which always contain the correct node_modules.

Key differences from `compose.yml`:

| Service  | Removed mounts |
|----------|----------------|
| frontend | `./:/app`, `frontend-node-modules:/app/node_modules` |
| backend  | `./packages/send/backend:/app`, `backend-node-modules:/app/node_modules` |

The `postgres-data` volume is kept so the database persists across test retries within the same run.

---

## Path resolution in `scripts/e2e.sh`

`lerna run test:e2e:ci` executes `scripts/e2e.sh` with the working directory set to `packages/send/e2e/`, not the repo root. All paths in the script are resolved relative to the script's own location using:

```bash
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
```

This ensures `compose.e2e.yml`, the playwright config, and the playwright install target are found correctly regardless of where the script is invoked from.

---

## Running locally

From the repo root:

```bash
bash scripts/e2e.sh
```

Or via lerna (as CI does):

```bash
lerna run test:e2e:ci --scope=send-suite-e2e
```

The script will:
1. Install Playwright browsers
2. Build and start the stack with `compose.e2e.yml`
3. Wait for `https://localhost:8088/` (reverse-proxy) and `http://localhost:5173/send` (vite)
4. Run Playwright tests tagged `@dev-desktop` against Firefox
5. Upload a report artifact on completion
