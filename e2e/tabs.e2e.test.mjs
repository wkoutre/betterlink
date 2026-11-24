// End-to-end over the real pipe, minus a real browser:
//   fake browser (real extension/bridge.js over a simulated chrome.tabs)
//     <-- native messaging stdio -->  real betterlink-tabhost binary
//     <-- Unix socket -->             real betterlink-tabs (the app's SyncHub)
//
// Build first: swift build. Run: node --test e2e/
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, existsSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createBridge } from "../browser-extension/bridge.js";

const BIN = process.env.BETTERLINK_TABS_BIN || join(process.cwd(), ".build/debug");

// A tiny in-memory browser: mutations fire the same events Chrome fires.
function fakeBrowser() {
  const ev = () => { const f = new Set(); return { addListener: (x) => f.add(x), removeListener: (x) => f.delete(x), fire: (...a) => f.forEach((x) => x(...a)) }; };
  let nextId = 100;
  const wins = [{ id: 1, focused: true, tabs: [{ id: 1, windowId: 1, index: 0, url: "https://start.test/", title: "Start", active: true }] }];
  const reindex = (w) => w.tabs.forEach((t, i) => { t.index = i; });
  const find = (id) => { for (const w of wins) { const i = w.tabs.findIndex((t) => t.id === id); if (i >= 0) return [w, i]; } return [null, -1]; };
  const chrome = {
    tabs: {
      onCreated: ev(), onUpdated: ev(), onRemoved: ev(), onMoved: ev(), onActivated: ev(), onDetached: ev(), onAttached: ev(), onReplaced: ev(),
      async create({ url, windowId, active }) {
        const w = wins.find((x) => x.id === windowId);
        const tab = { id: nextId++, windowId, index: w.tabs.length, url, title: "", active: !!active };
        if (active) w.tabs.forEach((t) => { t.active = false; });
        w.tabs.push(tab);
        chrome.tabs.onCreated.fire({ ...tab });
        if (active) chrome.tabs.onActivated.fire({ tabId: tab.id, windowId });
        return tab;
      },
      async remove(id) {
        const [w, i] = find(id);
        if (!w) throw new Error("No tab with id: " + id);
        w.tabs.splice(i, 1); reindex(w);
        chrome.tabs.onRemoved.fire(id, { windowId: w.id, isWindowClosing: false });
      },
      async update(id, { active }) {
        const [w, i] = find(id);
        if (active) { w.tabs.forEach((t) => { t.active = false; }); w.tabs[i].active = true; chrome.tabs.onActivated.fire({ tabId: id, windowId: w.id }); }
        return w.tabs[i];
      },
      async get(id) { const [w, i] = find(id); return w.tabs[i]; },
      move(id, toIndex) {
        const [w, i] = find(id);
        const [t] = w.tabs.splice(i, 1); w.tabs.splice(toIndex, 0, t); reindex(w);
        chrome.tabs.onMoved.fire(id, { windowId: w.id, fromIndex: i, toIndex });
      },
    },
    windows: {
      onCreated: ev(), onRemoved: ev(), onFocusChanged: ev(),
      async getAll() { return wins.map((w) => ({ ...w, tabs: w.tabs.map((t) => ({ ...t })) })); },
      async getLastFocused() { return wins.find((w) => w.focused) || wins[0]; },
      async update() {},
      async create() {},
    },
  };
  return { chrome, wins };
}

function frame(obj) {
  const body = Buffer.from(JSON.stringify(obj));
  const head = Buffer.alloc(4); head.writeUInt32LE(body.length);
  return Buffer.concat([head, body]);
}

function startHost(dir, browser) {
  const host = spawn(join(BIN, "betterlink-tabhost"), ["chrome-extension://nakiifbonhngpkpekakimjfgkbbbnjoe/"], {
    env: { ...process.env, BETTERLINK_TABS_SOCKET_DIR: dir, BETTERLINK_TABS_BROWSER_NAME: "Fake Chrome" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const bridge = createBridge(browser.chrome, (m) => host.stdin.write(frame(m)));
  bridge.attach();
  let buf = Buffer.alloc(0);
  host.stdout.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 4 && buf.length >= 4 + buf.readUInt32LE(0)) {
      const len = buf.readUInt32LE(0);
      const msg = JSON.parse(buf.subarray(4, 4 + len).toString());
      buf = buf.subarray(4 + len);
      bridge.handle(msg);
    }
  });
  return { host, bridge };
}

