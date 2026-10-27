#!/bin/bash
# Assertions against a running test/e2e container.
#   test/e2e/checks.sh <container> <port>
set -uo pipefail
C=$1
PORT=$2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

# -> "<status> <challenge|app|->", from host a (or $ON)
req() {
    local host=${ON:-a.gladios.test} method=$1 path=$2 code what=-
    shift 2
    code=$(curl -sk -X "$method" -o "$tmp/body" -D "$tmp/head" -w '%{http_code}' \
        --resolve "$host:$PORT:127.0.0.1" "$@" "https://$host:$PORT$path")
    if grep -q '/.gladios/gladios.js' "$tmp/body"; then
        what=challenge
    elif grep -q 'hello from the app' "$tmp/body"; then
        what=app
    fi
    echo "$code $what"
}
header() { tr -d '\r' < "$tmp/head" | awk -F': ' -v h="$1" 'tolower($1) == h { print $2 }'; }
expect() {
    if [[ $3 == "$2" ]]; then
        echo "ok    $1  ($3)"
    else
        echo "FAIL  $1: want '$2', got '$3'"
        fails=$((fails + 1))
    fi
}
# a reload returns before the old workers retire
reload() { docker exec "$C" nginx -s reload 2> /dev/null && sleep 1; }

echo "== who gets checked"
expect "anonymous GET /"                 "200 challenge" "$(req GET /)"
expect "anonymous GET, any path"         "200 challenge" "$(req GET /some/page?q=1)"
expect "anonymous POST"                  "200 challenge" "$(req POST /form -d a=b)"
expect "HEAD"                            "200 -"         "$(req HEAD / -I)"
expect "page is never cached"            "no-store"      "$(req GET / > /dev/null; header cache-control)"
expect "bypassed path (/api/)"           "200 app"       "$(req GET /api/thing)"
expect "the host itself"                 "200"           "$(docker exec "$C" curl -sk -o /dev/null -w '%{http_code}' --resolve a.gladios.test:443:127.0.0.1 https://a.gladios.test/)"
expect "solver script"                   "200 -"         "$(req GET /.gladios/gladios.js)"
expect "worker script"                   "200 -"         "$(req GET /.gladios/worker.js)"

FORGED='1999999999.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
echo "== forged and malformed passes (cookie: gate)"
strikes() { docker exec "$C" sh -c 'wc -l < /var/log/nginx/gladios-strikes.log'; }
s0=$(strikes)
expect "no cookie"                       "200 challenge" "$(req GET /)"
expect "  no strike"                     "0"             "$(($(strikes) - s0))"
s0=$(strikes)
expect "malformed pass"                  "200 challenge" "$(req GET / -H 'Cookie: gate=nope')"
expect "  a strike"                      "1"             "$(($(strikes) - s0))"
s0=$(strikes)
expect "forged pass"                     "200 challenge" "$(req GET / -H "Cookie: gate=$FORGED")"
expect "  a strike"                      "1"             "$(($(strikes) - s0))"
s0=$(strikes)
expect "the default name, unused here"   "200 challenge" "$(req GET / -H "Cookie: gladios=$FORGED")"
expect "  is just another cookie"        "0"             "$(($(strikes) - s0))"
expect "strike line"                     "yes"           "$(docker exec "$C" tail -n 1 /var/log/nginx/gladios-strikes.log | grep -qE '^[0-9T:+-]+ strike [0-9a-f.:]+ a\.gladios\.test "GET /" ' && echo yes || echo no)"
expect "fail2ban's filter reads it"      "yes"           "$(docker exec "$C" fail2ban-regex /var/log/nginx/gladios-strikes.log gladios | grep -qE '^Lines: .*[1-9][0-9]* matched' && echo yes || echo no)"

