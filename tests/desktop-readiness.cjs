// Serialized by Playwright into the renderer. Probe through the same IPC bridge
// as the UI so a listening but disconnected/unusable backend cannot pass.
async function desktopReady(expectedVersion) {
  const text = document.getElementById('root')?.textContent || '';
  if (!/provider|API key|Sign in/i.test(text)) return false;
  if (/Waiting for Hermes backend|Starting Hermes|Waking up|Boot failed|Failed to start|Something broke in the interface/i.test(text)) return false;
  if (!window.hermesDesktop?.api) return false;
  try {
    const health = await window.hermesDesktop.api({ connectionId: 'local', method: 'GET', path: '/api/health' });
    return health?.ok === true && health.version === expectedVersion;
  } catch {
    return false;
  }
}

module.exports = { desktopReady };
