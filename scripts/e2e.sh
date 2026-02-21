#!/bin/bash

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Install browser dependencies
echo "Installing browser dependencies..."
cd "$REPO_ROOT/packages/send"
pnpm exec playwright install
cd "$REPO_ROOT"

pwd

# Start dev server in background
if [ "$IS_CI_AUTOMATION" = "yes" ]; then
  BUILD_ENV=production docker compose -f "$REPO_ROOT/compose.ci.yml" up -d --build
  # When running inside a container (DinD), published ports bind to the docker host,
  # not the container's localhost. Reach them via the bridge gateway.
  DOCKER_HOST=$(ip route show default | awk '{print $3; exit}')
  echo "Docker host gateway: $DOCKER_HOST"
else
  pnpm dev:detach
  DOCKER_HOST="localhost"
fi

# Function to cleanup dev server on script exit
cleanup() {
  kill $DOCKER_LOGS_PID 2>/dev/null
}
trap cleanup INT TERM

# Wait for servers to be ready
echo "Waiting for dev servers..."
echo "--- docker compose ps ---"
docker compose -f "$REPO_ROOT/compose.ci.yml" ps 2>&1 || docker compose ps 2>&1
echo "--- initial curl probe (verbose) ---"
curl -v -k --max-time 5 "https://${DOCKER_HOST}:8088/" 2>&1 || true
echo "--- end probe ---"
START_TIME=$(date +%s)
LAST_LOG_TIME=0
while true; do
  STATUS=$(curl -s -k -w "%{http_code}" --max-time 5 "https://${DOCKER_HOST}:8088/" -o /dev/null)
  if [ "$STATUS" = "200" ]; then
    break
  fi

  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  # Log every 30 seconds with container status
  if [ $((ELAPSED - LAST_LOG_TIME)) -ge 30 ]; then
    echo "Waiting for HTTPS server... (${ELAPSED}s elapsed, curl status: ${STATUS})"
    docker compose -f "$REPO_ROOT/compose.ci.yml" ps 2>&1 || docker compose ps 2>&1
    LAST_LOG_TIME=$ELAPSED
  fi

  sleep 1
done
echo "HTTPS server is ready"

# Start docker logs in background
if [ "$IS_CI_AUTOMATION" = "yes" ]; then
  docker compose -f "$REPO_ROOT/compose.ci.yml" logs -f &
else
  docker compose logs -f &
fi
DOCKER_LOGS_PID=$!

while true; do
  RESPONSE=$(curl -s "http://${DOCKER_HOST}:5173/send")
  if [ -n "$RESPONSE" ] && [[ "$RESPONSE" == *"<title>Thunderbird Send</title>"* ]]; then
    echo $RESPONSE
    break
  fi
  # log the response for debugging
  echo $RESPONSE
  echo "Waiting for Vite dev server..."
  sleep 1
done
echo "Vite dev server is ready"


# Run tests in parallel with docker logs
pnpm exec playwright test --grep dev-desktop --config "$REPO_ROOT/packages/send/e2e/playwright.config.dev.ts" &
PLAYWRIGHT_PID=$!

# Wait for tests to complete
wait $PLAYWRIGHT_PID
PLAYWRIGHT_EXIT_CODE=$?

if [ $PLAYWRIGHT_EXIT_CODE -ne 0 ]; then
    echo "Playwright tests failed with exit code $PLAYWRIGHT_EXIT_CODE"
    kill $DOCKER_LOGS_PID
    cleanup
    exit $PLAYWRIGHT_EXIT_CODE
fi

echo "Finished running tests"

# Kill docker logs process
kill $DOCKER_LOGS_PID

# Cleanup
cleanup
