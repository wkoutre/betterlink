// MV3 service worker. Holds one native messaging port to the betterlink-tabhost.
// An open native port keeps the service worker alive (Chrome 105+), so events
// stream for as long as the browser runs. Nothing here polls: the only timer is
// the reconnect backoff after the host goes away.
import { createBridge, PROTOCOL } from "./bridge.js";

const HOST = "com.wkoutre.betterlink.tabs";
let port = null;
let retryMs = 1000;

function send(msg) {
  if (!port) return; // no app yet; the snapshot on (re)connect heals the gap
  try { port.postMessage(msg); } catch { port = null; }
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

const bridge = createBridge(chrome, send, () => Date.now(), favicon);
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
    return scheduleRetry();
  }
  port = p;
  p.onMessage.addListener((msg) => {
    retryMs = 1000; // the host is really there (it greets on start), so reset the backoff
    bridge.handle(msg);
  });
  p.onDisconnect.addListener(() => {
    if (chrome.runtime.lastError) console.warn("[betterlink-tabs] host:", chrome.runtime.lastError.message);
    if (port === p) port = null;
    scheduleRetry();
  });
  instance.then((id) => {
    if (port !== p) return;
    send({
      type: "hello",
      protocol: PROTOCOL,
      extension: chrome.runtime.getManifest().version,
      userAgent: navigator.userAgent,
      brands: (navigator.userAgentData && navigator.userAgentData.brands || []).map((b) => b.brand),
      instance: id,
    });
    bridge.snapshot();
  });
}

function scheduleRetry() {
  setTimeout(connect, retryMs);
  retryMs = Math.min(retryMs * 2, 60000);
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
