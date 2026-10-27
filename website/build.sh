#!/bin/sh
# Builds gladios.dev into website/dist (or $1): the page, the installer, and the release the
# installer downloads.
#
# Cloudflare Pages runs it from the repo root (build command `website/build.sh`, output directory
# `website/dist`), or deploy from here with `npm run website:deploy`.
set -eu
cd "$(dirname "$0")/.."
out=${1:-website/dist}
rm -rf "$out"
mkdir -p "$out"
cp website/index.html website/site.js website/_headers website/og.png website/icon.png website/favicon.png \
    website/apple-touch-icon.png website/favicon.ico public/gladios.webp "$out/"
cp install.sh "$out/"
cp LICENSE "$out/license.txt"
cp LICENSE-ARTWORK.md "$out/license-artwork.txt"

# the challenge page's files where nginx serves them: the demo and the preview run the real thing
mkdir -p "$out/.gladios" "$out/preview"
cp public/gladios.js public/worker.js "$out/.gladios/"
cp public/gladios.webp "$out/.gladios/mascot"
cp website/preview.js "$out/preview/"
sed 's|<script src="/.gladios/gladios.js" defer></script>|<script src="/preview/preview.js"></script>&|' \
    public/index.html > "$out/preview/index.html"
grep -q preview.js "$out/preview/index.html" || { echo "build: no gladios.js script tag in public/index.html" >&2; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/gladios"
cp -R README.md LICENSE LICENSE-ARTWORK.md install.sh njs public nginx bin fail2ban cron.d systemd "$stage/gladios/"
# ustar and no AppleDouble files: busybox and GNU tar extract it without complaint
COPYFILE_DISABLE=1 tar --format=ustar -czf "$out/gladios.tar.gz" -C "$stage" gladios
echo "built $out"
