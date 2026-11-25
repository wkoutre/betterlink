// The store package: what scripts/package-extension.sh puts in the zip.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const source = JSON.parse(readFileSync(join(root, "browser-extension/manifest.json"), "utf8"));

function pack() {
  const out = mkdtempSync(join(tmpdir(), "bl-ext-"));
  const zip = execFileSync(join(root, "scripts/package-extension.sh"), [out], { encoding: "utf8" }).trim();
  const names = execFileSync("unzip", ["-Z1", zip], { encoding: "utf8" }).trim().split("\n").sort();
  const manifest = JSON.parse(execFileSync("unzip", ["-p", zip, "manifest.json"], { encoding: "utf8" }));
  return { out, zip, names, manifest };
}

test("the store package leaves out the key, the tests and package.json", () => {
  const { out, zip, names, manifest } = pack();
  try {
    assert.equal(zip, join(out, `betterlink-tabs-${source.version}.zip`));
    assert.equal(manifest.key, undefined, "the store refuses an upload with a key");
    assert.ok(source.key, "the source manifest keeps the key, which pins the unpacked id");
    assert.deepEqual({ ...manifest, key: source.key }, source, "nothing else differs");
    assert.deepEqual(
      names.filter((n) => !n.endsWith("/")),
      ["background.js", "bridge.js", "icons/128.png", "icons/16.png", "icons/32.png", "icons/48.png", "manifest.json"],
    );
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test("the name and summary fit the store's limits", () => {
  assert.ok(source.name.length <= 75, "name: 75 characters at most");
  assert.ok(source.description.length <= 132, "description: 132 characters at most");
});

test("every icon the manifest names is a PNG of that size", () => {
  for (const [size, path] of Object.entries(source.icons)) {
    const png = readFileSync(join(root, "browser-extension", path));
    assert.equal(png.subarray(1, 4).toString("latin1"), "PNG");
    assert.equal(png.readUInt32BE(16), Number(size), `${path} width`);
    assert.equal(png.readUInt32BE(20), Number(size), `${path} height`);
  }
});
