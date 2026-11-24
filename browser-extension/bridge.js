// Pure bridge between the browser's tab API and a message sink.
// No chrome globals here: background.js passes `chrome` in, tests pass a fake.
//
// Browser -> app: every tab/window event the browser fires is turned into one
// message the instant it fires ({type:"event", kind, seq, t, ...}). Nothing polls.
// App -> browser: {type:"cmd", id, op, ...} runs the matching chrome.* call and
// answers {type:"ack", id, ok}. The resulting change reaches the app through the
// normal event path, so the app has one source of truth.

export const PROTOCOL = 1;

export function serializeTab(t) {
  return {
    id: t.id,
    windowId: t.windowId,
    index: t.index,
    title: t.title || "",
    url: t.url || t.pendingUrl || "",
    favIconUrl: t.favIconUrl || "",
    active: !!t.active,
    pinned: !!t.pinned,
    audible: !!t.audible,
    status: t.status || "",
  };
}

// `favicon(pageUrl)` resolves to a data: URL of the browser's cached icon for
// that page, or "" (background.js reads Chrome's local favicon store; the app
// itself never fetches anything from the network).
export function createBridge(chrome, send, now = () => Date.now(), favicon = async () => "") {
  let seq = 0;
  const emit = (kind, body) => send({ type: "event", kind, seq: ++seq, t: now(), ...body });
  const iconSent = new Map(); // tabId -> page URL whose icon was last sent

  async function sendFavicon(tab) {
    const page = tab.url || tab.pendingUrl || "";
    if (!/^https?:/.test(page) || iconSent.get(tab.id) === page) return;
    iconSent.set(tab.id, page);
    let data = "";
    try { data = await favicon(page); } catch {}
    if (data) emit("tabFavicon", { tabId: tab.id, favicon: data });
  }

  async function snapshot() {
    const wins = await chrome.windows.getAll({ populate: true, windowTypes: ["normal", "popup", "app"] });
    // seq is assigned AFTER the await so no event can slip between the
    // snapshot's contents and its sequence number.
    send({
      type: "snapshot",
      seq: ++seq,
      t: now(),
      windows: wins.map((w) => ({
        id: w.id,
        focused: !!w.focused,
        incognito: !!w.incognito,
        tabs: (w.tabs || []).map(serializeTab),
      })),
    });
    // Icons follow the snapshot, one event per tab, so the list appears at once.
    iconSent.clear();
    for (const w of wins) for (const t of w.tabs || []) sendFavicon(t);
  }

  const listeners = [
    [chrome.tabs.onCreated, (tab) => emit("tabCreated", { tab: serializeTab(tab) })],
    [chrome.tabs.onUpdated, (tabId, changes, tab) => {
      emit("tabUpdated", { tab: serializeTab(tab), changes: Object.keys(changes) });
      if (changes.favIconUrl || changes.status === "complete") sendFavicon(tab);
    }],
    [chrome.tabs.onRemoved, (tabId, info) => {
      iconSent.delete(tabId);
      emit("tabRemoved", { tabId, windowId: info.windowId, isWindowClosing: !!info.isWindowClosing });
    }],
    [chrome.tabs.onMoved, (tabId, info) => emit("tabMoved", { tabId, windowId: info.windowId, fromIndex: info.fromIndex, toIndex: info.toIndex })],
    [chrome.tabs.onActivated, (info) => emit("tabActivated", { tabId: info.tabId, windowId: info.windowId })],
    [chrome.tabs.onDetached, (tabId, info) => emit("tabDetached", { tabId, windowId: info.oldWindowId, fromIndex: info.oldPosition })],
    [chrome.tabs.onAttached, (tabId, info) => emit("tabAttached", { tabId, windowId: info.newWindowId, toIndex: info.newPosition })],
    [chrome.tabs.onReplaced, async (addedTabId, removedTabId) => {
      let tab = null;
      try { tab = serializeTab(await chrome.tabs.get(addedTabId)); } catch {}
      emit("tabReplaced", { tabId: addedTabId, removedTabId, tab });
    }],
    [chrome.windows.onCreated, (w) => emit("windowCreated", { windowId: w.id, focused: !!w.focused, incognito: !!w.incognito })],
    [chrome.windows.onRemoved, (windowId) => emit("windowRemoved", { windowId })],
    [chrome.windows.onFocusChanged, (windowId) => emit("windowFocused", { windowId })],
  ];

  function attach() {
    for (const [ev, fn] of listeners) ev.addListener(fn);
  }
  function detach() {
    for (const [ev, fn] of listeners) ev.removeListener(fn);
  }

  async function targetWindowId(windowId) {
    if (Number.isInteger(windowId)) return windowId;
    try {
      const w = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
      return w && w.id;
    } catch {
      return undefined;
    }
  }

  async function run(cmd) {
    switch (cmd.op) {
      case "snapshot":
        return snapshot();
      case "open": {
        const url = String(cmd.url || "");
        if (!/^(https?|chrome|about|file):/i.test(url)) throw new Error("refused url: " + url);
        const windowId = await targetWindowId(cmd.windowId);
        if (windowId === undefined) return chrome.windows.create({ url, focused: true });
        await chrome.tabs.create({ url, windowId, active: cmd.active !== false });
        if (cmd.focus) await chrome.windows.update(windowId, { focused: true });
        return;
      }
      case "close":
        return chrome.tabs.remove(cmd.tabId);
      case "activate": {
        const tab = await chrome.tabs.update(cmd.tabId, { active: true });
        if (cmd.focus !== false && tab) await chrome.windows.update(tab.windowId, { focused: true });
        return;
      }
      default:
        throw new Error("unknown op: " + cmd.op);
    }
  }

  async function handle(msg) {
    if (!msg || msg.type !== "cmd") return;
    try {
      await run(msg);
      send({ type: "ack", id: msg.id, ok: true, t: now() });
    } catch (e) {
      send({ type: "ack", id: msg.id, ok: false, error: String((e && e.message) || e), t: now() });
    }
  }

  return { attach, detach, handle, snapshot };
}
