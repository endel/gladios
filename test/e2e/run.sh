#!/bin/bash
# gladios in Docker (Debian 12's nginx and njs, test/e2e/site.conf): the unit tests, then the checks
# and real browsers through it. Needs docker, curl, python3, and node with `npm install` done.
#
#   test/e2e/run.sh [up|unit|checks|browser|down|all]   (default: all)
#
# PORT (default 8444) is published on 127.0.0.1; SHOTS keeps the browser test's screenshots.
set -euo pipefail
cd "$(dirname "$0")/../.."
PORT=${PORT:-8444}
C=gladios-e2e

up() {
    docker build -q -t gladios-e2e -f test/e2e/Dockerfile . > /dev/null
    down
    docker run -d --name "$C" -p "127.0.0.1:$PORT:443" gladios-e2e > /dev/null
    for _ in $(seq 60); do
        docker logs "$C" 2>&1 | grep '^ready' && return 0
        [[ $(docker inspect -f '{{.State.Running}}' "$C") == true ]] || break
        sleep 1
    done
    docker logs "$C"
    return 1
}
down() { docker rm -f "$C" > /dev/null 2>&1 || true; }
unit() { docker run --rm --entrypoint njs gladios-e2e -p /gladios/njs /gladios/test/unit.js; }
browser() {
    HOSTS=a.gladios.test,b.gladios.test node test/browser.mjs "https://a.gladios.test:$PORT" "https://b.gladios.test:$PORT/" ${SHOTS:+"$SHOTS"}
}

case "${1:-all}" in
    up) up ;;
    unit) unit ;;
    checks) test/e2e/checks.sh "$C" "$PORT" ;;
    browser) browser ;;
    down) down ;;
    all) up && unit && test/e2e/checks.sh "$C" "$PORT" && sleep 30 && browser ;;
    *) echo "usage: test/e2e/run.sh [up|unit|checks|browser|down|all]" >&2; exit 64 ;;
esac
