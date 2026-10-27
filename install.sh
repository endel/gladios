#!/bin/bash
# Installs gladios under a root directory: a live host's /, or a config tree that mirrors one.
#
#   sudo ./install.sh /                 this host
#   ./install.sh path/to/config-tree    vendor this release into a tree that mirrors a host's /
#
# Copies files only, and never /etc/gladios (the secret, your own page). The host also needs
# (README.md): the secret, a php-fpm pool, $gladios_enabled / $gladios_bypass / gladios_php, and
# an nginx reload. With opcache.validate_timestamps=0, a changed src/ needs a php-fpm reload too.
set -euo pipefail
dest="${1:?usage: install.sh <root>}"
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
cd "$(dirname "$0")"

install -d "$dest/opt/gladios/src" "$dest/opt/gladios/public" "$dest/etc/nginx/conf.d" "$dest/etc/nginx/snippets"
install -m 0644 src/Gladios.php src/fcgi.php "$dest/opt/gladios/src/"
install -m 0644 public/index.html public/gladios.js public/worker.js public/gladios.webp "$dest/opt/gladios/public/"
install -m 0644 nginx/conf.d/gladios.conf "$dest/etc/nginx/conf.d/"
install -m 0644 nginx/snippets/gladios-server.conf nginx/snippets/gladios-protect.conf "$dest/etc/nginx/snippets/"
echo "installed gladios into $dest"
