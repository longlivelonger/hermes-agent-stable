const { createRequire } = require('node:module');
const path = require('node:path');
const fs = require('node:fs');
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
  let app;
  try {
    app = await _electron.launch({ executablePath, env, timeout: 120000 });
    const page = await app.firstWindow({ timeout: 120000 });
    await page.waitForLoadState('domcontentloaded');
    await page.waitForFunction(() => document.body?.innerText.trim().length > 30, { timeout: 120000 });
    const text = await page.locator('body').innerText();
    fs.writeFileSync(path.join(process.env.RUNNER_TEMP, 'hermes-release', 'desktop-smoke.txt'), text);
    await page.screenshot({ path: path.join(process.env.RUNNER_TEMP, 'hermes-release', 'desktop-smoke.png') });
    if (/ERR_FILE_NOT_FOUND|Cannot find module|JavaScript error occurred/i.test(text)) throw new Error(text);
    console.log('Packaged Desktop renderer opened:', text.slice(0, 500));
  } finally {
    if (app) await app.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
