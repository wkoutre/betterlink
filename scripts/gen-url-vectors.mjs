// Regenerates Tests/BetterlinkCoreTests/Fixtures/url-vectors.json.
// Node's URL class implements the WHATWG URL standard, which is how Brave and
// every other Chromium browser parse links. The Swift tests assert that
// betterlink extracts the same host as this oracle, or refuses to route the
// link to anything but the fallback profile.
import { writeFileSync } from "node:fs";

const inputs = [
  "https://acme.com/",
  "https://app.acme.com/swap?chain=base#x",
  "HTTPS://APP.ACME.COM/Swap",
  "https://evil.com\\@acme.com/",
  "https://evil.com\\@app.acme.com/x",
  "https:\\\\evil.com\\acme.com",
  "https:evil.com/acme.com",
  "https:/evil.com",
  "https:///evil.com",
  "https://acme.com@evil.com/",
  "https://user:p@ss@evil.com/",
  "https://acme.com:pw@evil.com/",
  "https://evil.com#@acme.com",
  "https://evil.com?x=@acme.com",
  "https://evil.com/@acme.com",
  "https://ev\til.com/",
  "https://ac\nme.com/",
  "  https://acme.com/  ",
  "\u0001https://acme.com/",
  "https://acme%2ecom/",
  "https://app%2Eacme.com/",
  "https://acme.com./",
  "https://ACME.com:443/",
  "https://acme.com:8443/x",
  "http://0x7f.1/",
  "http://127.0.0.1/",
  "http://[::1]:8080/",
  "https://acmе.org/",
  "https://xn--acm-4ve.com/",
  "https://evil-acme.com/",
  "https://acme.com.evil.com/",
  "https://app.acme.com.evil.com/swap",
  "https://evil.com/?q=acme.com",
  "https://ex ample.com/",
  "https://exa%20mple.com/",
  "https://evil.com%2f@acme.com/",
  "https://evil.com%5c@acme.com/",
  "https://acme.com\\path\\to?q=\\x#\\y",
  "http://localhost:3000/",
  "https://a.b.c.acme.com/",
  "https://",
  "https:",
  "notaurl",
  "ftp://acme.com/",
  "javascript:alert(1)",
  "file:///Users/me/page.html",
  "https://xn--/",
  "https://%E2%80%8Bacme.com/",
  "https://acme.com%00.evil.com/",
  "https://[acme.com]/",
];

const vectors = inputs.map((input) => {
  try {
    const u = new URL(input);
    return { input, ok: true, protocol: u.protocol, host: u.hostname, port: u.port, href: u.href };
  } catch {
    return { input, ok: false };
  }
});
writeFileSync(new URL("../Tests/BetterlinkCoreTests/Fixtures/url-vectors.json", import.meta.url),
  JSON.stringify({ generator: `node ${process.version}`, vectors }, null, 1) + "\n");
console.log(`${vectors.length} vectors`);
