const assert = require('node:assert/strict');
const vm = require('node:vm');
const { desktopHealthReady, readDesktopUi, desktopUiReady, assertDesktopSnapshotReady, waitForDesktopReady } = require('./desktop-readiness.cjs');

(async () => {
  for (const [health, expected] of [
    [{ ok: true, version: '0.21.3' }, true],
    [{ ok: false, version: '0.21.3' }, false],
    [{ ok: true, version: '0.21.2' }, false],
    [new Error('backend unavailable'), false],
  ]) {
    const actual = await vm.runInNewContext(`(${desktopHealthReady.toString()})('0.21.3')`, {
      window: { hermesDesktop: { api: async request => {
        assert.equal(request.connectionId, 'local');
        assert.equal(request.path, '/api/health');
        if (health instanceof Error) throw health;
        return health;
      } } },
    });
    assert.equal(actual, expected);
  }
  const setup = { text: 'Connect a model provider', providerReady: true, composerReady: false };
  const main = { text: 'New session. Gateway needs setup', providerReady: false, composerReady: true };
  for (const ready of [setup, main]) {
    assert.doesNotThrow(() => assertDesktopSnapshotReady(ready));
    for (const state of ['Starting Hermes', 'Waiting for Hermes backend', 'Waking up', 'Boot failed', 'Failed to start', 'Something broke in the interface', 'ERR_FILE_NOT_FOUND', 'Cannot find module', 'JavaScript error occurred', 'No QueryClient set']) {
      assert.throws(() => assertDesktopSnapshotReady({ ...ready, text: ready.text + '. ' + state }), /snapshot is not ready/);
    }
  }
  assert.equal(desktopUiReady({ ...main, composerReady: false }), false);
  assert.equal(desktopUiReady({ ...setup, providerReady: false }), false);
  assert.equal(desktopUiReady({ text: '', composerReady: true }), false);

  // UI can change during health IPC; the poll must inspect it afterwards.
  let ui = setup;
  let calls = 0;
  await assert.rejects(waitForDesktopReady({ evaluate: async predicate => {
    if (predicate === desktopHealthReady) {
      ui = { ...setup, text: 'Starting Hermes 86%' };
      calls++;
      return true;
    }
    assert.equal(predicate, readDesktopUi);
    return ui;
  } }, '0.21.3', { timeout: 30, polling: 1 }), /readiness timed out/);
  assert.ok(calls > 0);

  let polls = 0;
  await waitForDesktopReady({ evaluate: async predicate => predicate === desktopHealthReady ? ++polls === 3 : main }, '0.21.3', { timeout: 1000, polling: 1 });
  assert.equal(polls, 3, 'Poll the resolved boolean, not the truthy Promise.');
  await assert.rejects(waitForDesktopReady({ evaluate: async () => false }, '0.21.3', { timeout: 30, polling: 1 }), /readiness timed out/);
  await assert.rejects(waitForDesktopReady({ evaluate: () => new Promise(() => {}) }, '0.21.3', { timeout: 30 }), /readiness timed out/);
  console.log('Desktop readiness tests passed, including UI changes during IPC and stalled requests.');
})().catch(error => { console.error(error); process.exitCode = 1; });
