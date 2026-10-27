# gladios

A self-hosted browser check for nginx. A visitor without a pass gets a static page that spends about
a second on a small SHA-256 proof of work, collects a signed cookie, and reloads what they asked
for. HTTP flood tools don't run JavaScript, so they never get past the static page, and that page
costs no more than serving a file.

Same idea as [Anubis](https://github.com/TecharoHQ/anubis), different split: there's no service
of its own. nginx serves the challenge page, and nginx's JavaScript module (njs) checks passes and
issues puzzles, so gladios is a few config files and one script.

```
request ── nginx ── bypassed? (signed in, API client, webhook…) ──────────────► app
              │
              ├─ no pass cookie ────────────────────► challenge page (static, 200)
              │                                         │  GET  /.gladios/api/challenge
              │                                         │  (browser solves the puzzle)
              │                                         │  POST /.gladios/api/verify → Set-Cookie
              │                                         ▼  reloads the same URL
              └─ pass cookie ── auth_request → njs check ── valid ───────────► app
                                                  └─ invalid ──► challenge page
```

## How it works

- **Stateless.** A puzzle is an HMAC over the client's network, the difficulty and an expiry; a pass
  is `expires.HMAC(network, expires)`. Nothing is stored, so every nginx worker (and every host
  sharing the secret) agrees.
- **Bound to the network.** The client's IPv4 address, or its IPv6 /64. A pass is worthless from
  another network, so one solve can't be shared across a botnet.
- **Cheap to verify.** One HMAC, inside the nginx worker that has the request: no process to call
  and no pool to fill (see [Performance](#performance)).
- **Difficulty 16** (default): ~65k hashes, 0.4–0.9 s in current Chromium and Firefox, spread over
  the device's cores with Web Workers.

It stops tools that don't run JavaScript. A real headless browser pays the proof of work and gets
through, as it would with any challenge of this kind; the per-network binding and rate limits are
what make that expensive at scale. Visitors with JavaScript off can't pass.

## Requirements

- nginx with `ngx_http_auth_request_module` (built in on Debian, Ubuntu and nginx.org packages) and
  the njs module, 0.7.9 or newer:

  | nginx from | njs package | loaded by |
  |---|---|---|
  | Debian 12, 13; Ubuntu 24.04 | `libnginx-mod-http-js` | the package (`modules-enabled`) |
  | nginx.org's repository | `nginx-module-njs` | `load_module modules/ngx_http_js_module.so;` atop `nginx.conf` |
  | Alpine | `nginx-mod-http-js` | the same `load_module` line |
  | the official `nginx` Docker image | already there | the same `load_module` line |

  Ubuntu 22.04's own nginx has none: use nginx.org's packages there.
- HTTPS: the pass cookie is `Secure`
- Optional: fail2ban to ban forgers; cron and Python 3.8+ (which fail2ban runs on) for ban
  notifications

The app you protect can be anything.

## Layout

```
njs/gladios.js         puzzles and passes, and the check, challenge and verify handlers
public/                the default challenge page, solver, worker and illustration
nginx/conf.d/          http level: $gladios_gate, strikes, the `gladios` limit_req zone
nginx/snippets/        gladios-server.conf (locations), gladios-protect.conf (per location)
fail2ban/              filter.d/gladios.conf (strikes), action.d/gladios-notify.conf (records bans)
bin/gladios-notify     posts a digest of recent bans to a webhook (Python 3)
cron.d/                runs it every minute, once /etc/gladios/notify.conf exists
install.sh             copies all of the above under a root (/ or a config tree)
test/                  unit tests (njs), a browser test, a Docker end-to-end setup, a benchmark
```

## Installing

```sh
sudo ./install.sh /     # or vendor into a config tree: ./install.sh path/to/tree
```

`install.sh` never touches `/etc/gladios`. Then, on the host:

1. **njs**, from the table above.
2. **The secret**, as nginx config: nginx reads it as root, so it can stay root-only. A new one
   voids every pass, so everyone solves once more.
   ```sh
   install -d -m 0755 /etc/gladios
   (umask 077 && printf 'js_var $gladios_secret "%s";\n' "$(head -c 48 /dev/urandom | base64 -w0)" > /etc/gladios/secret.conf)
   ```
3. **nginx.** At http level:
   ```nginx
   map $host $gladios_enabled     { default 1; }               # the switch
   map $host $gladios_cookie_name { default gladios; }         # the pass cookie (see below)
   map $host $gladios_cookie      { default $cookie_gladios; } # its value: same name
   map ... $gladios_bypass        { ... }                      # 1: never check (see below)
   ```
   Then `include snippets/gladios-server.conf;` in the server and
   `include snippets/gladios-protect.conf;` in each location to protect.
   [`test/e2e/site.conf`](test/e2e/site.conf) is a complete example.
4. `nginx -t && systemctl reload nginx`

### The cookie

Pick your own name: set it on both `$gladios_cookie_name` and `$gladios_cookie`. A name that isn't `gladios` keeps off-the-shelf tools guessing, but it's no
secret: anyone who passes the check once sees it. What protects you is the value, an HMAC under
your secret that's bound to the visitor's network and an expiry. A forged one never gets through;
the worst it does is cost an HMAC (anything not even shaped like a pass doesn't get that far), and
it earns a strike.

### What to bypass

Anything that can't run a browser: API clients, webhooks, uptime and health checks, your own
servers. Signed-in users too, if your app has its own sessions; matching their session cookie's
name is cheap, but anyone can send a cookie by that name, so it keeps out only floods that don't
know it.

### Behind a proxy or load balancer

The puzzle and pass are bound to `$remote_addr`. Behind a proxy, restore the client's address with
`ngx_http_realip_module`, or every visitor shares the proxy's address, and its passes.

### Banning forgers

A strike is a request that came with a pass cookie and still got the challenge: forged, expired,
or solved on another network. nginx logs each one to `/var/log/nginx/gladios-strikes.log`. A real
browser makes one, then solves; a flood of forged cookies makes one per request. Ban the second
kind with fail2ban:

```ini
# /etc/fail2ban/jail.d/gladios.local (touch the log first: fail2ban won't watch a missing file)
[gladios]
enabled  = true
filter   = gladios
logpath  = /var/log/nginx/gladios-strikes.log
findtime = 60
maxretry = 20
bantime  = 6h
action   = %(action_)s
           gladios-notify[name=%(__name__)s]
```

### Ban notifications

To catch false positives, `bin/gladios-notify` (Python 3) posts a digest of the last minute's bans to a
webhook. Add `gladios-notify[name=%(__name__)s]` to any jail's actions, as above; it only appends to
`/var/log/gladios/bans.log`, so it doesn't slow fail2ban down during a flood. Then, in
`/etc/gladios/notify.conf` (root only, the URL is a secret):

```ini
webhook   = "https://hooks.slack.com/services/..."
format    = slack                                 ; slack, discord or json
samples[] = /var/log/nginx/gladios-strikes.log    ; logs to quote what a banned address sent
```

`cron.d/gladios-notify` picks it up within a minute. Each digest lists up to 10 addresses with
their jail, hit count and latest lines from the sample logs, counts the rest, and ends with the
command to unban. Text from requests (URLs, user agents) is escaped, so it can't mention anyone or
post links. A failed post is retried on the next run.

### Configuration

Optional nginx variables, at http level like the others (`map $host $gladios_difficulty { default 18; }`):

| Variable | Default | |
|---|---|---|
| `$gladios_difficulty` | `16` | leading zero bits; each +1 doubles the work |
| `$gladios_pass_ttl` | `604800` | seconds a pass lasts |
| `$gladios_cookie_domain` | this host | share one pass across sibling hosts, e.g. `example.com` |

A setting out of range fails closed: visitors still get the check, the API answers 500, and
nginx's error log says why.

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
- An internal redirect back into a protected location runs the check again: `try_files $uri
  /index.html` checks twice whenever it falls back. Cheap, but a named location (`try_files $uri
  @app`) without the include checks once.
- A new `njs/gladios.js` takes effect on an nginx reload. Without `/etc/gladios/secret.conf`,
  `nginx -t` fails, so a reload never goes out half set up.
- `/.gladios/api/*` is limited to 60 requests a minute per address (burst 30): a check is 2, and
  one address can be a whole office or carrier NAT. Tune `rate` in `conf.d/gladios.conf` and
  `burst` in `snippets/gladios-server.conf`. Its 429s are `limit_req` errors in error.log, so a
  fail2ban jail on `nginx-limit-req` can include zone `gladios`.
- Challenge pages are logged to `/var/log/nginx/gladios.log`, not the server's access log.
- The challenge page is answered with 200, so an uptime check that isn't bypassed sees 200 even
  when the app is down.

## Testing

```sh
npm install                 # Playwright, for the browser test
test/e2e/run.sh             # Docker: Debian 12's nginx and njs 0.7.9, then the checks and browsers
test/bench/run.sh           # Docker: load test, see Performance
```

`test/e2e/run.sh` runs the unit tests (`test/unit.js`) in njs's own interpreter, then builds a
container from `test/e2e/site.conf`. It asserts who gets checked, solves a check with curl, mints a
pass by hand from the scheme above, swaps in a custom mascot and page, flips the switch, trips the
rate limit, then gets an address banned for forged passes and checks the notifications (Slack,
Discord, JSON, a webhook that's down). Then `test/browser.mjs` takes Chromium and Firefox through
the check in light and dark, plus the failure state and retry.

## Performance

`test/bench/run.sh` pins the server to 2 cores and runs [oha](https://github.com/hatoo/oha) on
others, over TLS with keep-alive and 64 connections. On an Apple M1 Pro's Linux VM, with Debian
12's nginx 1.22 and njs 0.7.9 (two runs each):

| Request | Most served | p50 | CPU at 1,000 req/s |
|---|---|---|---|
| with a valid pass: checked, then the app's page | 35–36k/s | 1.7 ms | 0.14 cores |
| with a forged pass: checked, challenge page, strike | 24–26k/s | 2.4 ms | 0.19 cores |
| without a cookie: challenge page, nothing to check | 35–36k/s | 1.7 ms | 0.15–0.18 cores |
| `GET /.gladios/api/challenge`, unthrottled | 59–61k/s | 1.0 ms | 0.11–0.17 cores |
| `POST /.gladios/api/verify`, unthrottled | 47–50k/s | 1.2 ms | 0.12–0.13 cores |

nginx's three processes took 11–12 MB between them. Absolute numbers depend on the machine:
run it on yours.

## License

MIT, see [LICENSE](LICENSE). The gladiator (`public/gladios.webp`) is under the same license.
