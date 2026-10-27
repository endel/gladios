#!/bin/bash
# Load test against a test/e2e image: the server pinned to SERVER_CPUS, oha on CLIENT_CPUS, over
# TLS keep-alive connections like a browser's. Per scenario, the most it serves (CONC connections)
# and what a steady RATE costs it in CPU.
#
#   test/bench/run.sh [image]   (default: gladios-e2e, built from this tree)
#
# SERVER_CPUS (0,1), CLIENT_CPUS (2-7), CONC (64), RATE (1000 req/s), DURATION (10s).
set -euo pipefail
cd "$(dirname "$0")/../.."
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2-7}
CONC=${CONC:-64}
RATE=${RATE:-1000}
DURATION=${DURATION:-10s}
NET=gladios-bench
S=gladios-bench-server
L=gladios-bench-load
URL=https://a.gladios.test

image=${1:-}
if [[ -z $image ]]; then
    docker build -q -t gladios-e2e -f test/e2e/Dockerfile . > /dev/null
    image=gladios-e2e
fi
docker build -q -t gladios-bench-load -f test/bench/Dockerfile . > /dev/null

cleanup() { docker rm -f "$S" "$L" > /dev/null 2>&1 || true; docker network rm "$NET" > /dev/null 2>&1 || true; }
cleanup
trap cleanup EXIT
docker network create "$NET" > /dev/null
docker run -d --name "$S" --network "$NET" --cpuset-cpus "$SERVER_CPUS" "$image" > /dev/null
docker run -d --name "$L" --network "$NET" --cpuset-cpus "$CLIENT_CPUS" --entrypoint sleep gladios-bench-load infinity > /dev/null
for _ in $(seq 60); do docker logs "$S" 2>&1 | grep -q '^ready' && break; sleep 1; done
echo "$(docker logs "$S" 2>&1 | grep '^ready'), server on CPUs $SERVER_CPUS"

# Nothing here is a flood to ban, and fail2ban tailing the logs would compete for the server's
# CPUs. One nginx worker per pinned CPU, and no limit on /.gladios/api, so its cost shows: limit_req
# turns away more than burst+1 requests from one address within the same millisecond, whatever the rate.
docker exec "$S" sh -c 'fail2ban-client -q stop > /dev/null
    sed -i "s/^worker_processes .*/worker_processes $(nproc);/" /etc/nginx/nginx.conf
    sed -i "/limit_req zone=gladios/d" /etc/nginx/snippets/gladios-server.conf
    nginx -s reload 2> /dev/null'
sleep 2

load() { docker exec "$L" "$@"; }
fetch() { load curl -sk --connect-to "a.gladios.test:443:$S:443" "$@"; }
# a solved puzzle: "expires=…&nonce=…", good for PUZZLE_TTL (300 s)
solution() {
    local puzzle challenge difficulty expires
    puzzle=$(fetch "$URL/.gladios/api/challenge")
    read -r challenge difficulty expires < <(echo "$puzzle" | python3 -c 'import json, sys; p = json.load(sys.stdin); print(p["challenge"], p["difficulty"], p["expires"])')
    echo "expires=$expires&nonce=$(load python3 /solve.py "$challenge" "$difficulty")"
}
cpu_usec() { docker exec "$S" awk '$1 == "usage_usec" { print $2 }' /sys/fs/cgroup/cpu.stat; }

# -> "<req/s> <p50 ms> <p99 ms> <statuses>"
summary() {
    python3 -c 'import json, sys
r = json.load(sys.stdin)
codes = " ".join("%s:%d" % kv for kv in sorted(r["statusCodeDistribution"].items()))
# oha cuts the connections still open when the time is up
errors = sum(n for e, n in r.get("errorDistribution", {}).items() if "deadline" not in e)
p = r["latencyPercentiles"]
print("%.0f %.2f %.2f %s%s" % (r["summary"]["requestsPerSec"], p["p50"] * 1000, p["p99"] * 1000, codes, " errors:%d" % errors if errors else ""))'
}

scenario() {
    local name=$1 max at_rate before after
    shift
    oha() { load oha --no-tui --insecure --output-format json --connect-to "a.gladios.test:443:$S:443" "$@"; }
    oha -z 2s -c "$CONC" "$@" > /dev/null  # warm-up
    read -r max_rps max_p50 max_p99 max_codes < <(oha -z "$DURATION" -c "$CONC" "$@" | summary)
    before=$(cpu_usec)
    read -r _ rate_p50 rate_p99 rate_codes < <(oha -z "$DURATION" -c "$CONC" -q "$RATE" "$@" | summary)
    after=$(cpu_usec)
    local cores
    cores=$(python3 -c "print('%.2f' % (($after - $before) / 1e6 / ${DURATION%s}))")
    printf '%-10s %8s %8s %8s   %6s %8s %8s   %s | %s\n' "$name" "$max_rps" "$max_p50" "$max_p99" "$cores" "$rate_p50" "$rate_p99" "$max_codes" "$rate_codes"
}

FORGED='1999999999.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
pass=$(fetch -o /dev/null -D - -d "$(solution)" "$URL/.gladios/api/verify" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: gate=\([^;]*\).*/\1/p')
[[ -n $pass ]] || { echo "couldn't get a pass" >&2; exit 1; }

printf '\n%-10s %8s %8s %8s   %6s %8s %8s\n' "" "max" "p50" "p99" "at $RATE/s:" "p50" "p99"
printf '%-10s %8s %8s %8s   %6s %8s %8s   %s\n' "scenario" "req/s" "ms" "ms" "cores" "ms" "ms" "statuses (max | rate)"
# a file that exists: test/e2e/site.conf's try_files fallback would re-enter the location, and check twice
scenario pass      -H "Cookie: gate=$pass" "$URL/index.html"
scenario forged    -H "Cookie: gate=$FORGED" "$URL/"
scenario none      "$URL/"
scenario challenge "$URL/.gladios/api/challenge"
scenario verify    -m POST -T application/x-www-form-urlencoded -d "$(solution)" "$URL/.gladios/api/verify"

echo
echo "memory after the runs (PSS, MB):"
# --privileged: reading another user's smaps (the workers') takes CAP_SYS_PTRACE
docker exec --privileged "$S" sh -c 'for p in /proc/[0-9]*; do
        pss=$(awk "/^Pss:/ { print \$2 }" "$p/smaps_rollup" 2> /dev/null) || continue
        [ -n "$pss" ] && echo "$(cat "$p/comm" 2> /dev/null) $pss"
    done; true' | LC_ALL=C awk '{ kb[$1] += $2; n[$1]++ } END { for (c in kb) printf "  %-16s %2d processes %6.1f\n", c, n[c], kb[c] / 1024 }' | sort -k4 -rn
