// When the extension tries the betterlink host again. Run: node --test browser-extension/tests
import { test } from "node:test";
import assert from "node:assert/strict";
import { createReconnector } from "../reconnect.js";

function clock() {
  let t = 0;
  let next = 1;
  const timers = new Map();
  return {
    now: () => t,
    setTimer: (fn, ms) => { const id = next++; timers.set(id, { fn, at: t + ms }); return id; },
    clearTimer: (id) => timers.delete(id),
    advance(ms) {
      t += ms;
      for (const [id, x] of [...timers]) if (x.at <= t) { timers.delete(id); x.fn(); }
    },
    pending: () => [...timers.values()].map((x) => x.at - t),
  };
}

test("a failed try waits 1 s, doubling to 60 s, and an answer resets that", () => {
  const c = clock();
  let tries = 0;
  const r = createReconnector(() => tries++, c);
  const waits = [];
  for (let i = 0; i < 8; i++) { r.failed(); waits.push(c.pending()[0]); c.advance(waits.at(-1)); }
  assert.deepEqual(waits, [1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000]);
  assert.equal(tries, 8);
  r.succeeded();
  r.failed();
  assert.deepEqual(c.pending(), [1000]);
});

test("a browser event while no host is there tries at once, instead of waiting out the backoff", () => {
  const c = clock();
  let tries = 0;
  const r = createReconnector(() => tries++, c);
  for (let i = 0; i < 7; i++) { r.failed(); c.advance(c.pending()[0]); }
  r.failed(); // now waiting 60 s
  tries = 0;
  c.advance(5000);
  assert.equal(r.nudge(), true);
  assert.equal(tries, 1);
  assert.deepEqual(c.pending(), [], "the slow timer is replaced by the try");
});

test("events don't try more than once every 3 s, and never while connected", () => {
  const c = clock();
  let tries = 0;
  const r = createReconnector(() => tries++, c);
  r.failed();
  c.advance(1000); // the timer's try
  assert.equal(tries, 1);
  c.advance(1000);
  assert.equal(r.nudge(), false, "1 s after a try");
  c.advance(2000);
  assert.equal(r.nudge(), true);
  assert.equal(r.nudge(), false);
  assert.equal(tries, 2);
  r.succeeded();
  c.advance(10000);
  assert.equal(r.nudge(), false, "connected: nothing to do");
  assert.equal(tries, 2);
});
