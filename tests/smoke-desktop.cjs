const { createRequire } = require('node:module');
const path = require('node:path');
const fs = require('node:fs');
const { desktopReady, assertDesktopSnapshotReady } = require('./desktop-readiness.cjs');
const { _electron } = createRequire(path.join(process.env.RUNNER_TEMP, 'hermes-smoke-deps', 'package.json'))('playwright-core');

(async () => {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/(TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL)/i.test(key)) delete env[key];
  }
  delete env.ELECTRON_RUN_AS_NODE;
  env.HERMES_DESKTOP_USER_DATA_DIR = path.join(process.env.RUNNER_TEMP, 'hermes-desktop-smoke-user');
  env.HERMES_DESKTOP_HERMES_ROOT = path.join(env.HERMES_HOME, 'hermes-agent');
  env.HERMES_DESKTOP_SKIP_QUIT_CONFIRM = '1';
  const executablePath = path.join(env.HERMES_DESKTOP_HERMES_ROOT, 'apps/desktop/release/win-unpacked/Hermes.exe');
  // Desktop's npm package has its own version; /api/health reports Agent's.
  const agentModule = fs.readFileSync(path.join(env.HERMES_DESKTOP_HERMES_ROOT, 'hermes_cli/__init__.py'), 'utf8');
  const expectedVersion = agentModule.match(/^__version__\s*=\s*["']([^"']+)["']/m)?.[1];
  if (!expectedVersion) throw new Error('Cannot read the pinned Agent version for backend verification.');
  const outputDir = path.join(process.env.RUNNER_TEMP, 'hermes-release');
  const errors = [];
  let app;
  let page;
  let text;
  let textAfterScreenshot;
  try {
    app = await _electron.launch({ executablePath, env, timeout: 120000 });
    page = await app.firstWindow({ timeout: 120000 });
    page.on('pageerror', error => errors.push(error.message));
    await page.waitForLoadState('domcontentloaded');
    await page.waitForFunction(desktopReady, expectedVersion, { timeout: 180000, polling: 1000 });
  } finally {
    try {
      if (page) {
        text = await page.locator('body').innerText();
        fs.writeFileSync(path.join(outputDir, 'desktop-smoke.txt'), text);
        await page.screenshot({ path: path.join(outputDir, 'desktop-smoke.png') });
        textAfterScreenshot = await page.locator('body').innerText();
      }
    } finally { if (app) await app.close(); }
  }
  assertDesktopSnapshotReady(text);
  assertDesktopSnapshotReady(textAfterScreenshot);
  if (errors.length) throw new Error(`Desktop renderer errors: ${errors.join('; ')}`);
  console.log(`Packaged Desktop and backend ${expectedVersion} are ready:`, text.slice(0, 500));
})().catch(error => { console.error(error); process.exitCode = 1; });
