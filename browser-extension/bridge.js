// Pure bridge between the browser's tab API and a message sink.
// No chrome globals here: background.js passes `chrome` in, tests pass a fake.
//
// Browser -> app: every tab/window event the browser fires is turned into one
// message the instant it fires ({type:"event", kind, seq, t, ...}). Nothing polls.
// App -> browser: {type:"cmd", id, op, ...} runs the matching chrome.* call and
// answers {type:"ack", id, ok}. The resulting change reaches the app through the
// normal event path, so the app has one source of truth.

export const PROTOCOL = 1;

// Every command this copy runs. Sent in the hello, so the app only offers what
// the installed extension can do (an older copy keeps working, with less).
export const OPS = ["snapshot", "open", "close", "activate", "move", "mute", "duplicate", "reload", "navigate", "closeMany", "newWindow", "reloadSelf"];

// The windows the app is told of: the snapshot lists these types, and the
// window events are asked for the same ones (left to itself Chrome sends them
// only for normal and popup windows, so an app window would open unannounced).
export const WINDOW_TYPES = ["normal", "popup", "app"];
// Every type there is, to ask what one window is.
const EVERY_WINDOW_TYPE = ["normal", "popup", "panel", "app", "devtools"];

// What the app may ask a tab to load. Never javascript: or data:.
const OPENABLE = /^(https?|chrome|about|file):/i;

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
    muted: !!(t.mutedInfo && t.mutedInfo.muted),
    status: t.status || "",
  };
}

// `favicon(pageUrl)` resolves to a data: URL of the browser's cached icon for
// that page, or "" (background.js reads Chrome's local favicon store; the app
// itself never fetches anything from the network).
// A window's frame in screen points, top-left origin (the same as macOS Accessibility).
export function bounds(w) {
  return { left: w.left ?? null, top: w.top ?? null, width: w.width ?? null, height: w.height ?? null };
}