echo "== solving with curl"
jar=$tmp/jar
puzzle=$(curl -sk --resolve "a.gladios.test:$PORT:127.0.0.1" "https://a.gladios.test:$PORT/.gladios/api/challenge")
field() { echo "$puzzle" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
challenge=$(field challenge)
difficulty=$(field difficulty)
expires=$(field expires)
expect "default difficulty"              "16"            "$difficulty"
nonce=$(docker exec "$C" python3 /gladios/test/solve.py "$challenge" "$difficulty")
expect "wrong nonce"                     "403 -"         "$(req POST /.gladios/api/verify --data "expires=$expires&nonce=zz$nonce")"
expect "verify needs POST"               "405 -"         "$(req GET /.gladios/api/verify)"
expect "challenge needs GET"             "405 -"         "$(req POST /.gladios/api/challenge -d x=1)"
expect "right nonce"                     "204 -"         "$(req POST /.gladios/api/verify -c "$jar" --data "expires=$expires&nonce=$nonce")"
expect "  Secure, HttpOnly, Lax, a week"  "yes"         "$([[ $(header set-cookie) =~ \;\ Max-Age=604800\;\ .*Secure\;\ HttpOnly\;\ SameSite=Lax$ ]] && echo yes || echo no)"
expect "pass named gate, for gladios.test" "1"           "$(grep -cE $'^(#HttpOnly_)?\\.gladios\\.test\tTRUE\t/\tTRUE\t[0-9]+\tgate\t' "$jar")"
expect "with the pass"                   "200 app"       "$(req GET /some/page -b "$jar")"
expect "same pass on the sibling host"   "200 app"       "$(ON=b.gladios.test req GET / -b "$jar")"
# the documented scheme, by hand: passes from another implementation or host carry over
me=$(docker exec "$C" tail -n 1 /var/log/nginx/gladios-strikes.log | awk '{ print $3 }')
secret=$(docker exec "$C" sed -E 's/^[^"]*"([^"]*)".*/\1/' /etc/gladios/secret.conf)
minted=$(python3 -c 'import base64, hashlib, hmac, sys, time
e = int(time.time()) + 60
m = hmac.new(sys.argv[1].encode(), ("pass|%s|%d" % (sys.argv[2], e)).encode(), hashlib.sha256).digest()
print("%d.%s" % (e, base64.urlsafe_b64encode(m).rstrip(b"=").decode()))' "$secret" "$me")
expect "a pass minted by hand"           "200 app"       "$(req GET / -H "Cookie: gate=$minted")"

echo "== your own mascot"
expect "default mascot"                  "image/webp"    "$(req GET /.gladios/mascot > /dev/null; header content-type)"
docker exec "$C" sh -c 'mkdir -p /etc/gladios/site && printf "<svg xmlns=\"http://www.w3.org/2000/svg\"/>" > /etc/gladios/site/mascot.svg'
expect "yours instead"                   "image/svg+xml" "$(req GET /.gladios/mascot > /dev/null; header content-type)"
expect "can't run scripts if opened"     "yes"           "$(req GET /.gladios/mascot > /dev/null; [[ $(header content-security-policy) == *sandbox* ]] && echo yes || echo no)"
docker exec "$C" rm -f /etc/gladios/site/mascot.svg
expect "default again once removed"      "image/webp"    "$(req GET /.gladios/mascot > /dev/null; header content-type)"

echo "== your own page"
docker exec "$C" sh -c 'mkdir -p /etc/gladios/site &&
    printf "<!doctype html><title>Custom</title><img src=/.gladios/site/logo.txt><span id=status></span><button class=retry></button><script src=/.gladios/gladios.js defer></script>" > /etc/gladios/site/index.html &&
    echo logo > /etc/gladios/site/logo.txt'
expect "replaces the default"            "Custom"        "$(req GET / > /dev/null; grep -o '<title>[^<]*' "$tmp/body" | sed 's/<title>//')"
expect "its assets"                      "200 -"         "$(req GET /.gladios/site/logo.txt)"
docker exec "$C" rm -rf /etc/gladios/site
expect "default again once removed"      "Checking your browser" "$(req GET / > /dev/null; grep -o '<title>[^<]*' "$tmp/body" | sed 's/<title>//')"

echo "== the switch"
docker exec "$C" sed -i 's/default 1;/default 0;/' /etc/nginx/sites-enabled/gladios-test.conf && reload
expect "off: straight through"           "200 app"       "$(req GET /)"
docker exec "$C" sed -i 's/default 0;/default 1;/' /etc/nginx/sites-enabled/gladios-test.conf && reload
expect "on again"                        "200 challenge" "$(req GET /)"

# drains the bucket: a re-run within ~30 s may get 429s while solving
echo "== rate limit on /.gladios/api"
codes=$(for _ in $(seq 60); do curl -sk -o /dev/null -w '%{http_code}\n' --resolve "a.gladios.test:$PORT:127.0.0.1" "https://a.gladios.test:$PORT/.gladios/api/challenge"; done | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
echo "      60 rapid challenges: $codes"
expect "some 429s"                       "yes"           "$([[ $codes == *429* ]] && echo yes || echo no)"

echo "== bans and their notification"
hooks() { docker exec "$C" sh -c 'ls /tmp/hook-*.json 2> /dev/null | wc -l'; }
notify() { docker exec "$C" /opt/gladios/bin/gladios-notify; }
conf() { docker exec "$C" sh -c "printf 'webhook = \"http://127.0.0.1:9999/hook\"\nformat = $1\nsamples[] = /var/log/nginx/gladios-strikes.log\n' > /etc/gladios/notify.conf"; }
# what a forger would hope to slip into a chat: a mention and a broken code span
UA='<!channel> `pwned` @everyone'
for _ in $(seq 25); do curl -sk -o /dev/null -A "$UA" -H "Cookie: gate=$FORGED" --resolve "a.gladios.test:$PORT:127.0.0.1" "https://a.gladios.test:$PORT/"; done
me=$(docker exec "$C" tail -n 1 /var/log/nginx/gladios-strikes.log | awk '{ print $3 }')
for _ in $(seq 20); do docker exec "$C" fail2ban-client status gladios | grep -q "$me" && break; sleep 1; done
expect "25 forged passes: banned"        "yes"           "$(docker exec "$C" fail2ban-client status gladios | grep -q "$me" && echo yes || echo no)"
expect "recorded for the notifier"       "gladios $me"   "$(docker exec "$C" tail -n 1 /var/log/gladios/bans.log | awk '{ print $2, $3 }')"
expect "no webhook configured: quiet"    "0"             "$(notify; hooks)"
conf slack
notify
expect "slack: posted once"              "1"             "$(hooks)"
slack=$(docker exec "$C" cat /tmp/hook-1.json)
expect "  names the address"             "yes"           "$([[ $slack == *"\`$me\`"* ]] && echo yes || echo no)"
expect "  quotes what it sent"           "yes"           "$([[ $slack == *'strike '"$me"' a.gladios.test'* ]] && echo yes || echo no)"
expect "  defuses the mention"           "yes"           "$([[ $slack == *'&lt;!channel&gt;'* && $slack != *'<!channel>'* ]] && echo yes || echo no)"
expect "  keeps code spans whole"        "yes"           "$([[ $slack == *"'pwned'"* ]] && echo yes || echo no)"
expect "nothing new: no post"            "1"             "$(notify; hooks)"
docker exec "$C" sh -c "echo '2026-01-01T00:00:00Z nginx-limit-req 203.0.113.9 60' >> /var/log/gladios/bans.log && touch /tmp/hook-fail"
expect "webhook down: fails"             "1 1"           "$(notify 2> /dev/null; echo "$? $(hooks)")"
docker exec "$C" rm /tmp/hook-fail
conf json
notify
expect "  retried on the next run"       "2"             "$(hooks)"
expect "json: the ban"                   "203.0.113.9 nginx-limit-req 1" "$(docker exec "$C" cat /tmp/hook-2.json | python3 -c 'import json, sys; p = json.load(sys.stdin); print(p["bans"][0]["ip"], p["bans"][0]["jail"], p["total"])')"
conf discord
docker exec "$C" sh -c "echo '2026-01-01T00:00:01Z gladios 203.0.113.10 20' >> /var/log/gladios/bans.log"
notify
expect "discord: no pings"               "[]"            "$(docker exec "$C" cat /tmp/hook-3.json | python3 -c 'import json, sys; print(json.load(sys.stdin)["allowed_mentions"]["parse"])')"
docker exec "$C" sh -c 'fail2ban-client unban --all > /dev/null; rm -f /etc/gladios/notify.conf'

echo
[[ $fails == 0 ]] && echo "all checks passed" || echo "$fails checks FAILED"
exit $((fails > 0))
