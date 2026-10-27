#!/bin/sh
# Installs gladios, or upgrades it in place.
#
#   curl -fsSL https://gladios.dev/install.sh | sudo sh   this host, the latest release
#   sudo ./install.sh                                      this host, from this checkout
#   ./install.sh path/to/tree                              files only, into a tree that mirrors a host's /
#
# On this host it also gets nginx's njs module loaded (installing its package if needed) and writes
# /etc/gladios/secret.conf and /etc/gladios/settings.conf unless they exist. It never overwrites
# anything in /etc/gladios and never reloads nginx. If `nginx -t` fails with the new files, it puts
# the old ones back.
#
# POSIX sh, for hosts without bash. Defined as functions and run on the last line, so a download
# cut short runs nothing.
set -eu

# what's downloaded when this script isn't beside a checkout (gladios.dev builds it from main)
GLADIOS_URL=${GLADIOS_URL:-https://gladios.dev/gladios.tar.gz}

fail() {
    echo "gladios: $*" >&2
    exit 1
}

# nginx -V's value for --<option>
built_with() { nginx -V 2>&1 | tr ' ' '\n' | sed -n "s/^--$1=//p"; }

# Copies the release in $1 under the root $2, the http-level config into etc/nginx/$3 (conf.d).
copy() {
    local src=$1 dest=$2 http=${3:-conf.d}
    install -d "$dest/opt/gladios/njs" "$dest/opt/gladios/public" "$dest/opt/gladios/bin" \
        "$dest/etc/nginx/$http" "$dest/etc/nginx/snippets" "$dest/etc/fail2ban/filter.d" "$dest/etc/fail2ban/action.d" \
        "$dest/etc/cron.d"
    install -m 0644 "$src/njs/gladios.js" "$dest/opt/gladios/njs/"
    install -m 0644 "$src/public/index.html" "$src/public/gladios.js" "$src/public/worker.js" "$src/public/gladios.webp" "$dest/opt/gladios/public/"
    install -m 0755 "$src/bin/gladios-notify" "$src/bin/gladios-gate" "$src/bin/gladios-auto" "$dest/opt/gladios/bin/"
    install -m 0644 "$src/nginx/conf.d/gladios.conf" "$dest/etc/nginx/$http/"
    install -m 0644 "$src/nginx/snippets/gladios.conf" "$src/nginx/snippets/gladios-server.conf" "$src/nginx/snippets/gladios-protect.conf" "$dest/etc/nginx/snippets/"
    install -m 0644 "$src/fail2ban/filter.d/gladios.conf" "$dest/etc/fail2ban/filter.d/"
    install -m 0644 "$src/fail2ban/action.d/gladios-notify.conf" "$dest/etc/fail2ban/action.d/"
    install -m 0644 "$src/cron.d/gladios-notify" "$dest/etc/cron.d/"
    # gladios-auto's unit: into any tree (it may be a host's config), and on a host run by systemd
    if [ "$dest" != / ] || [ -d /run/systemd/system ]; then
        install -d "$dest/etc/systemd/system"
        install -m 0644 "$src/systemd/gladios-auto.service" "$dest/etc/systemd/system/"
    fi
}

# nginx -T prints every file it reads, the distro's modules-enabled/*.conf included
njs_loaded() {
    local dump
    case $(built_with add-module) in *njs*) return 0 ;; esac
    dump=$(nginx -T 2> /dev/null) || return 1
    printf '%s\n' "$dump" | grep -qE '^[[:space:]]*load_module[[:space:]]+[^[:space:]]*ngx_http_js_module\.so'
}

install_njs() {
    if command -v apt-get > /dev/null; then
        # Debian's and Ubuntu's own nginx comes with nginx-common; nginx.org's doesn't
        local pkg=nginx-module-njs
        case $(dpkg-query -W -f '${Status}' nginx-common 2> /dev/null) in *' installed') pkg=libnginx-mod-http-js ;; esac
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" > /dev/null
    elif command -v apk > /dev/null; then
        apk add -q nginx-mod-http-js
    elif command -v dnf > /dev/null; then
        dnf install -y -q nginx-module-njs
    elif command -v yum > /dev/null; then
        yum install -y -q nginx-module-njs
    else
        return 1
    fi
}

need_njs() {
    local conf so
    njs_loaded && return
    echo "Installing nginx's njs module…"
    install_njs || fail "couldn't install nginx's njs module, see https://gladios.dev/#requirements"
    njs_loaded && return
    # nginx.org's package leaves the loading to nginx.conf
    conf=$(built_with conf-path)
    conf=${conf:-/etc/nginx/nginx.conf}
    so=$(built_with modules-path)
    so=${so:-$(dirname "$conf")/modules}/ngx_http_js_module.so
    [ -f "$so" ] || fail "njs is installed, but $so isn't there to load"
    { echo "load_module $so;"; cat "$conf"; } > "$conf.gladios"
    cat "$conf.gladios" > "$conf"
    rm -f "$conf.gladios"
    echo "Added \`load_module $so;\` atop $conf"
    njs_loaded || fail "nginx still doesn't load njs: check $conf"
}

