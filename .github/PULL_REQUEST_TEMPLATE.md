## What changes

<!-- What the user sees or what routes differently, in a sentence or two. -->

## Why

## Tour

<!-- The tour is the first-run flow and What's New (docs/tour.md). If this PR
adds or changes something a person can do, sees, or is asked to allow, add or
revise a step in Tour/tour.json, run `make tour`, and say which step below.
If it doesn't, write "none" and the reason. The `tour` check reads this line. -->

Tour:

## Testing

- [ ] `make test`
- [ ] `make test-cli` (if `cli/` or the agent API changed)
- [ ] Anything run by hand used `BETTERLINK_HOME` set to a temporary folder

## Checklist

- [ ] Routing changes are not mixed with visual changes
- [ ] No network code added (the Sparkle update check is the only one)
- [ ] README updated if behavior changed
- [ ] A changed tour step that people should see again has its `revision` raised and a `changed` sentence