function startApp(dir) {
  const app = spawn(join(BIN, "betterlink-tabs"), ["--json"], { env: { ...process.env, BETTERLINK_TABS_SOCKET_DIR: dir }, stdio: ["pipe", "pipe", "inherit"] });
  const states = [];
  const waiters = [];
  let rest = "";
  app.stdout.on("data", (c) => {
    rest += c;
    let i;
    while ((i = rest.indexOf("\n")) >= 0) {
      const s = JSON.parse(rest.slice(0, i)); rest = rest.slice(i + 1);
      states.push(s);
      for (const w of [...waiters]) if (w.pred(s)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(s); }
    }
  });
  const until = (pred, label, ms = 3000) => new Promise((resolve, reject) => {
    const hit = states.findLast((s) => pred(s));
    if (hit && pred(states.at(-1))) return resolve(states.at(-1));
    const w = { pred, resolve };
    waiters.push(w);
    setTimeout(() => reject(new Error("timed out waiting for: " + label + "\nlast state: " + JSON.stringify(states.at(-1)))), ms).unref();
  });
  return { app, until, cmd: (line) => app.stdin.write(line + "\n") };
}

const urls = (s) => (s.sessions[0]?.windows[0]?.tabs || []).map((t) => t.url);

test("browser <-> app tab sync over the real host, both directions, no polling", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "bl-tabs-"));
  const browser = fakeBrowser();

  // App first, browser second: the app must discover the host's socket by directory event.
  const { app, until, cmd } = startApp(dir);
  t.after(() => app.kill());
  await new Promise((r) => setTimeout(r, 200));
  const { host } = startHost(dir, browser);
  t.after(() => host.kill());

  let s = await until((s) => urls(s).includes("https://start.test/"), "initial snapshot");
  assert.equal(s.sessions[0].browser, "Fake Chrome");

  // Browser -> app
  const t0 = performance.now();
  await browser.chrome.tabs.create({ url: "https://opened-in-browser.test/", windowId: 1, active: true });
  s = await until((s) => urls(s).includes("https://opened-in-browser.test/"), "browser-created tab");
  const browserToApp = performance.now() - t0;
  const created = s.sessions[0].windows[0].tabs.find((x) => x.url === "https://opened-in-browser.test/");

  browser.chrome.tabs.move(created.id, 0);
  s = await until((s) => urls(s)[0] === "https://opened-in-browser.test/", "move to front");

  await browser.chrome.tabs.remove(created.id);
  s = await until((s) => !urls(s).includes("https://opened-in-browser.test/"), "browser-closed tab");

  // App -> browser
  const t1 = performance.now();
  cmd("open https://opened-in-app.test/");
  s = await until((s) => urls(s).includes("https://opened-in-app.test/"), "app-opened tab");
  const appToBrowserAndBack = performance.now() - t1;
  assert.ok(browser.wins[0].tabs.some((x) => x.url === "https://opened-in-app.test/"), "the browser really has the tab");
  const appTab = s.sessions[0].windows[0].tabs.find((x) => x.url === "https://opened-in-app.test/");
  assert.equal(appTab.active, true);

  cmd("activate 1");
  s = await until((s) => s.sessions[0].windows[0].tabs.find((x) => x.id === 1)?.active, "app-activated tab");

  cmd("close " + appTab.id);
  s = await until((s) => !urls(s).includes("https://opened-in-app.test/"), "app-closed tab");
  assert.ok(!browser.wins[0].tabs.some((x) => x.url === "https://opened-in-app.test/"), "the browser really closed it");

  console.log(`browser->app: ${browserToApp.toFixed(1)} ms; app->browser->app: ${appToBrowserAndBack.toFixed(1)} ms; host-measured event latency: ${s.eventLatencyMs?.toFixed(2)} ms`);
  assert.ok(browserToApp < 250, "browser -> app well under a frame budget on a loaded CI box");

  // Browser quits: host sees EOF, removes its socket, app drops the session.
  host.stdin.end();
  await until((s) => s.sessions.length === 0, "session gone after browser quit");
  assert.deepEqual(readdirSync(dir).filter((f) => f.endsWith(".sock")), []);
});

test("a stale socket from a crashed host is cleaned up, and a late app still gets a snapshot", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "bl-tabs-"));
  const browser = fakeBrowser();
  const { host } = startHost(dir, browser);
  t.after(() => host.kill());
  await new Promise((r) => setTimeout(r, 300));
  // A crashed host leaves its socket file behind with nobody listening.
  const stale = join(dir, "dead-1.sock");
  const { execFileSync } = await import("node:child_process");
  execFileSync("python3", ["-c", "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])", stale]);
  assert.ok(existsSync(stale));

  const { app, until } = startApp(dir);
  t.after(() => app.kill());
  const s = await until((s) => s.sessions.length === 1 && urls(s).includes("https://start.test/"), "late app gets snapshot");
  assert.equal(s.sessions.length, 1);
  assert.equal(existsSync(stale), false, "the app removed the dead socket");
});
