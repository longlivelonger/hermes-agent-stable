// Serialized by Playwright into the renderer. Probe through the same IPC bridge
// as the UI so a listening but disconnected/unusable backend cannot pass.
async function desktopReady(expectedVersion) {
  if (!window.hermesDesktop?.api) return false;
  try {
    const health = await window.hermesDesktop.api({ connectionId: 'local', method: 'GET', path: '/api/health' });
    if (health?.ok !== true || health.version !== expectedVersion) return false;
    // Read the current visible UI after IPC completes. React may change it
    // during the request, and loading overlays can live outside #root.
    const text = document.body?.innerText || '';
    if (!/provider|API key|Sign in/i.test(text)) return false;
    return !/Waiting for Hermes backend|Starting Hermes|Waking up|Boot failed|Failed to start|Something broke in the interface/i.test(text);
  } catch {
    return false;
  }
}

// Validate the actual captured artifact too: UI can change again between a
// successful readiness poll and the screenshot/text capture.
function assertDesktopSnapshotReady(text) {
  if (!/provider|API key|Sign in/i.test(text) || /Waiting for Hermes backend|Starting Hermes|Waking up|Boot failed|Failed to start|Something broke in the interface|ERR_FILE_NOT_FOUND|Cannot find module|JavaScript error occurred|No QueryClient set/i.test(text)) {
    throw new Error(`Desktop snapshot is not ready: ${text}`);
  }
}

async function waitForDesktopReady(page, expectedVersion, { timeout = 180000, polling = 1000 } = {}) {
  const deadline = Date.now() + timeout;
  const timedOut = () => new Error(`Desktop readiness timed out after ${timeout}ms.`);
  while (Date.now() < deadline) {
    let timer;
    try {
      // waitForFunction treats the async predicate's Promise as truthy, even
      // when it resolves to false. evaluate awaits that resolved boolean.
      const ready = await Promise.race([
        page.evaluate(desktopReady, expectedVersion),
        new Promise((_, reject) => { timer = setTimeout(() => reject(timedOut()), Math.max(1, deadline - Date.now())); }),
      ]);
      if (ready === true) return;
    } finally { clearTimeout(timer); }
    await new Promise(resolve => setTimeout(resolve, Math.min(polling, Math.max(0, deadline - Date.now()))));
  }
  throw timedOut();
}

module.exports = { desktopReady, assertDesktopSnapshotReady, waitForDesktopReady };
