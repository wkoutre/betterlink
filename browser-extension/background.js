// MV3 service worker. Holds one native messaging port to the betterlink-tabhost.
// An open native port keeps the service worker alive (Chrome 105+), so events
// stream for as long as the browser runs. Nothing here polls: the only timer is
// the reconnect backoff after the host goes away, and a browser event while
// no host is connected tries again at once (reconnect.js).
import { createBridge, OPS, PROTOCOL } from "./bridge.js";
import { createReconnector } from "./reconnect.js";

const HOST = "com.wkoutre.betterlink.tabs";
let port = null;
const reconnect = createReconnector(connect);

function send(msg) {
  // No host yet: the snapshot on (re)connect heals the gap, and this event
  // is the moment to try for one.
  if (!port) { reconnect.nudge(); return; }
  try { port.postMessage(msg); } catch { port = null; reconnect.failed(); }
}

// The browser's own cached icon for a page, as a data: URL. Served by the
// browser from its local favicon store ("favicon" permission); no network.
async function favicon(pageUrl) {
  const u = new URL(chrome.runtime.getURL("/_favicon/"));
  u.searchParams.set("pageUrl", pageUrl);
  u.searchParams.set("size", "32");
  const buf = new Uint8Array(await (await fetch(u)).arrayBuffer());
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return "data:image/png;base64," + btoa(bin);
}

// The version in the manifest.json on disk, read fresh. The browser reads an
// unpacked copy's files from its folder each time, so this is what a reload
// would start.
async function diskVersion() {
  const r = await fetch(chrome.runtime.getURL("manifest.json"), { cache: "no-store" });
  return (await r.json()).version;
}

const bridge = createBridge(chrome, send, () => Date.now(), favicon, diskVersion);
// Listeners must be registered synchronously at top level so they also wake the worker.
bridge.attach();

// A random id kept in this profile's extension storage. betterlink finds it in
// the profile's folder on disk to learn which browser profile this copy runs in.
async function instanceId() {
  try {
    const got = await chrome.storage.local.get("betterlinkInstance");
    if (got.betterlinkInstance) return got.betterlinkInstance;
    const id = "betterlink-instance-" + crypto.randomUUID();
    await chrome.storage.local.set({ betterlinkInstance: id });
    return id;
  } catch {
    return "";
  }
}
const instance = instanceId();

function connect() {
  if (port) return;
  let p;
  try {
    p = chrome.runtime.connectNative(HOST);
  } catch (e) {
    return reconnect.failed();
  }
  port = p;
  p.onMessage.addListener((msg) => {
    reconnect.succeeded(); // the host is really there (it greets on start), so reset the backoff
    bridge.handle(msg);
  });
  p.onDisconnect.addListener(() => {
    if (chrome.runtime.lastError) console.warn("[betterlink-tabs] host:", chrome.runtime.lastError.message);
    if (port !== p) return;
    port = null;
    reconnect.failed();
  });
  instance.then((id) => {
    if (port !== p) return;
    send({
      type: "hello",
      protocol: PROTOCOL,
      extension: chrome.runtime.getManifest().version,
      ops: OPS,
      userAgent: navigator.userAgent,
      brands: (navigator.userAgentData && navigator.userAgentData.brands || []).map((b) => b.brand),
      instance: id,
    });
    bridge.snapshot();
  });
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
