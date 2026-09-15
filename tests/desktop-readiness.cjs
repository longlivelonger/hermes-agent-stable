// Both renderer functions are self-contained so Playwright can serialize them.
async function desktopHealthReady(expectedVersion) {
  if (!window.hermesDesktop?.api) return false;
  try {
    const health = await window.hermesDesktop.api({ connectionId: 'local', method: 'GET', path: '/api/health' });
    return health?.ok === true && health.version === expectedVersion;
  } catch {
    return false;
  }
}

function readDesktopUi() {
  const visible = element => element.checkVisibility({ opacityProperty: true, visibilityProperty: true });
  const usable = element => {
    if (!visible(element) || element.matches(':disabled, [aria-disabled="true"]') || element.closest('[inert]')) return false;
    const box = element.getBoundingClientRect();
    const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
    return hit === element || element.contains(hit);
  };
  // innerText includes opacity:0 status labels. Read painted text nodes so an
  // inactive spinner does not make a usable main window look stuck loading.
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const lines = [];
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (node.textContent.trim() && visible(node.parentElement)) lines.push(node.textContent.trim());
  }
  return {
    text: lines.join('\n'),
    composerReady: [...document.querySelectorAll('[role="textbox"][contenteditable="true"]')].some(usable),
    providerReady: [...document.querySelectorAll('button, input')].some(element =>
      usable(element) && /sign\s+in|connect|API\s+key|Anthropic|OpenAI|Nous/i.test(element.innerText || element.getAttribute('aria-label') || element.placeholder || '')),
  };
}

function desktopUiReady(state) {
  const text = state.text.replace(/\s+/g, ' ');
  if (/Waiting for Hermes backend|Starting Hermes|Waking up|Boot failed|Failed to start|Something broke in the interface|ERR_FILE_NOT_FOUND|Cannot find module|JavaScript error occurred|No QueryClient set/i.test(text)) return false;
  return Boolean((state.composerReady && /New session/i.test(text)) || (state.providerReady && /provider|API key|Sign in/i.test(text)));
}

// Validate the actual captured artifact too: UI can change again between a
// successful readiness poll and the screenshot/text capture.
function assertDesktopSnapshotReady(state) {
  if (!desktopUiReady(state)) {
    throw new Error(`Desktop snapshot is not ready: ${state.text}`);
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
        (async () => {
          if (!await page.evaluate(desktopHealthReady, expectedVersion)) return false;
          // Read UI only after health IPC resolves, never reuse an earlier DOM.
          return desktopUiReady(await page.evaluate(readDesktopUi));
        })(),
        new Promise((_, reject) => { timer = setTimeout(() => reject(timedOut()), Math.max(1, deadline - Date.now())); }),
      ]);
      if (ready === true) return;
    } finally { clearTimeout(timer); }
    await new Promise(resolve => setTimeout(resolve, Math.min(polling, Math.max(0, deadline - Date.now()))));
  }
  throw timedOut();
}

module.exports = { desktopHealthReady, readDesktopUi, desktopUiReady, assertDesktopSnapshotReady, waitForDesktopReady };
