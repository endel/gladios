<?php

// The webhook gladios-notify posts to: keeps each body as /tmp/hook-<n>.json, or answers 500
// while /tmp/hook-fail exists.

if (file_exists('/tmp/hook-fail')) {
    http_response_code(500);
    exit;
}
$n = count(glob('/tmp/hook-*.json')) + 1;
file_put_contents("/tmp/hook-$n.json", file_get_contents('php://input'));
http_response_code(204);
