// nginx served this page in place of the URL the visitor asked for. Solve the puzzle, collect the
// pass cookie, then load that URL again (as a GET, even if it was a POST).
(() => {
    const body = document.body;
    const status = document.getElementById('status');
    const retry = document.querySelector('button.retry');

    const say = (text, failed = false) => {
        status.textContent = text;
        body.classList.toggle('failed', failed);
    };

    // A browser that drops the cookie would solve and reload forever: stop after three passes
    // in two minutes. sessionStorage can be missing or throw (private modes, blocked storage).
    const recentPasses = () => {
        try {
            const now = Date.now();
            return JSON.parse(sessionStorage.getItem('gladios') || '[]').filter((t) => now - t < 120000);
        } catch {
            return [];
        }
    };
    const rememberPass = () => {
        try {
            sessionStorage.setItem('gladios', JSON.stringify([...recentPasses(), Date.now()]));
        } catch {}
    };

    const solve = ({ challenge, difficulty }) =>
        new Promise((resolve, reject) => {
            const count = Math.max(1, Math.min(navigator.hardwareConcurrency || 2, 8));
            const workers = [];
            const stop = () => workers.forEach((w) => w.terminate());
            for (let start = 0; start < count; start++) {
                const worker = new Worker('/.gladios/worker.js');
                worker.onmessage = ({ data }) => {
                    stop();
                    resolve(data);
                };
                worker.onerror = (event) => {
                    stop();
                    reject(new Error(event.message || 'worker failed'));
                };
                worker.postMessage({ challenge, difficulty, start, step: count });
                workers.push(worker);
            }
        });

    const run = async () => {
        say('Working…');
        if (!navigator.cookieEnabled || recentPasses().length >= 3) {
            say('Your browser isn’t keeping cookies for this site. Allow them, then try again.', true);
            return;
        }
        try {
            const res = await fetch('/.gladios/api/challenge', { cache: 'no-store', credentials: 'same-origin' });
            if (!res.ok) throw new Error(`challenge: ${res.status}`);
            const puzzle = await res.json();
            const nonce = await solve(puzzle);
            const verify = await fetch('/.gladios/api/verify', {
                method: 'POST',
                credentials: 'same-origin',
                body: new URLSearchParams({ expires: String(puzzle.expires), nonce }),
            });
            if (verify.status !== 204) throw new Error(`verify: ${verify.status}`);
            rememberPass();
            say('Done. Loading…');
            location.replace(location.href);
        } catch (error) {
            console.error('gladios', error);
            say('The check didn’t finish.', true);
        }
    };

    retry.addEventListener('click', () => {
        try {
            sessionStorage.removeItem('gladios');
        } catch {}
        run();
    });
    run();
})();
