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
expect "forged pass"                     "200 challenge" "$(req GET / -H 'Cookie: gladios=1999999999.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')"
expect "malformed pass"                  "200 challenge" "$(req GET / -H 'Cookie: gladios=nope')"
expect "solver script"                   "200 -"         "$(req GET /.gladios/gladios.js)"
expect "worker script"                   "200 -"         "$(req GET /.gladios/worker.js)"

echo "== solving with curl"
jar=$tmp/jar
puzzle=$(curl -sk --resolve "a.gladios.test:$PORT:127.0.0.1" "https://a.gladios.test:$PORT/.gladios/api/challenge")
field() { echo "$puzzle" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
challenge=$(field challenge)
difficulty=$(field difficulty)
expires=$(field expires)
expect "default difficulty"              "16"            "$difficulty"
nonce=$(docker exec "$C" php -r '
    require "/opt/gladios/src/Gladios.php";
    for ($n = 0; ; $n++) {
        $x = base_convert((string) $n, 10, 36);
        if (Gladios\Gladios::leadingZeroBits(hash("sha256", $argv[1] . $x, true)) >= (int) $argv[2]) { echo $x; exit; }
    }' "$challenge" "$difficulty")
expect "wrong nonce"                     "403 -"         "$(req POST /.gladios/api/verify --data "expires=$expires&nonce=zz$nonce")"
expect "verify needs POST"               "405 -"         "$(req GET /.gladios/api/verify)"
expect "challenge needs GET"             "405 -"         "$(req POST /.gladios/api/challenge -d x=1)"
expect "right nonce"                     "204 -"         "$(req POST /.gladios/api/verify -c "$jar" --data "expires=$expires&nonce=$nonce")"
expect "pass shared across gladios.test" "1"             "$(grep -cE $'^(#HttpOnly_)?\\.gladios\\.test\tTRUE\t/\tTRUE\t[0-9]+\tgladios\t' "$jar")"
expect "with the pass"                   "200 app"       "$(req GET /some/page -b "$jar")"
expect "same pass on the sibling host"   "200 app"       "$(ON=b.gladios.test req GET / -b "$jar")"

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

echo
[[ $fails == 0 ]] && echo "all checks passed" || echo "$fails checks FAILED"
exit $((fails > 0))
