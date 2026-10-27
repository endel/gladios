// Copy buttons, and the demo: public/worker.js, the solver visitors run, on a puzzle made up here.
(() => {
    for (const button of document.querySelectorAll('button.copy')) {
        button.addEventListener('click', async () => {
            try {
                await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
                button.textContent = 'Copied';
            } catch {
                button.textContent = 'Select it';
            }
            setTimeout(() => (button.textContent = 'Copy'), 1600);
        });
    }

    const demo = document.querySelector('.demo');
    // slowed to this, so there's a page to look at; the numbers stay real
    const SHOW = 2500;
    const $ = (id) => document.getElementById(id);
    const proof = demo.querySelector('.proof');
    let workers = [];
    let runs = 0;

    const stop = () => {
        workers.forEach((w) => w.terminate());
        workers = [];
    };
    const say = (state, text) => {
        demo.dataset.state = state;
        $('status').textContent = text;
    };
    const puzzle = () => {
        const bytes = crypto.getRandomValues(new Uint8Array(32));
        return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    };
    const solve = (challenge, difficulty, threads) =>
        new Promise((resolve, reject) => {
            for (let start = 0; start < threads; start++) {
                const worker = new Worker('/.gladios/worker.js');
                worker.onmessage = ({ data }) => resolve(data);
                worker.onerror = (event) => reject(new Error(event.message || 'worker failed'));
                worker.postMessage({ challenge, difficulty, start, step: threads });
                workers.push(worker);
            }
        });

    const run = async () => {
        const run = ++runs;
        stop();
        if (!window.crypto?.subtle || !window.Worker) {
            say('failed', 'This browser can’t run the check.');
            return;
        }
        const difficulty = Number($('difficulty').value);
        const threads = Math.max(1, Math.min(navigator.hardwareConcurrency || 2, 8));
        const challenge = puzzle();
        say('working', 'Working…');
        $('run').disabled = true;
        try {
            const started = performance.now();
            const nonce = await solve(challenge, difficulty, threads);
            const seconds = (performance.now() - started) / 1000;
            stop();
            await new Promise((resolve) => setTimeout(resolve, SHOW - (performance.now() - started)));
            if (run !== runs) return;
            // what the server does with it: one hash
            const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(challenge + nonce)));
            const hex = Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
            const zeros = hex.match(/^0*/)[0].length;
            // the workers interleave nonces, so the winner's index is about how many were tried in all
            const tried = parseInt(nonce, 36) + 1;

            $('took').textContent = `${seconds < 10 ? seconds.toFixed(2) : seconds.toFixed(1)} s`;
            $('tried').textContent = tried >= 1e6 ? `${(tried / 1e6).toFixed(1)}M` : tried >= 1e4 ? `${Math.round(tried / 1e3)}k` : tried.toLocaleString('en');
            $('threads').textContent = String(threads);
            const hash = $('hash');
            hash.textContent = '';
            hash.append(`sha256(puzzle + "${nonce}") = `);
            const lead = document.createElement('b');
            lead.textContent = hex.slice(0, zeros);
            hash.append(lead, `${hex.slice(zeros, 40)}…`);
            proof.hidden = false;
            say('done', 'Done. Your page loads now.');
        } catch (error) {
            console.error('gladios demo', error);
            say('failed', 'The check didn’t finish.');
        } finally {
            if (run === runs) {
                $('run').disabled = false;
                $('run').textContent = 'Run it again';
            }
        }
    };

    $('run').addEventListener('click', run);
    $('difficulty').addEventListener('change', run);
    // run once when it comes into view: that second is the whole pitch
    if ('IntersectionObserver' in window) {
        const seen = new IntersectionObserver((entries) => {
            if (entries.some((e) => e.isIntersecting)) {
                seen.disconnect();
                run();
            }
        }, { threshold: 0.5 });
        seen.observe(demo);
    }
})();
