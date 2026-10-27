/**
 * gladios's server half, run inside nginx by its njs module: checks pass cookies, hands out
 * puzzles and turns solved ones into passes. Puzzles and passes are HMACs over the client's
 * network and an expiry, so nothing is stored: every nginx worker, or any host holding the same
 * secret, can verify what another issued.
 *
 * - A puzzle is `HMAC("puzzle|difficulty|scope|expires")`. The browser finds a nonce such that
 *   `SHA-256(puzzle + nonce)` starts with `difficulty` zero bits (2^difficulty hashes on average).
 * - A pass is `expires.HMAC("pass|scope|expires")`, set as a cookie once the work checks out.
 *
 * The scope is the client's IPv4 address, or its IPv6 /64 (privacy addresses rotate inside it):
 * a pass solved on one network is worthless from another.
 *
 * nginx variables read here:
 *
 *   $gladios_secret         32+ characters, from /etc/gladios/secret.conf
 *   $gladios_cookie_name    the pass cookie's name (default gladios)
 *   $gladios_cookie         the cookie's value under that name
 *   $gladios_difficulty     optional: leading zero bits of proof of work (default 16)
 *   $gladios_pass_ttl       optional: seconds a pass lasts (default 604800, a week)
 *   $gladios_cookie_domain  optional: share the pass across sibling hosts, e.g. example.com
 *
 * Written for njs 0.7.9 (Debian 12), the oldest engine it's tested on: no destructuring, spread
 * or optional chaining.
 */

import crypto from 'crypto';
import qs from 'querystring';

/** The pass cookie's name unless nginx says otherwise. */
const COOKIE = 'gladios';

/** How long a browser has to solve a puzzle. */
const PUZZLE_TTL = 300;

/** Settings for the functions below; throws on values that would make the check meaningless. */
function create(secret, difficulty, passTtl) {
    if (typeof secret !== 'string' || secret.length < 32) {
        throw new Error('the secret must be at least 32 characters');
    }
    if (!Number.isInteger(difficulty) || difficulty < 1 || difficulty > 32) {
        throw new Error('difficulty must be 1-32 bits');
    }
    if (!Number.isInteger(passTtl) || passTtl < 1) {
        throw new Error('the pass TTL must be a whole number of seconds');
    }
    return { secret: secret, difficulty: difficulty, passTtl: passTtl };
}

/** The cookie name nginx was given, or null when nginx couldn't read it back as $cookie_<name>. */
function cookieName(name) {
    if (name === undefined || name === null || name === '') {
        return COOKIE;
    }
    return /^[A-Za-z0-9_-]{1,64}$/.test(name) ? name : null;
}

