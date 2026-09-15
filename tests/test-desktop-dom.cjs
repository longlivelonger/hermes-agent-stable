const assert = require('node:assert/strict');
const path = require('node:path');
const { createRequire } = require('node:module');
const playwright = process.argv[2] || createRequire(path.join(process.env.RUNNER_TEMP, 'hermes-smoke-deps', 'package.json')).resolve('playwright-core');
const { chromium } = require(playwright);
const { readDesktopUi, desktopUiReady, assertDesktopSnapshotReady, waitForDesktopReady } = require('./desktop-readiness.cjs');

(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage();
    const main = '<button>New session</button><p>Gateway needs setup</p><div role="textbox" contenteditable="true" style="height:30px">Start with a goal</div>';
    const setup = '<p>Connect a model provider</p><button>Sign in</button>';
    for (const html of [main, setup]) {
      for (const css of ['opacity:0', 'display:none', 'visibility:hidden']) {
        await page.setContent(`${html}<div style="${css}"><span>Waking up</span></div>`);
        const state = await page.evaluate(readDesktopUi);
        assert.equal(desktopUiReady(state), true, `Ready UI with hidden status: ${css}`);
        assert.ok(!state.text.includes('Waking up'), 'Captured visible text must exclude hidden status.');
        assertDesktopSnapshotReady(state);
      }
      await page.setContent(`${html}<div style="position:fixed;inset:0;background:white">Starting Hermes 86%</div>`);
      assert.equal(desktopUiReady(await page.evaluate(readDesktopUi)), false, 'Visible loading overlay must block readiness.');
      await page.setContent(`${html}<div style="position:fixed;inset:0;background:white"></div>`);
      assert.equal(desktopUiReady(await page.evaluate(readDesktopUi)), false, 'Controls covered by an empty overlay must not pass.');
    }
    for (const html of [main.replace('contenteditable="true"', 'contenteditable="false"'), '<p>Connect a model provider</p>']) {
      await page.setContent(html);
      assert.equal(desktopUiReady(await page.evaluate(readDesktopUi)), false, 'A label without usable controls is insufficient.');
    }
    await page.setContent(main);
    await page.evaluate(() => {
      window.hermesDesktop = { api: async () => {
        document.body.insertAdjacentHTML('beforeend', '<div>Starting Hermes</div>');
        return { ok: true, version: '0.21.3' };
      } };
    });
    await assert.rejects(waitForDesktopReady(page, '0.21.3', { timeout: 100, polling: 10 }), /readiness timed out/);
    await page.setContent(main);
    await page.evaluate(() => { window.hermesDesktop = { api: async () => ({ ok: true, version: '0.21.3' }) }; });
    await waitForDesktopReady(page, '0.21.3', { timeout: 1000, polling: 10 });
    console.log('Real browser readiness tests passed for main/setup screens, hidden status, loading overlays, disabled controls, and IPC races.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
