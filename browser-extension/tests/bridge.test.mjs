// Node tests for bridge.js against a fake chrome API. Run: node --test extension/tests
import { test } from "node:test";
import assert from "node:assert/strict";
import { createBridge, OPS, serializeTab } from "../bridge.js";

function ev() {
  const fns = new Set();
  return { addListener: (f) => fns.add(f), removeListener: (f) => fns.delete(f), fire: (...a) => [...fns].map((f) => f(...a)), size: () => fns.size };
}

// A chrome.windows event as Chrome delivers it: only for the window types the
// listener's filter names, by default ['normal', 'popup'] (an app window's
// events reach no listener added without a filter). `typeOf` tells the type
// from the event's first argument; undefined (no window) always goes through.
function winEv(typeOf) {
  const fns = new Map();
  return {
    addListener: (f, filters) => fns.set(f, (filters && filters.windowTypes) || ["normal", "popup"]),
    removeListener: (f) => fns.delete(f),
    fire: (...a) => {
      const type = typeOf(a[0]);
      return [...fns].filter(([, types]) => type === undefined || types.includes(type)).map(([f]) => f(...a));
    },
    size: () => fns.size,
  };
}

function fakeChrome() {
  const windows = [{ id: 1, focused: true, incognito: false, tabs: [{ id: 10, windowId: 1, index: 0, title: "A", url: "https://a.test/", active: true }] }];
  const calls = [];
  // Every window there is, by id: the ones getAll lists and the ones opened since.
  const open = new Map();
  const find = (id) => open.get(id) || windows.find((w) => w.id === id);
  const typeOfId = (id) => (id === -1 ? undefined : (find(id) || {}).type || "normal");
  const c = {
    calls,
    tabs: {
      onCreated: ev(), onUpdated: ev(), onRemoved: ev(), onMoved: ev(), onActivated: ev(),
      onDetached: ev(), onAttached: ev(), onReplaced: ev(),
      create: async (o) => { calls.push(["tabs.create", o]); return { id: 99, windowId: o.windowId, index: 1 }; },
      remove: async (id) => { calls.push(["tabs.remove", id]); },
      update: async (id, o) => { calls.push(["tabs.update", id, o]); return { id, windowId: 1 }; },
      move: async (id, o) => { calls.push(["tabs.move", id, o]); },
      duplicate: async (id) => { calls.push(["tabs.duplicate", id]); return { id: 77, windowId: 1, index: 1 }; },
      reload: async (id) => { calls.push(["tabs.reload", id]); },
      get: async (id) => ({ id, windowId: 1, index: 0, title: "R", url: "https://r.test/" }),
    },
    windows: {
      onCreated: winEv((w) => { open.set(w.id, w); return w.type || "normal"; }), onRemoved: winEv(typeOfId), onFocusChanged: winEv(typeOfId),
      getAll: async () => windows,
      // As Chrome: a window whose type the options don't name is not found.
      get: async (id, o) => {
        calls.push(["windows.get", id, o]);
        const w = find(id);
        if (!w || !((o && o.windowTypes) || ["normal", "popup"]).includes(w.type || "normal")) throw new Error("No window with id: " + id);
        return w;
      },
      opened: (w) => open.set(w.id, w),
      getLastFocused: async () => windows[0],
      update: async (id, o) => { calls.push(["windows.update", id, o]); },
      create: async (o) => { calls.push(["windows.create", o]); return { id: 5, tabs: [{ id: 55, windowId: 5, index: 0 }] }; },
    },
    runtime: {
      getManifest: () => ({ version: "0.3.0" }),
      reload: () => { calls.push(["runtime.reload"]); },
    },
  };
  return c;
}

function setup() {
  const chrome = fakeChrome();
  const out = [];
  const b = createBridge(chrome, (m) => out.push(m), () => 1234);
  b.attach();
  return { chrome, out, b };
}

