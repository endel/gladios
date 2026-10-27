<?php

// php test/unit.php

declare(strict_types=1);

require __DIR__ . '/../src/Gladios.php';

use Gladios\Gladios;

$failures = 0;
function check(string $name, bool $ok): void
{
    global $failures;
    echo ($ok ? 'ok   ' : 'FAIL ') . $name . "\n";
    $failures += $ok ? 0 : 1;
}

function solve(array $puzzle): string
{
    for ($n = 0; ; $n++) {
        $nonce = base_convert((string) $n, 10, 36);
        if (Gladios::leadingZeroBits(hash('sha256', $puzzle['challenge'] . $nonce, true)) >= $puzzle['difficulty']) {
            return $nonce;
        }
    }
}

$secret = str_repeat('k', 32);
$g = new Gladios($secret, difficulty: 8, passTtl: 3600);
$now = 1_800_000_000;

check('scope: IPv4 as is', Gladios::scope('203.0.113.7') === '203.0.113.7');
check('scope: IPv6 /64', Gladios::scope('2001:db8:1:2:aaaa::1') === Gladios::scope('2001:db8:1:2:bbbb::9'));
check('scope: other IPv6 /64', Gladios::scope('2001:db8:1:2::1') !== Gladios::scope('2001:db8:1:3::1'));
check('scope: IPv4-mapped IPv6 is the IPv4', Gladios::scope('::ffff:203.0.113.7') === '203.0.113.7');

check('zero bits: 0x00 0x0f', Gladios::leadingZeroBits("\x00\x0f") === 12);
check('zero bits: 0x80', Gladios::leadingZeroBits("\x80") === 0);
check('zero bits: all zero', Gladios::leadingZeroBits("\x00\x00") === 16);

$p = $g->puzzle('203.0.113.7', $now);
check('puzzle: carries difficulty and expiry', $p['difficulty'] === 8 && $p['expires'] === $now + Gladios::PUZZLE_TTL);
check('puzzle: stable for the same scope and time', $g->puzzle('203.0.113.7', $now) === $p);
check('puzzle: differs per scope', $g->puzzle('203.0.113.8', $now)['challenge'] !== $p['challenge']);

$nonce = solve($p);
check('solved: right nonce', $g->solved('203.0.113.7', $p['expires'], $nonce, $now + 10));
check('solved: other scope', !$g->solved('203.0.113.8', $p['expires'], $nonce, $now + 10));
check('solved: expired', !$g->solved('203.0.113.7', $p['expires'], $nonce, $p['expires'] + 1));
check('solved: expiry moved', !$g->solved('203.0.113.7', $p['expires'] - 1, $nonce, $now + 10));
check('solved: far-future expiry', !$g->solved('203.0.113.7', $now + 99999, $nonce, $now));
check('solved: junk nonce', !$g->solved('203.0.113.7', $p['expires'], "a'; drop", $now));
check('solved: nonce too long', !$g->solved('203.0.113.7', $p['expires'], str_repeat('a', 17), $now));
$wrong = '';
for ($n = 0; ; $n++) {
    $wrong = base_convert((string) $n, 10, 36);
    if (Gladios::leadingZeroBits(hash('sha256', $p['challenge'] . $wrong, true)) < 8) {
        break;
    }
}
check('solved: wrong nonce', !$g->solved('203.0.113.7', $p['expires'], $wrong, $now));
$harder = new Gladios($secret, difficulty: 20);
check('solved: easier puzzle than configured', !$harder->solved('203.0.113.7', $p['expires'], $nonce, $now));

$pass = $g->pass('203.0.113.7', $now);
check('pass: valid', $g->valid($pass, '203.0.113.7', $now + 60));
check('pass: other scope', !$g->valid($pass, '198.51.100.1', $now + 60));
check('pass: expired', !$g->valid($pass, '203.0.113.7', $now + 3601));
check('pass: other secret', !(new Gladios(str_repeat('x', 32), 8, 3600))->valid($pass, '203.0.113.7', $now));
[$exp, $mac] = explode('.', $pass);
check('pass: expiry extended', !$g->valid(($exp + 86400) . '.' . $mac, '203.0.113.7', $now));
check('pass: tampered mac', !$g->valid($exp . '.' . strrev($mac), '203.0.113.7', $now));
check('pass: missing', !$g->valid(null, '203.0.113.7', $now));
check('pass: junk', !$g->valid('1.2.3', '203.0.113.7', $now));

check('cookie name: default', Gladios::cookieName(null) === 'gladios' && Gladios::cookieName('') === 'gladios');
check('cookie name: custom', Gladios::cookieName('site_check-2') === 'site_check-2');
check('cookie name: PHP would mangle it', Gladios::cookieName('a.b') === null && Gladios::cookieName('a b') === null);
check('cookie name: too long', Gladios::cookieName(str_repeat('a', 65)) === null);

$rejects = 0;
foreach (['short', ''] as $s) {
    try {
        new Gladios($s);
    } catch (InvalidArgumentException) {
        $rejects++;
    }
}
check('secret: under 32 bytes rejected', $rejects === 2);

echo $failures ? "\n$failures failed\n" : "\nall passed\n";
exit($failures ? 1 : 0);
