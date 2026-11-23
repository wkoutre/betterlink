# Contributing to betterlink

Thanks for helping. betterlink decides where every link on a Mac opens, so changes are held to two rules: never lose a user's rules, and never open a link somewhere the user didn't ask for.

## Toolchain

- macOS 15 or later on Apple silicon.
- Xcode 16 or later. The command line tools alone can build betterlink, but `make test` needs Xcode's Swift Testing module (without it: "no such module 'Testing'").
- [Bun](https://bun.sh) 1.4.4, for the bundled `betterlink` command in `cli/`. CI and the release check that exact build by checksum (`scripts/check-bun.sh`); when you update Bun, update the version in the workflows and the checksum there together.
- Python 3, for `make tokens` and the token check in `make test`.

## Build and test

```sh
make test       # fetches the pinned TypeScript compiler, checks design tokens, runs swift test
make test-cli   # builds dist/betterlink.app, then runs the command's tests against it
make build      # dist/betterlink.app only
```

CI runs `make test` and `make test-cli` on macOS for every pull request, and [zizmor](https://github.com/zizmorcore/zizmor) lints the workflows.

## Never test against your real settings

If betterlink is installed on your Mac, your real rules live in its settings folder. A test that writes there can delete a rule you rely on.

- Set `BETTERLINK_HOME` to a temporary folder for anything that writes: running a built app, the CLI, or a script.

  ```sh
  export BETTERLINK_HOME="$(mktemp -d)"
  open -n --env BETTERLINK_HOME="$BETTERLINK_HOME" dist/betterlink.app
  ```

- Read-only commands (`betterlink status`, `rules list`, `test <url>`, `config check`) are safe against real settings.
- `dist/betterlink.app/Contents/MacOS/Betterlink --test '<url>'` prints a routing decision and opens nothing.
- Don't run `default-browser set` or `login set` from a dev build unless you mean to change your Mac.
- After launching a `dist/` build on a Mac where an installed betterlink is the default browser, unregister the dev build so links keep going to the installed copy:

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u dist/betterlink.app
  ```

## Pull requests

- Keep routing changes (anything in `Sources/BetterlinkCore` that changes where a link goes) out of visual pull requests, so each gets the review it needs.
- Add a test with every behavior change. Routing logic lives in `BetterlinkCore`, which has no AppKit so it can be unit tested.
- Design changes go through `Design/tokens.json`, then `make tokens`. `make test` fails if `DesignTokens.swift` is out of date.
- betterlink's only network code is Sparkle's update check. A change that adds any other network request needs an issue and agreement first.
- Pin any new GitHub Action to a full commit SHA, with the version in a comment.
- Leave the version in `Info.plist` alone: every merge to `main` releases and bumps the patch itself ([RELEASING.md](RELEASING.md)). Set it only to ship a minor or major version (`scripts/set-version.sh minor`).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
