// Node tests for bridge.js against a fake chrome API. Run: node --test extension/tests
import { test } from "node:test";
import assert from "node:assert/strict";
import { createBridge } from "../bridge.js";

function ev() {
  const fns = new Set();
  return { addListener: (f) => fns.add(f), removeListener: (f) => fns.delete(f), fire: (...a) => [...fns].map((f) => f(...a)), size: () => fns.size };
}

function fakeChrome() {
  const windows = [{ id: 1, focused: true, incognito: false, tabs: [{ id: 10, windowId: 1, index: 0, title: "A", url: "https://a.test/", active: true }] }];
  const calls = [];
  const c = {
    calls,
    tabs: {
      onCreated: ev(), onUpdated: ev(), onRemoved: ev(), onMoved: ev(), onActivated: ev(),
      onDetached: ev(), onAttached: ev(), onReplaced: ev(),
      create: async (o) => { calls.push(["tabs.create", o]); return { id: 99, windowId: o.windowId, index: 1 }; },
      remove: async (id) => { calls.push(["tabs.remove", id]); },
      update: async (id, o) => { calls.push(["tabs.update", id, o]); return { id, windowId: 1 }; },
      get: async (id) => ({ id, windowId: 1, index: 0, title: "R", url: "https://r.test/" }),
    },
    windows: {
      onCreated: ev(), onRemoved: ev(), onFocusChanged: ev(),
      getAll: async () => windows,
      getLastFocused: async () => windows[0],
      update: async (id, o) => { calls.push(["windows.update", id, o]); },
      create: async (o) => { calls.push(["windows.create", o]); },
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
  assert.deepEqual(out.at(-1), { type: "ack", id: "c1", ok: true, t: 1234 });
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
