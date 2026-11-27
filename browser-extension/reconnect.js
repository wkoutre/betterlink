// When to try the betterlink host again after it went away or was never there.
// Pure: background.js passes the real timers in, tests pass fakes.
//
// A failed try waits 1 s, doubling to 60 s, as before. But a browser event
// while no host is connected (a tab switched, a page loaded) tries again at
// once, at most every `nudgeMs`: someone who just pressed Set Up, or whose
// betterlink just restarted, sees the sidebar fill on their next click
// instead of after up to a minute. Nothing runs while the browser is idle.
export function createReconnector(connect, { setTimer = setTimeout, clearTimer = clearTimeout, now = () => Date.now(), nudgeMs = 3000 } = {}) {
  let retryMs = 1000;
  let timer = null;
  let lastTry = -Infinity;
  let connected = false;

  function attempt() {
    timer = null;
    lastTry = now();
    connect();
  }

  return {
    // The host answered: it is really there.
    succeeded() {
      connected = true;
      retryMs = 1000;
    },
    // The port closed or could not open.
    failed() {
      connected = false;
      if (timer !== null) clearTimer(timer);
      timer = setTimer(attempt, retryMs);
      retryMs = Math.min(retryMs * 2, 60000);
    },
    // Something happened in the browser. Tries now if no host is connected
    // and the last try was long enough ago.
    nudge() {
      if (connected || now() - lastTry < nudgeMs) return false;
      if (timer !== null) clearTimer(timer);
      attempt();
      return true;
    },
    get retryMs() { return retryMs; },
  };
}
