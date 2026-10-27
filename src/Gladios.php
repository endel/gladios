<?php

declare(strict_types=1);

namespace Gladios;

/**
 * Puzzles and passes for the browser check. Both are HMACs over the client's network and an
 * expiry, so nothing is stored: any worker, or any host holding the same secret, can verify what
 * another issued.
 *
 * - A puzzle is `HMAC("puzzle|difficulty|scope|expires")`. The browser finds a nonce such that
 *   `SHA-256(puzzle . nonce)` starts with `difficulty` zero bits (2^difficulty hashes on average).
 * - A pass is `expires.HMAC("pass|scope|expires")`, set as a cookie once the work checks out.
 *
 * The scope is the client's IPv4 address, or its IPv6 /64 (privacy addresses rotate inside it):
 * a pass solved on one network is worthless from another.
 */
final class Gladios
{
    public const COOKIE = 'gladios';

    /** How long a browser has to solve a puzzle. */
    public const PUZZLE_TTL = 300;

    public function __construct(
        private readonly string $secret,
        public readonly int $difficulty = 16,
        public readonly int $passTtl = 604800,
    ) {
        if (strlen($secret) < 32) {
            throw new \InvalidArgumentException('the secret must be at least 32 bytes');
        }
        if ($difficulty < 1 || $difficulty > 32) {
            throw new \InvalidArgumentException('difficulty must be 1-32 bits');
        }
    }

    /** The network a puzzle or pass is bound to. */
    public static function scope(string $ip): string
    {
        $bin = @inet_pton($ip);
        if ($bin === false) {
            return $ip;
        }
        // IPv4-mapped IPv6 (::ffff:a.b.c.d) is the IPv4 client
        if (strlen($bin) === 16 && str_starts_with($bin, str_repeat("\0", 10) . "\xff\xff")) {
            return inet_ntop(substr($bin, 12));
        }

        return strlen($bin) === 4 ? $ip : bin2hex(substr($bin, 0, 8)) . '::/64';
    }

    /** @return array{challenge: string, difficulty: int, expires: int} */
    public function puzzle(string $scope, int $now): array
    {
        $expires = $now + self::PUZZLE_TTL;

        return [
            'challenge' => $this->puzzleFor($scope, $expires),
            'difficulty' => $this->difficulty,
            'expires' => $expires,
        ];
    }

    public function solved(string $scope, int $expires, string $nonce, int $now): bool
    {
        // expires is covered by the HMAC, so a client can't extend it; the upper bound only
        // rejects puzzles issued under a longer PUZZLE_TTL than this one
        if ($expires < $now || $expires > $now + self::PUZZLE_TTL) {
            return false;
        }
        if (!preg_match('/^[0-9a-z]{1,16}$/', $nonce)) {
            return false;
        }

        $hash = hash('sha256', $this->puzzleFor($scope, $expires) . $nonce, true);

        return self::leadingZeroBits($hash) >= $this->difficulty;
    }

    /** The cookie value for a solved puzzle. */
    public function pass(string $scope, int $now): string
    {
        $expires = $now + $this->passTtl;

        return $expires . '.' . $this->mac("pass|$scope|$expires");
    }

    public function valid(?string $pass, string $scope, int $now): bool
    {
        if ($pass === null || !preg_match('/^(\d{1,12})\.([A-Za-z0-9_-]{43})$/', $pass, $m)) {
            return false;
        }
        $expires = (int) $m[1];

        return $expires >= $now && hash_equals($this->mac("pass|$scope|$expires"), $m[2]);
    }

    public static function leadingZeroBits(string $bytes): int
    {
        $bits = 0;
        foreach (str_split($bytes) as $byte) {
            $b = ord($byte);
            if ($b === 0) {
                $bits += 8;
                continue;
            }
            while (($b & 0x80) === 0) {
                $bits++;
                $b <<= 1;
            }
            break;
        }

        return $bits;
    }

    private function puzzleFor(string $scope, int $expires): string
    {
        return $this->mac("puzzle|{$this->difficulty}|$scope|$expires");
    }

    private function mac(string $message): string
    {
        return rtrim(strtr(base64_encode(hash_hmac('sha256', $message, $this->secret, true)), '+/', '-_'), '=');
    }
}
