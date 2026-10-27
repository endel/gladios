#!/usr/bin/env python3
"""What the browser's workers do, for tests: prints a nonce for a puzzle.

  python3 test/solve.py <challenge> <difficulty>
"""
import hashlib
import sys

DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz'


def base36(n):
    s = ''
    while True:
        n, d = divmod(n, 36)
        s = DIGITS[d] + s
        if n == 0:
            return s


challenge, difficulty = sys.argv[1], int(sys.argv[2])
n = 0
while True:
    nonce = base36(n)
    digest = int.from_bytes(hashlib.sha256((challenge + nonce).encode()).digest(), 'big')
    if 256 - digest.bit_length() >= difficulty:
        print(nonce)
        break
    n += 1