test("every tab and window event is pushed the moment it fires, in sequence", () => {
  const { chrome, out } = setup();
  chrome.tabs.onCreated.fire({ id: 11, windowId: 1, index: 1, title: "", pendingUrl: "https://b.test/" });
  chrome.tabs.onMoved.fire(11, { windowId: 1, fromIndex: 1, toIndex: 0 });
  chrome.tabs.onActivated.fire({ tabId: 11, windowId: 1 });
  chrome.tabs.onRemoved.fire(11, { windowId: 1, isWindowClosing: false });
  chrome.windows.onFocusChanged.fire(-1);
  assert.deepEqual(out.map((m) => m.kind), ["tabCreated", "tabMoved", "tabActivated", "tabRemoved", "windowFocused"]);
  assert.deepEqual(out.map((m) => m.seq), [1, 2, 3, 4, 5]);
  assert.equal(out[0].tab.url, "https://b.test/", "pendingUrl is used before the page commits");
  assert.equal(out[0].t, 1234);
  assert.deepEqual(out[1], { type: "event", kind: "tabMoved", seq: 2, t: 1234, tabId: 11, windowId: 1, fromIndex: 1, toIndex: 0 });
});

test("an update that changes nothing the app sees is not sent", async () => {
  const { chrome, out, b } = setup();
  const tab = { id: 10, windowId: 1, index: 0, title: "A", url: "https://a.test/" };
  chrome.tabs.onUpdated.fire(10, { title: "A" }, tab);
  chrome.tabs.onUpdated.fire(10, { frozen: true }, tab);
  chrome.tabs.onUpdated.fire(10, { title: "A" }, tab);
  const updates = () => out.filter((m) => m.kind === "tabUpdated");
  assert.equal(updates().length, 1);
  chrome.tabs.onUpdated.fire(10, { title: "B" }, { ...tab, title: "B" });
  assert.deepEqual(updates().map((m) => m.seq), [1, 2], "no gap in the sequence");
  // A reconnecting app starts from a snapshot: everything may be said again.
  await b.snapshot();
  chrome.tabs.onUpdated.fire(10, { title: "B" }, { ...tab, title: "B" });
  assert.equal(updates().length, 3);
});

test("attach/detach moves tabs between windows with positions", () => {
  const { chrome, out } = setup();
  chrome.tabs.onDetached.fire(10, { oldWindowId: 1, oldPosition: 0 });
  chrome.tabs.onAttached.fire(10, { newWindowId: 2, newPosition: 3 });
  assert.equal(out[0].windowId, 1);
  assert.equal(out[1].windowId, 2);
  assert.equal(out[1].toIndex, 3);
});

test("snapshot carries every window and tab", async () => {
  const { out, b } = setup();
  await b.snapshot();
  assert.equal(out[0].type, "snapshot");
  assert.equal(out[0].windows[0].tabs[0].url, "https://a.test/");
});

test("open command creates a tab in the focused window and acks", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "c1", op: "open", url: "https://new.test/" });
  assert.deepEqual(chrome.calls[0], ["tabs.create", { url: "https://new.test/", windowId: 1, active: true }]);
  // The ack names the tab it made, so the app can tie it to what asked for it.
  assert.deepEqual(out.at(-1), { type: "ack", id: "c1", ok: true, t: 1234, tabId: 99 });
});

test("open with no browser window makes one and still names the tab", async () => {
  const { chrome, out, b } = setup();
  chrome.windows.getLastFocused = async () => { throw new Error("no window"); };
  await b.handle({ type: "cmd", id: "c1b", op: "open", url: "https://new.test/" });
  assert.deepEqual(chrome.calls[0], ["windows.create", { url: "https://new.test/", focused: true }]);
  assert.equal(out.at(-1).tabId, 55);
});

test("open refuses javascript: and data: URLs", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "c2", op: "open", url: "javascript:alert(1)" });
  assert.equal(chrome.calls.length, 0);
  assert.equal(out.at(-1).ok, false);
});

test("close and activate drive the real tab API", async () => {
  const { chrome, b } = setup();
  await b.handle({ type: "cmd", id: "c3", op: "close", tabId: 10 });
  await b.handle({ type: "cmd", id: "c4", op: "activate", tabId: 10 });
  assert.deepEqual(chrome.calls.map((c) => c[0]), ["tabs.remove", "tabs.update", "windows.update"]);
});

