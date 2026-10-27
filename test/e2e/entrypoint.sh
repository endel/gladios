#!/bin/bash
# The rest of the setup README.md's "Installing" describes (the image ran install.sh), then nginx.
set -euo pipefail

cp /gladios/test/e2e/settings.conf /etc/gladios/settings.conf

# fail2ban with a ban action that only records: the container has no firewall to drive
rm -f /etc/fail2ban/jail.d/defaults-debian.conf
cat > /etc/fail2ban/jail.d/gladios.local << EOF
[gladios]
enabled   = true
filter    = gladios
logpath   = /var/log/nginx/gladios-strikes.log
backend   = polling
findtime  = 60
maxretry  = 20
bantime   = 600
banaction = dummy
action    = %(action_)s
            gladios-notify[name=%(__name__)s]
EOF
touch /var/log/nginx/gladios-strikes.log

# the webhook gladios-notify posts to (checks.sh writes notify.conf)
python3 /gladios/test/e2e/receiver.py > /dev/null 2>&1 &

mkdir -p /etc/ssl/gladios-test /var/www/app
openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj /CN=a.gladios.test \
    -addext 'subjectAltName=DNS:a.gladios.test,DNS:b.gladios.test,DNS:c.gladios.test' \
    -keyout /etc/ssl/gladios-test/key.pem -out /etc/ssl/gladios-test/cert.pem 2> /dev/null
printf '<!doctype html>\n<title>app</title>\n<p>hello from the app</p>\n' > /var/www/app/index.html

rm -f /etc/nginx/sites-enabled/default
cp /gladios/test/e2e/site.conf /etc/nginx/sites-enabled/gladios-test.conf

nginx -t 2> /dev/null
fail2ban-client -q start
echo "ready (nginx $(nginx -v 2>&1 | sed 's|.*/||'), njs $(njs -v))"
exec nginx -g 'daemon off;'