/** The network a puzzle or pass is bound to. */
function scope(ip) {
    if (ip.indexOf(':') < 0) {
        return ip;
    }
    const g = ipv6(ip);
    if (!g) {
        return ip;
    }
    // IPv4-mapped IPv6 (::ffff:a.b.c.d) is the IPv4 client
    if (g[0] === 0 && g[1] === 0 && g[2] === 0 && g[3] === 0 && g[4] === 0 && g[5] === 0xffff) {
        return [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join('.');
    }
    return g.slice(0, 4).map(function (n) { return ('000' + n.toString(16)).slice(-4); }).join('') + '::/64';
}

/** An IPv6 address as its 8 groups, or null. */
function ipv6(ip) {
    // a dotted IPv4 tail (::ffff:192.0.2.1) is the last two groups
    const tail = /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
    if (tail) {
        const hi = (Number(tail[1]) << 8) | Number(tail[2]);
        const lo = (Number(tail[3]) << 8) | Number(tail[4]);
        ip = ip.slice(0, tail.index) + hi.toString(16) + ':' + lo.toString(16);
    }
    const halves = ip.split('::');
    if (halves.length > 2) {
        return null;
    }
    const head = halves[0] ? halves[0].split(':') : [];
    const rest = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
    const missing = 8 - head.length - rest.length;
    if (halves.length === 2 ? missing < 1 : missing !== 0) {
        return null;
    }
    const groups = head.concat(new Array(missing).fill('0'), rest);
    for (let i = 0; i < groups.length; i++) {
        if (!/^[0-9A-Fa-f]{1,4}$/.test(groups[i])) {
            return null;
        }
        groups[i] = parseInt(groups[i], 16);
    }
    return groups;
}

function puzzle(g, scope, now) {
    const expires = now + PUZZLE_TTL;
    return { challenge: puzzleFor(g, scope, expires), difficulty: g.difficulty, expires: expires };
}

function solved(g, scope, expires, nonce, now) {
    // expires is covered by the HMAC, so a client can't extend it; the upper bound only rejects
    // puzzles issued under a longer PUZZLE_TTL than this one
    if (expires < now || expires > now + PUZZLE_TTL) {
        return false;
    }
    if (!/^[0-9a-z]{1,16}$/.test(nonce)) {
        return false;
    }
    const hash = crypto.createHash('sha256').update(puzzleFor(g, scope, expires) + nonce).digest();
    return leadingZeroBits(hash) >= g.difficulty;
}

/** The cookie value for a solved puzzle. */
function pass(g, scope, now) {
    const expires = now + g.passTtl;
    return expires + '.' + mac(g, 'pass|' + scope + '|' + expires);
}

function valid(g, value, scope, now) {
    const m = /^(\d{1,12})\.([A-Za-z0-9_-]{43})$/.exec(value || '');
    if (!m) {
        return false;
    }
    const expires = Number(m[1]);
    return expires >= now && same(mac(g, 'pass|' + scope + '|' + expires), m[2]);
}

function leadingZeroBits(bytes) {
    let bits = 0;
    for (let i = 0; i < bytes.length; i++) {
        let b = bytes[i];
        if (b === 0) {
            bits += 8;
            continue;
        }
        while ((b & 0x80) === 0) {
            bits++;
            b <<= 1;
        }
        break;
    }
    return bits;
}

function puzzleFor(g, scope, expires) {
    return mac(g, 'puzzle|' + g.difficulty + '|' + scope + '|' + expires);
}

function mac(g, message) {
    return crypto.createHmac('sha256', g.secret).update(message).digest('base64url');
}

// constant time: a forger can't learn a MAC byte by byte from response times
function same(a, b) {
    if (a.length !== b.length) {
        return false;
    }
    let diff = 0;
    for (let i = 0; i < a.length; i++) {
        diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    return diff === 0;
}

// ---- nginx handlers ----

function now() {
    return Math.floor(Date.now() / 1000);
}

function optionalInt(value, fallback) {
    return value === undefined || value === '' ? fallback : Number(value);
}

/** This request's settings from nginx's variables, or null (and an error.log line). */
function settings(r) {
    const v = r.variables;
    const cookie = cookieName(v.gladios_cookie_name);
    const domain = v.gladios_cookie_domain || '';
    try {
        if (cookie === null) {
            throw new Error('$gladios_cookie_name must be 1-64 of A-Z a-z 0-9 _ -');
        }
        if (!/^[A-Za-z0-9.-]*$/.test(domain)) {
            throw new Error('$gladios_cookie_domain must be a host name');
        }
        const g = create(v.gladios_secret, optionalInt(v.gladios_difficulty, 16), optionalInt(v.gladios_pass_ttl, 604800));
        g.cookie = cookie;
        g.domain = domain;
        return g;
    } catch (e) {
        r.error('gladios: ' + e.message);
        return null;
    }
}

function respond(r, status, json) {
    r.headersOut['Cache-Control'] = 'no-store';
    if (json === undefined) {
        r.return(status);
        return;
    }
    r.headersOut['Content-Type'] = 'application/json';
    r.return(status, JSON.stringify(json));
}

/** js_set $gladios_pass_valid: "1" when the request's pass cookie checks out. */
function passValid(r) {
    const g = settings(r);
    return g && valid(g, r.variables.gladios_cookie, scope(r.remoteAddress), now()) ? '1' : '0';
}

/** js_content, GET: {challenge, difficulty, expires} */
function challenge(r) {
    if (r.method !== 'GET') {
        return respond(r, 405);
    }
    const g = settings(r);
    if (!g) {
        return respond(r, 500);
    }
    respond(r, 200, puzzle(g, scope(r.remoteAddress), now()));
}

/** js_content, POST expires and nonce (urlencoded): 204 and the pass cookie, or 403. */
function verify(r) {
    if (r.method !== 'POST') {
        return respond(r, 405);
    }
    const g = settings(r);
    if (!g) {
        return respond(r, 500);
    }
    const body = qs.parse(r.requestText || '');
    const expires = body.expires;
    const nonce = body.nonce;
    if (typeof expires !== 'string' || !/^\d{1,12}$/.test(expires) || typeof nonce !== 'string') {
        return respond(r, 400);
    }
    const s = scope(r.remoteAddress);
    const t = now();
    if (!solved(g, s, Number(expires), nonce, t)) {
        return respond(r, 403);
    }
    const cookie = [
        g.cookie + '=' + pass(g, s, t),
        'Expires=' + new Date((t + g.passTtl) * 1000).toUTCString(),
        'Max-Age=' + g.passTtl,
        'Path=/',
    ];
    if (g.domain) {
        cookie.push('Domain=' + g.domain);
    }
    cookie.push('Secure', 'HttpOnly', 'SameSite=Lax');
    r.headersOut['Set-Cookie'] = cookie.join('; ');
    respond(r, 204);
}

export default {
    passValid: passValid,
    challenge: challenge,
    verify: verify,
    // for test/unit.js
    COOKIE: COOKIE,
    PUZZLE_TTL: PUZZLE_TTL,
    create: create,
    cookieName: cookieName,
    scope: scope,
    puzzle: puzzle,
    solved: solved,
    pass: pass,
    valid: valid,
    leadingZeroBits: leadingZeroBits,
};
