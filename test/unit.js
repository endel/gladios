// njs's own interpreter, the engine nginx runs (test/e2e/run.sh unit does this in Docker):
//
//   njs -p njs test/unit.js

import crypto from 'crypto';
import gladios from 'gladios.js';

let failures = 0;
function check(name, ok) {
    console.log((ok ? 'ok    ' : 'FAIL  ') + name);
    failures += ok ? 0 : 1;
}

function zeroBits(challenge, nonce) {
    return gladios.leadingZeroBits(crypto.createHash('sha256').update(challenge + nonce).digest());
}

function solve(p) {
    for (let n = 0; ; n++) {
        const nonce = n.toString(36);
        if (zeroBits(p.challenge, nonce) >= p.difficulty) {
            return nonce;
        }
    }
}

function throws(f) {
    try {
        f();
        return false;
    } catch (e) {
        return true;
    }
}

const secret = 'k'.repeat(32);
const g = gladios.create(secret, 8, 3600);
const now = 1800000000;
const scope = gladios.scope;

check('scope: IPv4 as is', scope('203.0.113.7') === '203.0.113.7');
check('scope: IPv6 /64', scope('2001:db8:1:2:aaaa::1') === scope('2001:db8:1:2:bbbb::9'));
check('scope: other IPv6 /64', scope('2001:db8:1:2::1') !== scope('2001:db8:1:3::1'));
check('scope: IPv6 written out', scope('2001:db8:1:2::1') === '20010db800010002::/64');
check('scope: compressed at the front', scope('::1') === '0000000000000000::/64');
check('scope: IPv4-mapped IPv6 is the IPv4', scope('::ffff:203.0.113.7') === '203.0.113.7');
check('scope: IPv4-mapped, in hex', scope('::ffff:cb00:7107') === '203.0.113.7');

check('zero bits: 0x00 0x0f', gladios.leadingZeroBits([0x00, 0x0f]) === 12);
check('zero bits: 0x80', gladios.leadingZeroBits([0x80]) === 0);
check('zero bits: all zero', gladios.leadingZeroBits([0, 0]) === 16);

const p = gladios.puzzle(g, '203.0.113.7', now);
check('puzzle: carries difficulty and expiry', p.difficulty === 8 && p.expires === now + gladios.PUZZLE_TTL);
check('puzzle: stable for the same scope and time', gladios.puzzle(g, '203.0.113.7', now).challenge === p.challenge);
check('puzzle: differs per scope', gladios.puzzle(g, '203.0.113.8', now).challenge !== p.challenge);

const nonce = solve(p);
check('solved: right nonce', gladios.solved(g, '203.0.113.7', p.expires, nonce, now + 10));
check('solved: other scope', !gladios.solved(g, '203.0.113.8', p.expires, nonce, now + 10));
check('solved: expired', !gladios.solved(g, '203.0.113.7', p.expires, nonce, p.expires + 1));
check('solved: expiry moved', !gladios.solved(g, '203.0.113.7', p.expires - 1, nonce, now + 10));
check('solved: far-future expiry', !gladios.solved(g, '203.0.113.7', now + 99999, nonce, now));
check("solved: junk nonce", !gladios.solved(g, '203.0.113.7', p.expires, "a'; drop", now));
check('solved: nonce too long', !gladios.solved(g, '203.0.113.7', p.expires, 'a'.repeat(17), now));
let wrong = 0;
while (zeroBits(p.challenge, wrong.toString(36)) >= 8) {
    wrong++;
}
check('solved: wrong nonce', !gladios.solved(g, '203.0.113.7', p.expires, wrong.toString(36), now));
check('solved: easier puzzle than configured', !gladios.solved(gladios.create(secret, 20, 3600), '203.0.113.7', p.expires, nonce, now));

const pass = gladios.pass(g, '203.0.113.7', now);
const parts = pass.split('.');
check('pass: valid', gladios.valid(g, pass, '203.0.113.7', now + 60));
check('pass: other scope', !gladios.valid(g, pass, '198.51.100.1', now + 60));
check('pass: expired', !gladios.valid(g, pass, '203.0.113.7', now + 3601));
check('pass: other secret', !gladios.valid(gladios.create('x'.repeat(32), 8, 3600), pass, '203.0.113.7', now));
check('pass: expiry extended', !gladios.valid(g, (Number(parts[0]) + 86400) + '.' + parts[1], '203.0.113.7', now));
check('pass: tampered mac', !gladios.valid(g, parts[0] + '.' + parts[1].split('').reverse().join(''), '203.0.113.7', now));
check('pass: missing', !gladios.valid(g, undefined, '203.0.113.7', now));
check('pass: junk', !gladios.valid(g, '1.2.3', '203.0.113.7', now));
// the same HMAC over the same message, so passes from the PHP version (and other hosts) carry over
check('pass: the documented format', pass === (now + 3600) + '.' + crypto.createHmac('sha256', secret).update('pass|203.0.113.7|' + (now + 3600)).digest('base64url'));

check('cookie name: default', gladios.cookieName(undefined) === 'gladios' && gladios.cookieName('') === 'gladios');
check('cookie name: custom', gladios.cookieName('site_check-2') === 'site_check-2');
check('cookie name: not a $cookie_ name', gladios.cookieName('a.b') === null && gladios.cookieName('a b') === null);
check('cookie name: too long', gladios.cookieName('a'.repeat(65)) === null);

check('secret: under 32 characters rejected', throws(function () { gladios.create('short', 16, 60); }) && throws(function () { gladios.create(undefined, 16, 60); }));
check('difficulty: 1-32 bits', throws(function () { gladios.create(secret, 0, 60); }) && throws(function () { gladios.create(secret, 33, 60); }) && throws(function () { gladios.create(secret, NaN, 60); }));
check('pass TTL: whole seconds', throws(function () { gladios.create(secret, 16, 0); }) && throws(function () { gladios.create(secret, 16, 1.5); }));

console.log(failures ? '\n' + failures + ' failed' : '\nall passed');
if (failures) {
    throw new Error(failures + ' failed');
}
