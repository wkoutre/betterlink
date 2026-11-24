# betterlink Tabs: privacy

betterlink Tabs is the browser extension that connects a Chromium browser to the betterlink app on the same Mac. This page says what it reads and where that goes.

## What it reads

- For each open tab and window in the browser profile it is installed in: the tab's title, address, position, whether it is pinned, muted, playing sound or active, and the window's position on screen.
- Each page's icon, from the browser's own icon cache.
- A random id it makes once and keeps in its own extension storage, so betterlink can tell which browser profile it is talking to.

It does not read what is on a page, what you type, your passwords, your bookmarks or your browsing history. Tabs in private windows are seen only if you turn on Allow in Incognito for the extension, and betterlink never remembers them.

## Where it goes

Only to the betterlink app on the same Mac, over the browser's native messaging channel, which starts a helper inside the betterlink app and talks to it through a local pipe. Nothing is sent over the network, by the extension or by the app, and there are no servers, accounts, analytics or ads.

Without the betterlink app the extension sends nothing to anyone: it has nowhere to send it.

## What betterlink keeps

betterlink shows your tabs in its sidebar and keeps the links you choose to save, in its settings folder on your Mac. It keeps where your saved links' tabs were, so they return after the browser restarts. It keeps no history of the pages you visit.

## What it does to your tabs

Only what you ask for in betterlink: open, close, switch to, move, mute, duplicate or reload a tab, or move one to a new window.

## Sharing and selling

None. The data never leaves your Mac, so there is nothing to share or sell.

## Questions

Open an issue at https://github.com/wkoutre/betterlink/issues, or see [SECURITY.md](../SECURITY.md) to report a security problem privately.
