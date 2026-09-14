const assert = require('node:assert/strict');
const vm = require('node:vm');
const { desktopReady } = require('./desktop-readiness.cjs');

(async () => {
  const cases = [
    ['Connect a model provider. Waiting for Hermes backend to launch 86%', { ok: true, version: '0.21.3' }, false],
    ['Connect a model provider', { ok: false, version: '0.21.3' }, false],
    ['Connect a model provider', { ok: true, version: '0.21.2' }, false],
    ['Connect a model provider', new Error('backend unavailable'), false],
    ['Connect a model provider. Boot failed', { ok: true, version: '0.21.3' }, false],
    ['Connect a model provider', { ok: true, version: '0.21.3' }, true],
  ];
  for (const [text, health, expected] of cases) {
    const actual = await vm.runInNewContext(`(${desktopReady.toString()})('0.21.3')`, {
      document: { getElementById: () => ({ textContent: text }) },
      window: { hermesDesktop: { api: async request => {
        assert.equal(request.connectionId, 'local');
        assert.equal(request.path, '/api/health');
        if (health instanceof Error) throw health;
        return health;
      } } },
    });
    assert.equal(actual, expected, text);
  }
  console.log('Desktop readiness tests passed, including the published 86% loading state.');
})().catch(error => { console.error(error); process.exitCode = 1; });