test("unknown ops ack with an error instead of throwing", async () => {
  const { out, b } = setup();
  await b.handle({ type: "cmd", id: "c5", op: "nuke" });
  assert.match(out.at(-1).error, /unknown op/);
});

test("detach removes every listener", () => {
  const { chrome, b } = setup();
  b.detach();
  assert.equal(chrome.tabs.onCreated.size(), 0);
  assert.equal(chrome.windows.onFocusChanged.size(), 0);
});

test("a loaded page's cached icon follows as its own event, once per page", async () => {
  const chrome = fakeChrome();
  const out = [];
  const asked = [];
  const b = createBridge(chrome, (m) => out.push(m), () => 1, async (page) => { asked.push(page); return "data:image/png;base64,AAAA"; });
  b.attach();
  const tab = { id: 10, windowId: 1, index: 0, url: "https://a.test/", status: "complete" };
  chrome.tabs.onUpdated.fire(10, { status: "complete" }, tab);
  chrome.tabs.onUpdated.fire(10, { title: "A" }, tab); // no icon change: no second lookup
  chrome.tabs.onUpdated.fire(10, { favIconUrl: "https://a.test/i.png" }, tab); // same page: already sent
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(asked, ["https://a.test/"]);
  const icon = out.find((m) => m.kind === "tabFavicon");
  assert.deepEqual([icon.tabId, icon.favicon], [10, "data:image/png;base64,AAAA"]);
});

test("pages without a web URL never ask for an icon", async () => {
  const chrome = fakeChrome();
  const asked = [];
  const b = createBridge(chrome, () => {}, () => 1, async (p) => { asked.push(p); return "x"; });
  b.attach();
  chrome.tabs.onUpdated.fire(5, { status: "complete" }, { id: 5, windowId: 1, url: "chrome://settings/" });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(asked, []);
});

test("window frames ride along in the snapshot and on every move, for profile matching", async () => {
  const chrome = fakeChrome();
  chrome.windows.onBoundsChanged = ev();
  const all = await chrome.windows.getAll();
  Object.assign(all[0], { left: 0, top: 31, width: 748, height: 1259 });
  const out = [];
  const b = createBridge(chrome, (m) => out.push(m), () => 1234);
  b.attach();
  await b.snapshot();
  const snap = out.find((m) => m.type === "snapshot");
  assert.deepEqual([snap.windows[0].left, snap.windows[0].top, snap.windows[0].width, snap.windows[0].height], [0, 31, 748, 1259]);
  chrome.windows.onBoundsChanged.fire({ id: 1, left: 1028, top: 31, width: 748, height: 1259 });
  const moved = out.find((m) => m.kind === "windowBounds");
  assert.equal(moved.windowId, 1);
  assert.equal(moved.left, 1028);
});

test("each window's type rides along in the snapshot and when a window opens", async () => {
  const chrome = fakeChrome();
  const all = await chrome.windows.getAll();
  all[0].type = "normal";
  all.push({ id: 2, type: "popup", focused: false, incognito: false, tabs: [] });
  const out = [];
  const b = createBridge(chrome, (m) => out.push(m), () => 1234);
  b.attach();
  await b.snapshot();
  assert.deepEqual(out[0].windows.map((w) => w.windowType), ["normal", "popup"]);
  chrome.windows.onCreated.fire({ id: 3, type: "popup", focused: true, incognito: false });
  const opened = out.find((m) => m.kind === "windowCreated");
  // The message's own `type` is taken: the window's goes as `windowType`.
  assert.equal(opened.type, "event");
  assert.equal(opened.windowType, "popup");
});

test("an app window's opening, focus and closing reach the app, as the snapshot's windows do", async () => {
  const { chrome, out, b } = setup();
  await b.snapshot();
  out.length = 0;
  // Chrome sends these only to a listener whose filter names "app".
  chrome.windows.onCreated.fire({ id: 3, type: "app", focused: true, incognito: false });
  chrome.windows.onFocusChanged.fire(3);
  chrome.windows.onRemoved.fire(3);
  assert.deepEqual(out.map((m) => [m.kind, m.windowId]), [["windowCreated", 3], ["windowFocused", 3], ["windowRemoved", 3]]);
  assert.equal(out[0].windowType, "app");
});

