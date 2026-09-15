const assert = require('node:assert/strict');
const vm = require('node:vm');
const { desktopReady, assertDesktopSnapshotReady } = require('./desktop-readiness.cjs');

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
      document: { body: { innerText: text }, getElementById: () => ({ textContent: text }) },
      window: { hermesDesktop: { api: async request => {
        assert.equal(request.connectionId, 'local');
        assert.equal(request.path, '/api/health');
        if (health instanceof Error) throw health;
        return health;
      } } },
    });
    assert.equal(actual, expected, text);
  }
  // The IPC await yields to UI updates. A healthy response must not validate
  // the setup screen that existed before the request started.
  for (const loading of ['Starting Hermes', 'Waiting for Hermes backend to launch 86%', 'Waking up', 'Boot failed', '']) {
    const root = { textContent: 'Connect a model provider' };
    const body = { innerText: root.textContent };
    const actual = await vm.runInNewContext(`(${desktopReady.toString()})('0.21.3')`, {
      document: { body, getElementById: () => root },
      window: { hermesDesktop: { api: async () => {
        root.textContent = loading;
        body.innerText = loading;
        return { ok: true, version: '0.21.3' };
      } } },
    });
    assert.equal(actual, false, `UI changed during health request: ${loading}`);
  }
  const overlay = await vm.runInNewContext(`(${desktopReady.toString()})('0.21.3')`, {
    document: {
      getElementById: () => ({ textContent: 'Connect a model provider' }),
      body: { innerText: 'Connect a model provider. Starting Hermes' },
    },
    window: { hermesDesktop: { api: async () => ({ ok: true, version: '0.21.3' }) } },
  });
  assert.equal(overlay, false, 'Loading UI outside root must block readiness too.');
  for (const state of ['Starting Hermes', 'Waiting for Hermes backend', 'Waking up', 'Boot failed', 'Failed to start', 'Something broke in the interface', 'ERR_FILE_NOT_FOUND', 'Cannot find module', 'JavaScript error occurred', 'No QueryClient set']) {
    assert.throws(() => assertDesktopSnapshotReady(`Connect a model provider. ${state}`), /snapshot is not ready/);
  }
  assert.throws(() => assertDesktopSnapshotReady(''), /snapshot is not ready/);
  assert.doesNotThrow(() => assertDesktopSnapshotReady('Connect a model provider'));
  console.log('Desktop readiness tests passed, including the published 86% loading state.');
})().catch(error => { console.error(error); process.exitCode = 1; });
