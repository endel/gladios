#!/bin/bash
# Sets the container up the way README.md's "Installing" does, then runs php-fpm and nginx.
set -euo pipefail
php=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')

/gladios/install.sh / > /dev/null

adduser --system --group --no-create-home --home /nonexistent gladios > /dev/null
install -d -o root -g root -m 0755 /etc/gladios
head -c 48 /dev/urandom | base64 > /etc/gladios/secret
chown root:gladios /etc/gladios/secret
chmod 0640 /etc/gladios/secret

cat > "/etc/php/$php/fpm/pool.d/gladios.conf" << EOF
[gladios]
user = gladios
group = gladios
listen = /run/php/gladios.sock
listen.owner = www-data
listen.group = www-data
pm = static
pm.max_children = 4
request_terminate_timeout = 5s
php_admin_value[open_basedir] = /opt/gladios/src/:/etc/gladios/
env[GLADIOS_SECRET_FILE] = /etc/gladios/secret
env[GLADIOS_COOKIE_DOMAIN] = gladios.test
EOF

mkdir -p /etc/ssl/gladios-test /var/www/app
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj /CN=a.gladios.test \
    -addext 'subjectAltName=DNS:a.gladios.test,DNS:b.gladios.test' \
    -keyout /etc/ssl/gladios-test/key.pem -out /etc/ssl/gladios-test/cert.pem 2> /dev/null
printf '<!doctype html>\n<title>app</title>\n<p>hello from the app</p>\n' > /var/www/app/index.html

rm -f /etc/nginx/sites-enabled/default
cp /gladios/test/e2e/site.conf /etc/nginx/sites-enabled/gladios-test.conf

mkdir -p /run/php
"php-fpm$php" -t 2> /dev/null
"php-fpm$php" -D
nginx -t 2> /dev/null
echo "ready (nginx $(nginx -v 2>&1 | sed 's|.*/||'), php $php)"
exec nginx -g 'daemon off;'