test("a tab of a window the app was never sent brings the window's type right behind it", async () => {
  const { chrome, out, b } = setup();
  // Before the first snapshot nothing is asked: the snapshot will say.
  chrome.tabs.onCreated.fire({ id: 70, windowId: 7, index: 0 });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(chrome.calls, []);
  await b.snapshot();
  out.length = 0;
  // A window whose own event never came (a DevTools window has none).
  chrome.windows.opened({ id: 7, type: "devtools", focused: false, incognito: false, left: 5, top: 6, width: 700, height: 500 });
  chrome.tabs.onCreated.fire({ id: 71, windowId: 7, index: 1 });
  chrome.tabs.onAttached.fire(72, { newWindowId: 7, newPosition: 2 });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(out.map((m) => m.kind), ["tabCreated", "tabAttached", "windowCreated"], "the tab goes at once, the window once");
  assert.deepEqual([out[2].windowId, out[2].windowType, out[2].left], [7, "devtools", 5]);
  assert.deepEqual(out.map((m) => m.seq), [3, 4, 5], "no gap in the sequence");
  // A window the snapshot or its own event named is not asked about.
  chrome.tabs.onCreated.fire({ id: 11, windowId: 1, index: 1 });
  chrome.windows.onCreated.fire({ id: 8, type: "popup", focused: true, incognito: false });
  chrome.tabs.onCreated.fire({ id: 80, windowId: 8, index: 0 });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(chrome.calls.filter((c) => c[0] === "windows.get").map((c) => c[1]), [7]);
  // A window that is gone by the time the tab says so: nothing is sent for it.
  chrome.tabs.onCreated.fire({ id: 90, windowId: 9, index: 0 });
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(out.filter((m) => m.kind === "windowCreated" && m.windowId === 9).length, 0);
});

test("a window sent because a tab named it is reported gone too, whatever its type", async () => {
  const { chrome, out, b } = setup();
  await b.snapshot();
  chrome.windows.opened({ id: 7, type: "devtools", focused: false, incognito: false, left: 5, top: 6, width: 700, height: 500 });
  chrome.tabs.onCreated.fire({ id: 71, windowId: 7, index: 0 });
  await new Promise((r) => setTimeout(r, 0));
  out.length = 0;
  chrome.windows.onRemoved.fire(7);
  assert.deepEqual(out.map((m) => [m.kind, m.windowId]), [["windowRemoved", 7]]);
});

test("move, mute, duplicate, reload and newWindow drive the real tab API", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "m1", op: "move", tabId: 10, index: 3 });
  await b.handle({ type: "cmd", id: "m2", op: "move", tabId: 10, index: 0, windowId: 2 });
  await b.handle({ type: "cmd", id: "m3", op: "mute", tabId: 10, muted: true });
  await b.handle({ type: "cmd", id: "m4", op: "mute", tabId: 10, muted: false });
  await b.handle({ type: "cmd", id: "m5", op: "duplicate", tabId: 10 });
  await b.handle({ type: "cmd", id: "m6", op: "reload", tabId: 10 });
  await b.handle({ type: "cmd", id: "m7", op: "newWindow", tabId: 10 });
  assert.deepEqual(chrome.calls, [
    ["tabs.move", 10, { index: 3 }],
    ["tabs.move", 10, { index: 0, windowId: 2 }],
    ["tabs.update", 10, { muted: true }],
    ["tabs.update", 10, { muted: false }],
    ["tabs.duplicate", 10],
    ["tabs.reload", 10],
    ["windows.create", { tabId: 10, focused: true }],
  ]);
  assert.ok(out.every((m) => m.type === "ack" && m.ok), "every command acks ok");
  assert.equal(out[4].tabId, 77, "duplicate names the copy");
});

test("closeMany closes the listed tabs in one call, and nothing for an empty list", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "x1", op: "closeMany", tabIds: [10, 11, "12", null] });
  await b.handle({ type: "cmd", id: "x2", op: "closeMany", tabIds: [] });
  assert.deepEqual(chrome.calls, [["tabs.remove", [10, 11]]]);
  assert.equal(out.at(-1).ok, true);
});

