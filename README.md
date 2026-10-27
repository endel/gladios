# gladios

A self-hosted browser check for nginx. A visitor without a pass gets a static page that spends about
a second on a small SHA-256 proof of work, collects a signed cookie, and reloads what they asked
for. HTTP flood tools don't run JavaScript, so they never get past the static page, and that page
costs no more than serving a file.

Same idea as [Anubis](https://github.com/TecharoHQ/anubis), different split: nginx serves the
challenge page itself, so only a request that *presents* a cookie ever reaches the backend.

```
request ── nginx ── bypassed? (signed in, API client, webhook…) ──────────────► app
              │
              ├─ no pass cookie ────────────────────► challenge page (static, 200)
              │                                         │  GET  /.gladios/api/challenge
              │                                         │  (browser solves the puzzle)
              │                                         │  POST /.gladios/api/verify → Set-Cookie
              │                                         ▼  reloads the same URL
              └─ pass cookie ── auth_request → fcgi.php check ── valid ──────► app
                                                      └─ invalid ──► challenge page
```

## How it works

- **Stateless.** A puzzle is an HMAC over the client's network, the difficulty and an expiry; a pass
  is `expires.HMAC(network, expires)`. Nothing is stored, so any number of php-fpm workers (or hosts
  sharing the secret) agree.
- **Bound to the network.** The client's IPv4 address, or its IPv6 /64. A pass is worthless from
  another network, so one solve can't be shared across a botnet.
- **Cheap to verify.** `src/fcgi.php` loads no framework: well under a millisecond per check.
- **Difficulty 16** (default): ~65k hashes, 0.4–0.9 s in current Chromium and Firefox, spread over
  the device's cores with Web Workers.

It stops tools that don't run JavaScript. A real headless browser pays the proof of work and gets
through, as it would with any challenge of this kind; the per-network binding and rate limits are
what make that expensive at scale. Visitors with JavaScript off can't pass.

## Requirements

- nginx with `ngx_http_auth_request_module` (built in on Debian, Ubuntu and nginx.org packages)
- php-fpm 8.1 or newer, for the backend only: the app you protect can be anything
- HTTPS: the pass cookie is `Secure`

## Layout

```
src/Gladios.php        puzzles and passes (pure, unit-tested)
src/fcgi.php           the php-fpm entry: check, challenge, verify
public/                the default challenge page, solver, worker and illustration
nginx/conf.d/          http level: $gladios_gate, the `gladios` limit_req zone
nginx/snippets/        gladios-server.conf (locations), gladios-protect.conf (per location)
install.sh             copies all of the above under a root (/ or a config tree)
test/                  unit tests, a browser test, and a Docker end-to-end setup
```

## Installing

```sh
sudo ./install.sh /     # or vendor into a config tree: ./install.sh path/to/tree
```

`install.sh` never touches `/etc/gladios`. Then, on the host:

1. **The secret.** Readable by the pool only; a new one voids every pass, so everyone solves once
   more.
   ```sh
   adduser --system --group --no-create-home --home /nonexistent gladios
   install -d -m 0755 /etc/gladios
   head -c 48 /dev/urandom | base64 > /etc/gladios/secret
   chown root:gladios /etc/gladios/secret && chmod 0640 /etc/gladios/secret
   ```
2. **A php-fpm pool** for `/opt/gladios/src/fcgi.php`, under its own user. `pm = static`: under a
   flood of forged cookies every request lands here, so it shouldn't be forking.
   ```ini
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
   ```
3. **nginx.** At http level, define `upstream gladios_php` (that socket), `$gladios_enabled` (the
   switch) and `$gladios_bypass` (1 for requests never to check). Then
   `include snippets/gladios-server.conf;` in the server and `include snippets/gladios-protect.conf;`
   in each location to protect. [`test/e2e/site.conf`](test/e2e/site.conf) is a complete example.
4. Reload php-fpm, then nginx.

### What to bypass

Anything that can't run a browser: API clients, webhooks, uptime and health checks, your own
servers. Signed-in users too, if your app has its own sessions; matching their session cookie's
name is cheap, but anyone can send a cookie by that name, so it keeps out only floods that don't
know it.

### Behind a proxy or load balancer

The puzzle and pass are bound to `$remote_addr`. Behind a proxy, restore the client's address with
`ngx_http_realip_module`, or every visitor shares the proxy's address, and its passes.

### Configuration (pool `env[...]` or `fastcgi_param`)

| Variable | Default | |
|---|---|---|
| `GLADIOS_SECRET_FILE` | `/etc/gladios/secret` | 32+ bytes, readable by the pool only |
| `GLADIOS_DIFFICULTY` | `16` | leading zero bits; each +1 doubles the work |
| `GLADIOS_PASS_TTL` | `604800` | seconds a pass lasts |
| `GLADIOS_COOKIE_DOMAIN` | this host | share one pass across sibling hosts, e.g. `example.com` |

## Making it yours

Everything lives in `/etc/gladios/site/`, which `install.sh` and upgrades never touch.

**Your own mascot.** Drop `mascot.webp`, `.png`, `.svg`, `.jpg` or `.gif` there (first match wins):
the default page shows it in place of the gladiator, at up to 220 × 260 px.

**Your own page.** Put it at `/etc/gladios/site/index.html`, with any images or styles beside it:
they're served under `/.gladios/site/`, and the mascot stays at `/.gladios/mascot`. It replaces
the default (`public/index.html`) and needs three things from it:

```html
<span id="status"></span>                       <!-- progress and errors are written here -->
<button type="button" class="retry">Try again</button>
<script src="/.gladios/gladios.js" defer></script>
```

While the check fails, `<body>` has the class `failed`: show the button then.

## Gotchas

- `gladios-protect.conf` sets an `error_page`, which drops every `error_page` the location
  inherited from its server. Repeat any it relies on.
- With `opcache.validate_timestamps=0`, a new `src/` needs a php-fpm reload.
- `/.gladios/api/*` is limited to 60 requests a minute per address (burst 30): a check is 2, and
  one address can be a whole office or carrier NAT. Tune `rate` in `conf.d/gladios.conf` and
  `burst` in `snippets/gladios-server.conf`. Its 429s are `limit_req` errors in error.log, so a
  fail2ban jail on `nginx-limit-req` can include zone `gladios`.
- Challenge pages are logged to `/var/log/nginx/gladios.log`, not the server's access log.
- The challenge page is answered with 200, so an uptime check that isn't bypassed sees 200 even
  when the app is down.

## Testing

```sh
php test/unit.php           # puzzles, passes, scopes, tampering
npm install                 # Playwright, for the browser test
test/e2e/run.sh             # Docker: Debian 12's nginx and php-fpm, then the checks and browsers
```

`test/e2e/run.sh` builds a container from `test/e2e/site.conf`, asserts who gets checked, solves a
check with curl, swaps in a custom page, flips the switch and trips the rate limit. Then
`test/browser.mjs` takes Chromium and Firefox through the check in light and dark, plus the
failure state and retry.

## License

MIT, see [LICENSE](LICENSE). The gladiator (`public/gladios.webp`) is under the same license.
