// Real browsers through the check, against a server with it on (test/e2e/run.sh starts one):
//
//   HOSTS=a.gladios.test,b.gladios.test node test/browser.mjs <url> [alt url] [screenshot dir]
//
// HOSTS resolve to 127.0.0.1 inside the browsers, whatever DNS says. The alt URL, on a sibling
// host, must pass on the first URL's pass (GLADIOS_COOKIE_DOMAIN). Chromium and Firefox: WebKit
// has no resolver override.
import { chromium, firefox } from 'playwright';

const [url, altUrl, shots] = process.argv.slice(2);
if (!url) {
    console.error('usage: node test/browser.mjs <url> [alt url] [screenshot dir]');
    process.exit(64);
}
const hosts = (process.env.HOSTS || new URL(url).hostname).split(',');
let failures = 0;

const check = (name, ok, detail = '') => {
    console.log(`${ok ? 'ok   ' : 'FAIL '} ${name}${detail ? `  (${detail})` : ''}`);
    if (!ok) failures++;
};
// any page that runs the solver, the default or your own
const onChallenge = (page) => page.locator('script[src="/.gladios/gladios.js"]').count().then((n) => n > 0);
const bodyText = (page) => page.locator('body').innerText();

// The check finishes faster than a screenshot, so picture a page whose puzzle never arrives.
const shoot = async (browser, colorScheme) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, colorScheme });
    context.setDefaultTimeout(30000);
    const page = await context.newPage();
    await page.route('**/.gladios/api/challenge', () => {});
    await page.goto(`${url}/`);
    await page.screenshot({ path: `${shots}/challenge-${colorScheme}.png` });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: `${shots}/challenge-${colorScheme}-phone.png` });
    await context.close();
};

const browsers = [
    ['chromium', () => chromium.launch({ args: [`--host-resolver-rules=${hosts.map((h) => `MAP ${h} 127.0.0.1`).join(',')}`] })],
    ['firefox', () => firefox.launch({ firefoxUserPrefs: { 'network.dns.localDomains': hosts.join(',') } })],
];

for (const [name, launch] of browsers) {
    console.log(`== ${name}`);
    const browser = await launch();
    try {
        for (const colorScheme of ['light', 'dark']) {
            const context = await browser.newContext({ ignoreHTTPSErrors: true, colorScheme });
            context.setDefaultTimeout(30000); // Playwright's actions otherwise wait forever
            const page = await context.newPage();
            const target = `${url}/some/page?q=1`;
            const started = Date.now();
            await page.goto(target);
            check(`${colorScheme}: challenge page first`, await onChallenge(page), await page.title());
            if (shots && name === 'chromium') await shoot(browser, colorScheme);
            await page.waitForFunction(() => !document.querySelector('script[src="/.gladios/gladios.js"]'), null, { timeout: 30000 });
            await page.waitForLoadState();
            const seconds = ((Date.now() - started) / 1000).toFixed(2);
            check(`${colorScheme}: solved, back on the same URL`, page.url() === target, `${seconds}s, ${page.url()}`);
            check(`${colorScheme}: the page itself`, !(await onChallenge(page)), (await bodyText(page)).slice(0, 80));

            await page.reload();
            check(`${colorScheme}: reload goes straight through`, !(await onChallenge(page)), (await bodyText(page)).slice(0, 80));
            if (altUrl) {
                await page.goto(altUrl);
                check(`${colorScheme}: same pass on ${new URL(altUrl).host}`, !(await onChallenge(page)), (await bodyText(page)).slice(0, 80));
            }
            await context.close();
        }

        // a failed verify shows the error and a retry that works
        const context = await browser.newContext({ ignoreHTTPSErrors: true });
        context.setDefaultTimeout(30000);
        const page = await context.newPage();
        await page.route('**/.gladios/api/verify', (route) => route.fulfill({ status: 500 }));
        await page.goto(`${url}/`);
        const retry = page.getByRole('button', { name: 'Try again' });
        await retry.waitFor({ timeout: 30000 });
        check('failure: message and retry shown', (await page.locator('#status').innerText()).includes('didn’t finish'));
        if (shots && name === 'chromium') await page.screenshot({ path: `${shots}/challenge-failed.png` });
        await page.unroute('**/.gladios/api/verify');
        await retry.click();
        await page.waitForFunction(() => !document.querySelector('script[src="/.gladios/gladios.js"]'), null, { timeout: 30000 });
        check('failure: retry gets through', !(await onChallenge(page)));
        await context.close();
    } catch (error) {
        check(`${name}: ran to the end`, false, error.message.split('\n')[0]);
    } finally {
        await browser.close();
    }
}

console.log(failures ? `\n${failures} failed` : '\nall passed');
process.exit(failures ? 1 : 0);
