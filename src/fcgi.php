<?php

/**
 * The FastCGI entry point. nginx picks the action with `fastcgi_param GLADIOS_ACTION`:
 *
 *   check      auth_request target: 204 with a valid pass cookie, else 401 (nginx then serves the
 *              challenge page itself). nginx only asks about cookies shaped like a pass.
 *   challenge  GET:  {challenge, difficulty, expires}
 *   verify     POST: expires, nonce (urlencoded). 204 + the pass cookie, or 403
 *
 * nginx also passes GLADIOS_COOKIE, the pass cookie's name ($gladios_cookie_name).
 *
 * Configuration, from the pool's `env[...]` or a fastcgi_param:
 *
 *   GLADIOS_SECRET_FILE    32+ random bytes, readable by the pool only (default /etc/gladios/secret)
 *   GLADIOS_DIFFICULTY     leading zero bits of proof of work (default 16: ~65k hashes, well under
 *                          a second in a current browser)
 *   GLADIOS_PASS_TTL       seconds a pass lasts (default 604800, a week)
 *   GLADIOS_COOKIE_DOMAIN  share the pass across sibling hosts, e.g. example.com (default: this host)
 */

declare(strict_types=1);

require __DIR__ . '/Gladios.php';

use Gladios\Gladios;

function gladios_env(string $name, string $default): string
{
    $value = $_SERVER[$name] ?? getenv($name);

    return is_string($value) && $value !== '' ? $value : $default;
}

function gladios_respond(int $status, ?array $json = null): never
{
    http_response_code($status);
    header('Cache-Control: no-store');
    if ($json !== null) {
        header('Content-Type: application/json');
        echo json_encode($json);
    }
    exit;
}

$secretFile = gladios_env('GLADIOS_SECRET_FILE', '/etc/gladios/secret');
$secret = @file_get_contents($secretFile);
try {
    $gladios = new Gladios(
        trim((string) $secret),
        (int) gladios_env('GLADIOS_DIFFICULTY', '16'),
        (int) gladios_env('GLADIOS_PASS_TTL', '604800'),
    );
} catch (InvalidArgumentException $e) {
    error_log("gladios: $secretFile: {$e->getMessage()}");
    gladios_respond(500);
}

$cookie = Gladios::cookieName($_SERVER['GLADIOS_COOKIE'] ?? null);
if ($cookie === null) {
    error_log('gladios: GLADIOS_COOKIE must be 1-64 of A-Z a-z 0-9 _ -');
    gladios_respond(500);
}

$scope = Gladios::scope($_SERVER['REMOTE_ADDR'] ?? '');
$now = time();
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

switch ($_SERVER['GLADIOS_ACTION'] ?? '') {
    case 'check':
        gladios_respond($gladios->valid($_COOKIE[$cookie] ?? null, $scope, $now) ? 204 : 401);

    case 'challenge':
        if ($method !== 'GET') {
            gladios_respond(405);
        }
        gladios_respond(200, $gladios->puzzle($scope, $now));

    case 'verify':
        if ($method !== 'POST') {
            gladios_respond(405);
        }
        $expires = $_POST['expires'] ?? '';
        $nonce = $_POST['nonce'] ?? '';
        if (!is_string($expires) || !ctype_digit($expires) || !is_string($nonce)) {
            gladios_respond(400);
        }
        if (!$gladios->solved($scope, (int) $expires, $nonce, $now)) {
            gladios_respond(403);
        }
        $pass = $gladios->pass($scope, $now);
        setcookie($cookie, $pass, [
            'expires' => $now + $gladios->passTtl,
            'path' => '/',
            'domain' => gladios_env('GLADIOS_COOKIE_DOMAIN', ''),
            'secure' => true,
            'httponly' => true,
            'samesite' => 'Lax',
        ]);
        gladios_respond(204);

    default:
        error_log('gladios: no GLADIOS_ACTION from nginx');
        gladios_respond(500);
}
