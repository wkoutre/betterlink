# AGENTS.md

For coding agents and reviewers working in this repository. [CONTRIBUTING.md](CONTRIBUTING.md) has the toolchain, how to test without touching real settings, and the pull request rules; this file holds what an agent gets wrong without being told.

## Building

One Swift build at a time, always through make: `make test`, `make build`. The Makefile holds the machine-wide lock, the compiler cap and the Command Line Tools flags (see its comments). Several builds at once, from parallel agents for example, ran a 24 GB Mac out of memory.

## The tour

betterlink has a tour: the first-run flow and What's New, both drawn from the steps in `Tour/tour.json` ([docs/tour.md](docs/tour.md) says how it works and how to edit it). It is only useful while it is true, so every change is weighed against it.

`make test` already fails when a new page, setting, command group or macOS permission has no step. The rest takes judgment, and it is yours to apply on every change:

**Add a step** when the change gives a person something new: something they can now do, a new place in the window or the sidebar, a new browser betterlink works with, a new thing macOS or a browser will ask them to allow, or a new command group. A change that ships a feature without its step is not finished.

**Raise a step's `revision`**, and write its `changed` sentence, when what an existing step describes now behaves differently in a way someone who already saw the step would want to know: its default changed, it moved to another page, it needs a new permission, a shortcut changed, a limit went away. The sentence says what is different, not that something is.

**Change the words only** (no new revision) when the step was unclear or wrong and the feature is the same.

**Change nothing** for a bug fix that makes the app do what the step already says, a refactor, a performance change, tests, docs, CI. Say so on the PR's `Tour:` line with the reason. "Tour: none" alone fails the `tour` check.

**Remove a step** when its feature is gone, and add its id to `retired`.

When unsure whether a change is worth showing again, ask what a person who set betterlink up a month ago would be surprised by. If nothing, leave the revision alone.

Writing a step:

- Two or three plain sentences: what the thing is for, then what happens when the control is used. No feature lists, no exclamation marks, no dashes as punctuation, no "simply" or "just".
- Say what macOS will show before the button that makes it show. Never describe a permission as required unless betterlink can't route a link without it.
- A step holds the real control, the one its page has, never a picture or a link to documentation.
- Every step with a control names the `betterlink` command that does the same (`cli`). If the control has no command, add the command in the same PR. `cliWhy` is only for what macOS lets only a person do.
- Only what nobody can use betterlink without goes in tier `essential`, which is capped at six steps. Everything else is tier `more`.
- The tour never opens by itself except once, on the first run. Don't add anything that opens a window after an update, on a link click, or on a timer.

Reviewing a pull request, check each of these and say which you checked:

1. Does the diff add or change something a person sees, can do, or is asked to allow? Then `Tour/tour.json` should have changed. A `Tour: none` line on such a PR is a finding.
2. Does a changed step still describe what its control does after this diff? Read the step's body against the code it drives.
3. If an existing feature behaves differently, was `revision` raised with a `changed` sentence that names the difference?
4. Does anything new in the GUI have its `betterlink` command, and does the step show it?
5. Is the PR's `Tour:` line true?