//
// `diskVersion()` resolves to the version in the manifest.json on disk. For a
// copy loaded unpacked that can be newer than the one running, because the
// betterlink app replaces the files when it updates.
export function createBridge(chrome, send, now = () => Date.now(), favicon = async () => "", diskVersion = async () => "") {
  let seq = 0;
  const emit = (kind, body) => send({ type: "event", kind, seq: ++seq, t: now(), ...body });
  const iconSent = new Map(); // tabId -> page URL whose icon was last sent
  const tabSent = new Map(); // tabId -> the tab as last sent in an update
  const told = new Set(); // windows the app has been sent, by the snapshot or their own event
  let snapped = false;

  const windowBody = (w) => ({ windowId: w.id, focused: !!w.focused, incognito: !!w.incognito, windowType: w.type || null, ...bounds(w) });

  // A tab can name a window the app was never sent (one of a type that has no
  // events here, or whose event is still to come). The app must not take it
  // for a normal window, so the window is asked for and sent as its own
  // event, right behind the tab's. Once per window; nothing before the first
  // snapshot, which lists the windows itself.
  async function tellWindow(windowId) {
    if (!snapped || !Number.isInteger(windowId) || told.has(windowId)) return;
    told.add(windowId);
    try {
      const w = await chrome.windows.get(windowId, { windowTypes: EVERY_WINDOW_TYPE });
      if (told.has(windowId)) emit("windowCreated", windowBody(w));
    } catch {
      told.delete(windowId); // gone already, or not to be had
    }
  }

  async function sendFavicon(tab) {
    const page = tab.url || tab.pendingUrl || "";
    if (!/^https?:/.test(page) || iconSent.get(tab.id) === page) return;
    iconSent.set(tab.id, page);
    let data = "";
    try { data = await favicon(page); } catch {}
    if (data) emit("tabFavicon", { tabId: tab.id, favicon: data });
  }

  // Each window goes with the browser's own word for what it is (`windowType`:
  // normal, popup or app), so the app pairs a sidebar only with a normal one.
  async function snapshot() {
    const wins = await chrome.windows.getAll({ populate: true, windowTypes: WINDOW_TYPES });
    told.clear();
    for (const w of wins) told.add(w.id);
    snapped = true;
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
        windowType: w.type || null,
        ...bounds(w),
        tabs: (w.tabs || []).map(serializeTab),
      })),
    });
    // Icons follow the snapshot, one event per tab, so the list appears at once.
    iconSent.clear();
    tabSent.clear();
    for (const w of wins) for (const t of w.tabs || []) sendFavicon(t);
  }

  // The window events take a filter of window types; the tab events take none.
  const windowFilter = { windowTypes: WINDOW_TYPES };
  const listeners = [
    [chrome.tabs.onCreated, (tab) => {
      emit("tabCreated", { tab: serializeTab(tab) });
      tellWindow(tab.windowId);
    }],
    [chrome.tabs.onUpdated, (tabId, changes, tab) => {
      // Chrome also fires for what the app never sees (groups, freezing, a
      // title set to what it was): nothing to say then.
      const body = serializeTab(tab);
      const same = JSON.stringify(body);
      if (tabSent.get(tabId) !== same) {
        tabSent.set(tabId, same);
        emit("tabUpdated", { tab: body, changes: Object.keys(changes) });
      }
      if (changes.favIconUrl || changes.status === "complete") sendFavicon(tab);
    }],
    [chrome.tabs.onRemoved, (tabId, info) => {
      iconSent.delete(tabId);
      tabSent.delete(tabId);
      emit("tabRemoved", { tabId, windowId: info.windowId, isWindowClosing: !!info.isWindowClosing });
    }],
    [chrome.tabs.onMoved, (tabId, info) => emit("tabMoved", { tabId, windowId: info.windowId, fromIndex: info.fromIndex, toIndex: info.toIndex })],
    [chrome.tabs.onActivated, (info) => emit("tabActivated", { tabId: info.tabId, windowId: info.windowId })],
    [chrome.tabs.onDetached, (tabId, info) => emit("tabDetached", { tabId, windowId: info.oldWindowId, fromIndex: info.oldPosition })],
    [chrome.tabs.onAttached, (tabId, info) => {
      emit("tabAttached", { tabId, windowId: info.newWindowId, toIndex: info.newPosition });
      tellWindow(info.newWindowId);
    }],
    [chrome.tabs.onReplaced, async (addedTabId, removedTabId) => {
      let tab = null;
      try { tab = serializeTab(await chrome.tabs.get(addedTabId)); } catch {}
      emit("tabReplaced", { tabId: addedTabId, removedTabId, tab });
    }],
    [chrome.windows.onCreated, (w) => {
      told.add(w.id);
      emit("windowCreated", windowBody(w));
    }, windowFilter],
    [chrome.windows.onRemoved, (windowId) => {
      told.delete(windowId);
      emit("windowRemoved", { windowId });
    }, windowFilter],
    [chrome.windows.onFocusChanged, (windowId) => emit("windowFocused", { windowId }), windowFilter],
  ];
  // Where each window is on screen, so the app can tell which browser profile
  // owns the window in front (every profile runs its own copy of this extension).
  if (chrome.windows.onBoundsChanged) {
    listeners.push([chrome.windows.onBoundsChanged, (w) => emit("windowBounds", { windowId: w.id, ...bounds(w) })]);
  }

  function attach() {
    for (const [ev, fn, filter] of listeners) filter ? ev.addListener(fn, filter) : ev.addListener(fn);
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

  function tabId(cmd) {
    if (!Number.isInteger(cmd.tabId)) throw new Error("no tab id");
    return cmd.tabId;
  }

  // Runs one command. May return fields for the ack (the tab a command made).
  async function run(cmd) {
    switch (cmd.op) {
      case "snapshot":
        await snapshot();
        return;
      case "open": {
        const url = String(cmd.url || "");
        if (!OPENABLE.test(url)) throw new Error("refused url: " + url);
        const windowId = await targetWindowId(cmd.windowId);
        if (windowId === undefined) {
          const w = await chrome.windows.create({ url, focused: true });
          const first = w && w.tabs && w.tabs[0];
          return first ? { tabId: first.id } : undefined;
        }
        const tab = await chrome.tabs.create({ url, windowId, active: cmd.active !== false });
        if (cmd.focus) await chrome.windows.update(windowId, { focused: true });
        return tab ? { tabId: tab.id } : undefined;
      }
      case "close":
        await chrome.tabs.remove(tabId(cmd));
        return;
      case "closeMany": {
        const ids = Array.isArray(cmd.tabIds) ? cmd.tabIds.filter(Number.isInteger) : [];
        if (ids.length) await chrome.tabs.remove(ids);
        return;
      }
      case "activate": {
        const tab = await chrome.tabs.update(tabId(cmd), { active: true });
        if (cmd.focus !== false && tab) await chrome.windows.update(tab.windowId, { focused: true });
        return;
      }
      case "move": {
        if (!Number.isInteger(cmd.index)) throw new Error("no index");
        const to = { index: cmd.index };
        if (Number.isInteger(cmd.windowId)) to.windowId = cmd.windowId;
        await chrome.tabs.move(tabId(cmd), to);
        return;
      }
      case "mute":
        await chrome.tabs.update(tabId(cmd), { muted: cmd.muted !== false });
        return;
      case "duplicate": {
        const tab = await chrome.tabs.duplicate(tabId(cmd));
        return tab ? { tabId: tab.id } : undefined;
      }
      case "reload":
        await chrome.tabs.reload(tabId(cmd));
        return;
      case "navigate": {
        const url = String(cmd.url || "");
        if (!OPENABLE.test(url)) throw new Error("refused url: " + url);
        const tab = await chrome.tabs.update(tabId(cmd), cmd.focus === false ? { url } : { url, active: true });
        if (cmd.focus !== false && tab) await chrome.windows.update(tab.windowId, { focused: true });
        return;
      }
      case "newWindow":
        // The tab leaves its window for a new one of its own.
        await chrome.windows.create({ tabId: tabId(cmd), focused: true });
        return;
      case "reloadSelf": {
        // The app says the files this copy was loaded from have changed. Reload
        // only if they really are another version: a copy loaded from somewhere
        // the app doesn't manage, or the store's own copy, stays as it is, so
        // this can never loop.
        const running = chrome.runtime.getManifest().version;
        let onDisk = "";
        try { onDisk = await diskVersion(); } catch {}
        if (!onDisk || onDisk === running) throw new Error("nothing newer on disk (running " + running + ")");
        return { reload: true };
      }
      default:
        throw new Error("unknown op: " + cmd.op);
    }
  }

  async function handle(msg) {
    if (!msg || msg.type !== "cmd") return;
    try {
      const { reload, ...extra } = (await run(msg)) || {};
      send({ type: "ack", id: msg.id, ok: true, t: now(), ...extra });
      // After the ack, so the app hears yes before this copy restarts.
      if (reload) chrome.runtime.reload();
    } catch (e) {
      send({ type: "ack", id: msg.id, ok: false, error: String((e && e.message) || e), t: now() });
    }
  }

  return { attach, detach, handle, snapshot };
}
