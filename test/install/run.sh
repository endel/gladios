#!/bin/bash
# install.sh on clean hosts, the way gladios.dev serves it: piped into sh, downloading the release
# website/build.sh makes. Each host has nginx from its own packages and no njs (the nginx image has
# nginx.org's njs package, not loaded). Then one include line, and the page has to be served.
#
#   test/install/run.sh [image …]   (default: all of them)
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
website/build.sh "$tmp/dist" > /dev/null

# nginx and curl, the host's own packages
setup() {
    case $1 in
        debian:* | ubuntu:*) echo 'apt-get update -qq && apt-get install -y -qq --no-install-recommends nginx curl ca-certificates > /dev/null' ;;
        alpine:*) echo 'apk add -q nginx curl' ;;
        *) echo true ;;
    esac
}
images=("$@")
[[ $# -gt 0 ]] || images=(debian:12 ubuntu:24.04 nginx:1.28 alpine:3.22)

# a site to guard: a file, since a `return` would answer before any check
test_site='d=/etc/nginx/http.d; [ -d $d ] || d=/etc/nginx/conf.d
mkdir -p /srv/app && echo "hello from the app" > /srv/app/index.html
printf "server {\n listen 8080;\n root /srv/app;\n include snippets/gladios.conf;\n}\n" > $d/test-app.conf'

fails=0
for image in "${images[@]}"; do
    echo "== $image"
    out=$(docker run --rm -e DEBIAN_FRONTEND=noninteractive -v "$tmp/dist:/dist:ro" "$image" sh -c "
        set -e
        $(setup "$image")
        echo '-- first install'
        GLADIOS_URL=file:///dist/gladios.tar.gz sh < /dist/install.sh
        $test_site
        nginx -t -q
        mkdir -p /run/nginx && nginx
        echo '-- served'
        curl -s localhost:8080/ | grep -o 'Checking your browser'
        curl -s localhost:8080/.gladios/api/challenge | grep -o '\"difficulty\":16'
        echo '-- upgrade'
        echo '# mine' >> /etc/gladios/settings.conf
        GLADIOS_URL=file:///dist/gladios.tar.gz sh < /dist/install.sh
        tail -n 1 /etc/gladios/settings.conf
    " 2>&1) && status=0 || status=$?
    echo "$out" | sed 's/^/    /'
    for want in 'gladios is installed' 'Checking your browser' '"difficulty":16' 'gladios is upgraded' '# mine'; do
        if [[ $status != 0 || $out != *"$want"* ]]; then
            echo "FAIL  $image: no '$want' (exit $status)"
            fails=$((fails + 1))
            break
        fi
    done
done
echo
[[ $fails == 0 ]] && echo "all hosts passed" || echo "$fails hosts FAILED"
exit $((fails > 0))
