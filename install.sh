#!/bin/bash
# Installs gladios under a root directory: a live host's /, or a config tree that mirrors one.
#
#   sudo ./install.sh /                 this host
#   ./install.sh path/to/config-tree    vendor this release into a tree that mirrors a host's /
#
# Copies files only, and never /etc/gladios (the secret, your own page, notify.conf). The host also
# needs (README.md): nginx's njs module, the secret, the deployment's nginx variables, and an nginx
# reload, which is also what picks up a new njs/gladios.js.
set -euo pipefail
dest="${1:?usage: install.sh <root>}"
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
cd "$(dirname "$0")"

install -d "$dest/opt/gladios/njs" "$dest/opt/gladios/public" "$dest/opt/gladios/bin" \
    "$dest/etc/nginx/conf.d" "$dest/etc/nginx/snippets" "$dest/etc/fail2ban/filter.d" "$dest/etc/fail2ban/action.d" \
    "$dest/etc/cron.d"
install -m 0644 njs/gladios.js "$dest/opt/gladios/njs/"
install -m 0644 public/index.html public/gladios.js public/worker.js public/gladios.webp "$dest/opt/gladios/public/"
install -m 0755 bin/gladios-notify "$dest/opt/gladios/bin/"
install -m 0644 nginx/conf.d/gladios.conf "$dest/etc/nginx/conf.d/"
install -m 0644 nginx/snippets/gladios-server.conf nginx/snippets/gladios-protect.conf "$dest/etc/nginx/snippets/"
install -m 0644 fail2ban/filter.d/gladios.conf "$dest/etc/fail2ban/filter.d/"
install -m 0644 fail2ban/action.d/gladios-notify.conf "$dest/etc/fail2ban/action.d/"
install -m 0644 cron.d/gladios-notify "$dest/etc/cron.d/"
echo "installed gladios into $dest"
