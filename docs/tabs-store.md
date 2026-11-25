# betterlink Tabs in the Chrome Web Store

How the Tabs extension gets into the store, and every field to paste. The dashboard only works by hand (Chrome blocks extensions and automation on its pages).

## The id

The item exists in the store as a draft: id `gjjllnebeeegbipppiclhlomdppbnljh`, <https://chromewebstore.google.com/detail/gjjllnebeeegbipppiclhlomdppbnljh> once it is published.

The store gives each item its own id and refuses an upload whose manifest has a `key`. So the item was created first, from a package without one, and its public key (Dashboard › Package › View public key) is now the `key` in `browser-extension/manifest.json`. An unpacked copy and the store copy therefore have the same id, which is `HostRegistration.extensionId`; a test checks the key gives that id.

A copy loaded before that change had another id. Reload it, then press Set Up Again in betterlink: the app shows a registration written for the old id as "Set up for an older betterlink".

## The package

```sh
scripts/package-extension.sh        # writes dist/betterlink-tabs-<version>.zip
```

The zip holds the manifest without its `key`, `background.js`, `bridge.js` and `icons/`. The icons are betterlink's app icon (`swift scripts/make-icon.swift browser-extension/icons/128.png 128`, and 48, 32, 16).

## When to submit

The extension does nothing without a betterlink that has the Sidebar page, and a reviewer has to be able to run it. Save the item as a draft until a betterlink release with the sidebar is out (or about to be), then submit.

## Uploads

| Upload | Where in the dashboard | File |
|---|---|---|
| Package | New item | `dist/betterlink-tabs-<version>.zip` |
| Store icon, 128×128 | Store listing › Graphic assets › Store icon | `browser-extension/icons/128.png` |
| Screenshot, 1280×800 (at least one) | Store listing › Screenshots | not made yet: the sidebar beside a Chrome window |

## Store listing tab

- **Name:** from the manifest: betterlink Tabs (preview)
- **Summary:** from the manifest's description.
- **Description:**

  > betterlink Tabs connects this browser to betterlink, a free and open source Mac app that opens every link in the right browser and profile.
  >
  > With it, betterlink's sidebar shows this window's tabs beside the browser, the way Arc and Dia do, in any Chromium browser: Chrome, Brave, Edge, Vivaldi.
  >
  > WHAT YOU GET
  > • Your tabs in a sidebar that follows the browser window. Click to switch, close, reorder, mute, duplicate or reload.
  > • A grid of Favorites and nested folders of saved links above your tabs. A saved link keeps its tab, like a pinned tab.
  > • One Sidebar Profile per browser profile, tinted with that profile's color.
  > • Changes show the moment they happen. Nothing polls.
  >
  > THIS EXTENSION NEEDS THE BETTERLINK APP
  > It does nothing by itself. Install betterlink for macOS from github.com/wkoutre/betterlink, open its Sidebar page and press Set Up next to this browser. Install the extension in each browser profile you want in the sidebar.
  >
  > PRIVATE
  > The extension sends tab titles, addresses and icons only to the betterlink app on the same Mac, through the browser's native messaging. No servers, no account, no analytics, no network requests. It never reads what is on a page.
  >
  > FREE AND OPEN SOURCE
  > MIT licensed. Read every line at github.com/wkoutre/betterlink. Found a bug? github.com/wkoutre/betterlink/issues.

- **Category:** Productivity: Tools
- **Language:** English
- **Homepage URL:** https://github.com/wkoutre/betterlink
- **Support URL:** https://github.com/wkoutre/betterlink/issues

## Privacy tab

- **Single purpose:** Connects the browser to the betterlink Mac app so betterlink's sidebar can show and control this browser's tabs.
- **Permission justifications:**
  - `tabs`: Read each tab's title and address to list the tabs in betterlink's sidebar, and switch to, close, move, mute, duplicate and reload tabs when the user asks in the sidebar.
  - `nativeMessaging`: Talk to the betterlink app installed on the same Mac. This is the extension's only channel; it makes no network requests.
  - `favicon`: Show each tab's icon in the sidebar, from the browser's local icon cache.
  - `storage`: Keep one random id so betterlink can tell which browser profile this copy of the extension runs in.
- **Remote code:** No, I am not using remote code.
- **Data usage:** tick **Web history** (tab addresses and titles are handed to the betterlink app on the same Mac). Nothing else. Certify all three disclosures. Ticking nothing is arguable, since the data never leaves the Mac, but the store asks what the extension handles, not only what it uploads, and under-declaring is a common reason for rejection.
- **Privacy policy URL:** https://github.com/wkoutre/betterlink/blob/main/docs/tabs-privacy.md

## Distribution tab

- Public, all regions, free. Unlisted also works while the feature is a preview: the app links straight to the store page either way.

## Test instructions tab

> This extension is the browser half of betterlink, a macOS app. To test it: 1. Install betterlink from https://github.com/wkoutre/betterlink/releases (signed and notarized). 2. Open betterlink › Tabs and press Set Up next to Google Chrome. 3. Install this extension. 4. In betterlink › Tabs, turn on Show the sidebar and grant Accessibility when asked. A sidebar listing the window's tabs appears beside Chrome. No account is needed.