test("navigate sends a tab to a web address and shows it, and refuses javascript:", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "n1", op: "navigate", tabId: 10, url: "https://home.test/" });
  assert.deepEqual(chrome.calls, [
    ["tabs.update", 10, { url: "https://home.test/", active: true }],
    ["windows.update", 1, { focused: true }],
  ]);
  await b.handle({ type: "cmd", id: "n2", op: "navigate", tabId: 10, url: "javascript:alert(1)" });
  assert.equal(chrome.calls.length, 2);
  assert.match(out.at(-1).error, /refused url/);
  await b.handle({ type: "cmd", id: "n3", op: "navigate", tabId: 10, url: "https://quiet.test/", focus: false });
  assert.deepEqual(chrome.calls.at(-1), ["tabs.update", 10, { url: "https://quiet.test/" }]);
});

test("a tab command without a tab id acks an error and calls nothing", async () => {
  const { chrome, out, b } = setup();
  for (const op of ["close", "activate", "move", "mute", "duplicate", "reload", "navigate", "newWindow"]) {
    await b.handle({ type: "cmd", id: op, op, index: 0, url: "https://a.test/" });
    assert.equal(out.at(-1).ok, false, op);
  }
  assert.equal(chrome.calls.length, 0);
});

test("move without an index is refused", async () => {
  const { chrome, out, b } = setup();
  await b.handle({ type: "cmd", id: "mv", op: "move", tabId: 10 });
  assert.match(out.at(-1).error, /no index/);
  assert.equal(chrome.calls.length, 0);
});

test("a tab says whether it is muted", () => {
  assert.equal(serializeTab({ id: 1, windowId: 1, index: 0, mutedInfo: { muted: true } }).muted, true);
  assert.equal(serializeTab({ id: 1, windowId: 1, index: 0 }).muted, false);
});

test("the hello's op list is exactly what run() handles", async () => {
  const { out, b } = setup();
  for (const op of OPS) {
    await b.handle({ type: "cmd", id: op, op, tabId: 10, index: 0, url: "https://a.test/", tabIds: [10] });
    assert.ok(!/unknown op/.test(out.at(-1).error || ""), op + " is handled");
  }
});

// reloadSelf: the app has put newer files where this copy was loaded from.
function reloadSetup(diskVersion) {
  const chrome = fakeChrome();
  const out = [];
  const b = createBridge(chrome, (m) => out.push(m), () => 1234, async () => "", diskVersion);
  return { chrome, out, b };
}

test("reloadSelf reloads into the files on disk when they are another version, after acking", async () => {
  const { chrome, out, b } = reloadSetup(async () => "0.3.1");
  let ackedFirst = false;
  chrome.runtime.reload = () => { ackedFirst = out.some((m) => m.type === "ack" && m.id === "r1" && m.ok); chrome.calls.push(["runtime.reload"]); };
  await b.handle({ type: "cmd", id: "r1", op: "reloadSelf" });
  assert.deepEqual(chrome.calls, [["runtime.reload"]]);
  assert.ok(ackedFirst, "the ack goes out before the extension restarts");
});

test("reloadSelf does nothing when the files on disk are the version already running", async () => {
  // A copy loaded from somewhere the app doesn't manage, or the store's copy.
  const { chrome, out, b } = reloadSetup(async () => "0.3.0");
  await b.handle({ type: "cmd", id: "r2", op: "reloadSelf" });
  assert.deepEqual(chrome.calls, []);
  assert.equal(out.at(-1).ok, false);
  assert.match(out.at(-1).error, /nothing newer on disk/);
});

test("reloadSelf does nothing when the files on disk can't be read", async () => {
  for (const diskVersion of [async () => { throw new Error("gone"); }, async () => "", async () => null, undefined]) {
    const { chrome, out, b } = reloadSetup(diskVersion);
    await b.handle({ type: "cmd", id: "r3", op: "reloadSelf" });
    assert.deepEqual(chrome.calls, []);
    assert.equal(out.at(-1).ok, false);
  }
});
