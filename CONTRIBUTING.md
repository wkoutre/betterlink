# Contributing to betterlink

Thanks for helping. betterlink decides where every link on a Mac opens, so changes are held to two rules: never lose a user's rules, and never open a link somewhere the user didn't ask for.

## Toolchain

- macOS 15 or later on Apple silicon.
- Xcode 16 or later, or the Command Line Tools alone: with only the Command Line Tools, `make test` adds the paths their Swift Testing module needs.
- [Bun](https://bun.sh) 1.4.4, for the bundled `betterlink` command in `cli/`. CI and the release check that exact build by checksum (`scripts/check-bun.sh`); when you update Bun, update the version in the workflows and the checksum there together.
- Python 3, for `make tokens`, `make tour` and the checks `make test` runs before the Swift tests.

## Build and test

```sh
make test       # fetches the pinned TypeScript compiler, checks design tokens and the tour, runs swift test
make test-cli   # builds dist/betterlink.app, then runs the command's tests against it
make build      # dist/betterlink.app only
```

`make build` signs the app with a Developer ID Application certificate from your keychain (`scripts/sign.sh`, the sequence releases use), so macOS keeps the permissions you gave it across rebuilds. With none the build is ad-hoc signed, and macOS asks again after each build. Pick another identity with `make build DEV_SIGN_IDENTITY="…"`, or none with `DEV_SIGN_IDENTITY=`.

CI runs `make test` and `make test-cli` on macOS for every pull request, [zizmor](https://github.com/zizmorcore/zizmor) lints the workflows, and the `tour` check reads the pull request against the tour (below).

## Never test against your real settings

If betterlink is installed on your Mac, your real rules live in its settings folder. A test that writes there can delete a rule you rely on.

- Set `BETTERLINK_HOME` to a temporary folder for anything that writes: running a built app, the CLI, or a script. It also gives that folder its own preferences (the sidebar, Sync, the toast), so a fresh folder starts with Sync off.

  ```sh
  export BETTERLINK_HOME="$(mktemp -d)"
  open -n --env BETTERLINK_HOME="$BETTERLINK_HOME" dist/betterlink.app
  ```

- Read-only commands (`betterlink status`, `rules list`, `test <url>`, `config check`) are safe against real settings.
- `dist/betterlink.app/Contents/MacOS/Betterlink --test '<url>'` prints a routing decision and opens nothing.
- Don't run `default-browser set` or `login set` from a dev build unless you mean to change your Mac.
- `tabs setup` writes into a browser's own folder, which `BETTERLINK_HOME` doesn't move, so it refuses to run while `BETTERLINK_HOME` is set. From a dev build without it, it points that browser's Tabs extension at the dev build until the installed betterlink is opened again.
- After launching a `dist/` build on a Mac where an installed betterlink is the default browser, unregister the dev build so links keep going to the installed copy:

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u dist/betterlink.app
  ```

## Pull requests

- Keep routing changes (anything in `Sources/BetterlinkCore` that changes where a link goes) out of visual pull requests, so each gets the review it needs.
- Add a test with every behavior change. Routing logic lives in `BetterlinkCore`, which has no AppKit so it can be unit tested.
- Design changes go through `Design/tokens.json`, then `make tokens`. `make test` fails if `DesignTokens.swift` is out of date.
- The tour (the first-run flow and What's New) changes with the app. If your change adds or changes something a person can do, sees, or is asked to allow, add or revise its step in `Tour/tour.json` and run `make tour`; otherwise say why not on the `Tour:` line of the pull request. [AGENTS.md](AGENTS.md#the-tour) says when a change needs a step, and [docs/tour.md](docs/tour.md) how to write one and what `make test` checks.
- The pull request's title is its line in the changelog (the Changelog page, `betterlink changelog list`, and the GitHub Release's notes). Write it for someone who uses betterlink: what changed for them, not how. To reword it after the merge, or leave out a change nobody would notice, put `Changelog: <the line>` or `Changelog: none` in the squash commit's message. [AGENTS.md](AGENTS.md#the-changelog) has the details.
- betterlink's only network code is Sparkle's update check. A change that adds any other network request needs an issue and agreement first.
- Pin any new GitHub Action to a full commit SHA, with the version in a comment.
- Leave the version in `Info.plist` alone: every merge to `main` releases and bumps the patch itself ([RELEASING.md](RELEASING.md)). Set it only to ship a minor or major version (`scripts/set-version.sh minor`).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
