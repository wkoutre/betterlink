// The tab host lives as long as the browser: a busy day of tab events must not
// stay in its memory.  TABHOST=<path> picks another binary.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";

const HOST = process.env.TABHOST ?? ".build/debug/betterlink-tabhost";

function frame(obj) {
  const body = Buffer.from(JSON.stringify(obj));
  const len = Buffer.alloc(4);
  len.writeUInt32LE(body.length);
  return Buffer.concat([len, body]);
}

test("40,000 tab events leave the host's memory where it was", { skip: !existsSync(HOST) }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "blh-"));
  const host = spawn(HOST, ["chrome-extension://test/"], {
    env: { ...process.env, BETTERLINK_TABS_SOCKET_DIR: dir, BETTERLINK_TABS_BROWSER_NAME: "Test" },
    stdio: ["pipe", "ignore", "ignore"],
  });
  const rss = () => Number(execFileSync("ps", ["-o", "rss=", "-p", String(host.pid)]).toString()) / 1024;
  const send = async (from, n) => {
    for (let i = from; i < from + n; i += 100) {
      const batch = [];
      for (let k = i; k < i + 100; k++) {
        batch.push(frame({ type: "event", kind: "tabUpdated", seq: k, t: 1, changes: ["title"],
          tab: { id: 1, windowId: 1, index: 0, title: "tab " + k, url: "https://a.test/", favIconUrl: "", active: true } }));
      }
      if (!host.stdin.write(Buffer.concat(batch))) await once(host.stdin, "drain");
    }
    await new Promise((r) => setTimeout(r, 800));
  };
  try {
    await send(1, 2000);
    const before = rss();
    await send(2001, 40000);
    const grew = rss() - before;
    assert.ok(grew < 5, `grew ${grew.toFixed(1)} MB`);
  } finally {
    host.kill();
    rmSync(dir, { recursive: true, force: true });
  }
});