# The secret, the settings and the switch (on, as gladios-gate leaves it): written once, then the
# host's own
etc_gladios() {
    install -d -m 0755 /etc/gladios
    if [ ! -e /etc/gladios/secret.conf ]; then
        (umask 077 && printf 'js_var $gladios_secret "%s";\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n')" > /etc/gladios/secret.conf)
    fi
    [ -e /etc/gladios/settings.conf ] || install -m 0644 "$1/nginx/settings.conf" /etc/gladios/settings.conf
    [ -e /etc/gladios/switch.conf ] || install -m 0644 "$1/nginx/switch.conf" /etc/gladios/switch.conf
}

# Where http-level config goes: conf.d/, but Alpine's nginx reads that at the top level and http.d/
# inside http { }
http_dir() {
    local conf
    conf=$(built_with conf-path)
    if grep -qsE '^[[:space:]]*include[[:space:]]+/etc/nginx/http\.d/' "${conf:-/etc/nginx/nginx.conf}"; then
        echo http.d
    else
        echo conf.d
    fi
}

# The files nginx reads, put back as they were if nginx -t fails with the new ones
save() {
    local f
    saved=$(mktemp -d)
    for f in "$@"; do
        if [ -e "$f" ]; then cp -p "$f" "$saved/$(echo "$f" | tr / _)"; fi
    done
}
restore() {
    local f
    for f in "$@"; do
        if [ -e "$saved/$(echo "$f" | tr / _)" ]; then
            cp -p "$saved/$(echo "$f" | tr / _)" "$f"
        else
            rm -f "$f"
        fi
    done
}

# nginx -t, quiet unless it fails: njs logs a notice for every VM it starts
nginx_ok() {
    local out
    out=$(nginx -t -q 2>&1) && return
    echo "$out" >&2
    return 1
}

host() {
    local src=$1 upgrade=0 http files
    [ "$(id -u)" = 0 ] || fail "run it as root (sudo), or give it a directory to install into"
    command -v nginx > /dev/null || fail "install nginx first"
    nginx_ok || fail "fix the errors above first: nginx -t fails before gladios changes anything"
    [ -e /opt/gladios/njs/gladios.js ] && upgrade=1

    need_njs
    etc_gladios "$src"
    http=$(http_dir)
    files="/etc/nginx/$http/gladios.conf /etc/nginx/snippets/gladios.conf /etc/nginx/snippets/gladios-server.conf
        /etc/nginx/snippets/gladios-protect.conf /opt/gladios/njs/gladios.js"
    save $files
    copy "$src" / "$http"
    if ! nginx_ok; then
        restore $files
        fail "nginx -t fails with this version (errors above), so the files it replaced are back"
    fi
    rm -rf "$saved"
    install -d /usr/local/sbin
    ln -sf /opt/gladios/bin/gladios-gate /usr/local/sbin/gladios-gate
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload
        # an upgrade's gladios-auto runs from here on, if it ran before
        systemctl try-restart gladios-auto
    fi

    echo
    if ! nginx -T 2> /dev/null | grep -q "^# configuration file /etc/nginx/$http/gladios.conf:"; then
        echo "Your nginx.conf doesn't read /etc/nginx/$http/. Add this inside its http { }:"
        echo
        echo "    include /etc/nginx/$http/gladios.conf;"
        echo
    fi
    if [ $upgrade = 1 ]; then
        echo "gladios is upgraded. Reload nginx to run it: nginx -t && systemctl reload nginx"
        return
    fi
    echo "gladios is installed. Add this line to each server { } it should guard:"
    echo
    echo "    include snippets/gladios.conf;"
    echo
    echo "then reload nginx: nginx -t && systemctl reload nginx"
    echo "Who gets checked, and the rest: /etc/gladios/settings.conf"
}

main() {
    local dest=${1:-/} src
    src=$(dirname "$0")
    if [ -f "$src/njs/gladios.js" ]; then
        src=$(cd "$src" && pwd)
    else
        command -v curl > /dev/null || fail "needs curl to download $GLADIOS_URL"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        curl -fsSL "$GLADIOS_URL" -o "$tmp/gladios.tar.gz" || fail "couldn't download $GLADIOS_URL"
        tar -xzf "$tmp/gladios.tar.gz" -C "$tmp"
        src=$tmp/gladios
    fi
    mkdir -p "$dest"
    dest=$(cd "$dest" && pwd)
    if [ "$dest" = / ]; then
        host "$src"
    else
        copy "$src" "$dest"
        echo "installed gladios into $dest"
    fi
}

main "$@"
