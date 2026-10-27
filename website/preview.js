// gladios.dev/preview/: the real challenge page (public/index.html and gladios.js, unchanged), with
// nginx's two answers made up here. Verify sets a cookie as nginx would, so the reload that follows
// lands "on the site" rather than on the check again.
(() => {
    const COOKIE = 'gladios-preview';
    // the check is slowed to this, so there's a page to look at
    const SHOW = 3000;
    const encoder = new TextEncoder();

    if (document.cookie.split('; ').includes(`${COOKIE}=1`)) {
        document.cookie = `${COOKIE}=; Max-Age=0; Path=/preview/`;
        // this pass is spent: don't let gladios.js's loop guard count it next time
        try {
            sessionStorage.removeItem('gladios');
        } catch {}
        // gladios.js still starts the check; its puzzle never comes, out of sight
        window.fetch = () => new Promise(() => {});
        document.addEventListener('DOMContentLoaded', () => {
            document.title = 'You’re through';
            document.querySelector('main').hidden = true;
            const site = document.createElement('main');
            site.innerHTML = `
                <img src="/.gladios/mascot" width="220" height="241" alt="">
                <h1>You’re through</h1>
                <p>On your site, this is where the page they asked for loads. The pass lasts a week on
                    this network, so they won’t see the check again until then.</p>
                <p style="margin-top: 12px">The check was slowed to ${SHOW / 1000} seconds here so you could see it.</p>
                <p style="margin-top: 20px; color: var(--fg)">
                    <a href="/preview/" style="color: inherit">See the check again</a> ·
                    <a href="/" style="color: inherit">Back to gladios.dev</a>
                </p>`;
            document.body.append(site);
        });
        return;
    }

    const zeroBits = (bytes) => {
        let bits = 0;
        for (const byte of bytes) {
            if (byte !== 0) return bits + Math.clz32(byte) - 24;
            bits += 8;
        }
        return bits;
    };
    let puzzle = null;
    let asked = 0;
    const json = (value) => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
    const fetch = window.fetch.bind(window);

    window.fetch = async (input, init = {}) => {
        const path = new URL(input instanceof Request ? input.url : input, location.href).pathname;
        if (path === '/.gladios/api/challenge') {
            const bytes = crypto.getRandomValues(new Uint8Array(32));
            const challenge = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
            puzzle = { challenge, difficulty: 16, expires: Math.floor(Date.now() / 1000) + 300 };
            asked = performance.now();
            return json(puzzle);
        }
        if (path === '/.gladios/api/verify') {
            const nonce = new URLSearchParams(String(init.body)).get('nonce') || '';
            const digest = puzzle && new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(puzzle.challenge + nonce)));
            if (!digest || zeroBits(digest) < puzzle.difficulty) return new Response(null, { status: 403 });
            await new Promise((resolve) => setTimeout(resolve, SHOW - (performance.now() - asked)));
            document.cookie = `${COOKIE}=1; Max-Age=300; Path=/preview/; SameSite=Lax`;
            return new Response(null, { status: 204 });
        }
        return fetch(input, init);
    };
})();
