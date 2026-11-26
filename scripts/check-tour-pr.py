#!/usr/bin/env python3
"""Checks a pull request against the tour (docs/tour.md).

scripts/gen-tour.py checks what can be read from the code: every page,
command, setting and permission has a step. This checks what only a pull
request shows: that someone decided what the change means for the tour.

  1. A PR that changes what ships (the app, the command, the Tabs extension)
     either changes Tour/tour.json or says, on a "Tour:" line in its
     description, why the tour stays as it is.
  2. A step's revision never goes down, and a raised revision comes with a
     new "changed" sentence.
  3. A removed step's id goes on the "retired" list, so it is never used
     again for another step.

Run by .github/workflows/tour.yml:
  python3 scripts/check-tour-pr.py --files <file of changed paths> [--base <tour.json on the base>]
with the description in PR_BODY. `--self-test` runs this file's own cases
(make test).
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOUR = "Tour/tour.json"

# What ships to people: a change here can change what they see, can do or
# are asked to allow.
SHIPS = re.compile(
    r"^(Sources/|cli/src/|browser-extension/(?!tests/)|Info\.plist$|scripts/[^/]+\.entitlements$)")
# The tour's own code and what gen-tour.py writes: changing how the tour is
# drawn is not a feature to tell people about.
TOUR_CODE = re.compile(r"^(Sources/Betterlink/Tour/|Sources/BetterlinkCore/Tour[^/]*\.swift$)")

NO_CHANGE = re.compile(r"^(none|no changes?(?: needed)?|unchanged|not needed|n/a)\b[\s,.:;()\-–—]*(.*)$", re.I)
MIN_REASON_WORDS = 3


def tour_line(body):
    """What the description's "Tour:" line says; None with no such line."""
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    found = [m.group(1).strip().strip("*_ ") for m in re.finditer(r"(?im)^[ \t>*_-]*Tour[*_]*:[*_]*[ \t]*(.*)$", text)]
    found = [f for f in found if f]
    return found[-1] if found else None


def ships(files):
    return [f for f in files if SHIPS.match(f) and not TOUR_CODE.match(f)]


def check_note(files, body):
    """Problems with the PR's decision about the tour."""
    changed_tour = TOUR in files
    line = tour_line(body)
    shipping = ships(files)
    if line is None:
        if changed_tour or not shipping: return []
        some = ", ".join(shipping[:3]) + (f" and {len(shipping) - 3} more" if len(shipping) > 3 else "")
        return [
            f"This PR changes what ships ({some}) and not {TOUR}, and its description has no \"Tour:\" line.\n"
            "  If it adds or changes something a person can do, sees, or is asked to allow: add or revise a step in "
            f"{TOUR}, then run `make tour` (docs/tour.md says when and how).\n"
            "  If it doesn't: say so in the description, with the reason, on a line like\n"
            "    Tour: none, a bug fix in how rules match; nothing new to show."]
    none = NO_CHANGE.match(line)
    if none:
        if changed_tour:
            return [f"The description says \"Tour: {line}\", and this PR changes {TOUR}. Say what changed in the tour instead."]
        if len(none.group(2).split()) < MIN_REASON_WORDS:
            return [f"\"Tour: {line}\" gives no reason. Say in a few words why nothing in the tour changes, "
                    "for example: Tour: none, a refactor with no change a person sees."]
        return []
    if not changed_tour:
        return [f"The description says \"Tour: {line}\", and this PR doesn't change {TOUR}. "
                "Add or revise the step there and run `make tour`, or write: Tour: none, <why>."]
    return []


def steps_of(tour):
    return {s["id"]: s for t in tour.get("topics", []) for s in t.get("steps", []) if isinstance(s.get("id"), str)}


def check_history(base, head):
    """(problems, notes) from comparing the tour on the base with the PR's."""
    problems, notes = [], []
    before, after = steps_of(base), steps_of(head)
    retired = set(head.get("retired") or [])
    for gone in sorted(set(base.get("retired") or []) - retired):
        problems.append(f"\"{gone}\" was taken off the retired list. A retired id stays retired: betterlink may still remember it as seen.")
    for sid, old in before.items():
        new = after.get(sid)
        if new is None:
            if sid not in retired:
                problems.append(f"Step \"{sid}\" was removed (or renamed). Add \"{sid}\" to \"retired\" in {TOUR}: "
                                "betterlink remembers a step by its id, so an id is never used again for another step. "
                                "A step that only moved or was reworded keeps its id.")
            continue
        was, now = old.get("revision", 1), new.get("revision", 1)
        if now < was:
            problems.append(f"Step \"{sid}\" went from revision {was} to {now}. A revision only goes up.")
        elif now > was:
            if not new.get("changed") or new.get("changed") == old.get("changed"):
                problems.append(f"Step \"{sid}\" is now at revision {now} and its \"changed\" sentence is the old one. "
                                "Say what is different this time, for people who saw the earlier step.")
        else:
            if (old.get("control"), old.get("status")) != (new.get("control"), new.get("status")):
                notes.append(f"Step \"{sid}\" acts or reports differently and is still at revision {now}. "
                             "Raise \"revision\" (with a \"changed\" sentence) if someone who saw it should see it again.")
            elif (old.get("title"), old.get("body")) != (new.get("title"), new.get("body")):
                notes.append(f"Step \"{sid}\" was reworded and is still at revision {now}: right for a wording fix. "
                             "Raise \"revision\" if what it describes changed.")
            for key, what in (("cli", "command"), ("requires", "condition"), ("covers", "coverage")):
                if old.get(key) != new.get(key):
                    notes.append(f"Step \"{sid}\" has a different {what} ({key}). Check its words still match.")
    for sid in sorted(set(after) - set(before)):
        notes.append(f"Step \"{sid}\" is new: people who finished the tour are offered it under What's New.")
    # An exemption is the quiet way to pass the coverage check, so each new
    # one is named for the reviewer.
    for kind in sorted(set(base.get("exempt") or {}) | set(head.get("exempt") or {})):
        was, now = (base.get("exempt") or {}).get(kind) or {}, (head.get("exempt") or {}).get(kind) or {}
        for name in sorted(set(now) - set(was)):
            notes.append(f"exempt.{kind} now lists \"{name}\": it has no step, because \"{now[name]}\" A reviewer should agree.")
        for name in sorted(set(was) & set(now)):
            if was[name] != now[name]: notes.append(f"exempt.{kind}'s reason for \"{name}\" changed.")
    return problems, notes


def self_test():
    ok = True

    def expect(name, got, want):
        nonlocal ok
        if bool(got) != want:
            ok = False
            print(f"self-test failed: {name}: {got!r}", file=sys.stderr)

    app, tour = ["Sources/Betterlink/Pages.swift"], [TOUR]
    expect("docs only", check_note(["README.md", "docs/tour.md", ".github/workflows/test.yml"], ""), False)
    expect("tests only", check_note(["Tests/BetterlinkTests/X.swift", "cli/test/cli.test.ts"], None), False)
    expect("dependency bump", check_note(["cli/bun.lock", "cli/package.json", "Package.resolved"], ""), False)
    expect("app change, nothing said", check_note(app, "## What changes\nA new page."), True)
    expect("app change with the tour", check_note(app + tour, ""), False)
    expect("app change, none with reason", check_note(app, "## Tour\n\nTour: none, a bug fix in rule matching.\n"), False)
    expect("none without reason", check_note(app, "Tour: none"), True)
    expect("none with a thin reason", check_note(app, "Tour: n/a."), True)
    expect("the template's own comment is not an answer", check_note(app, "<!-- Tour: none, because the template says so -->\nTour:"), True)
    expect("bold label", check_note(app, "**Tour:** no change - only the log's wording moved"), False)
    expect("no changes needed", check_note(app, "Tour: no changes needed, the fix is in how rules are matched"), False)
    expect("says added, tour untouched", check_note(app, "Tour: added a step for the new page"), True)
    expect("says added, tour changed", check_note(app + tour, "Tour: added a step for the new page"), False)
    expect("says none, tour changed", check_note(app + tour, "Tour: none, nothing to see here"), True)
    expect("the tour's own code", check_note(["Sources/Betterlink/Tour/TourView.swift", "Sources/BetterlinkCore/TourRegistry.swift"], ""), False)
    expect("the extension", check_note(["browser-extension/background.js"], ""), True)
    expect("the extension's tests", check_note(["browser-extension/tests/a.test.mjs"], ""), False)
    expect("the command", check_note(["cli/src/bin.ts"], ""), True)
    expect("an entitlement", check_note(["scripts/app.entitlements"], ""), True)

    def t(*steps, retired=None):
        out = {"topics": [{"id": "a", "steps": [dict(s) for s in steps]}]}
        if retired is not None: out["retired"] = retired
        return out

    one = {"id": "one", "revision": 1, "title": "One", "body": "First."}
    expect("same", check_history(t(one), t(one))[0], False)
    expect("removed", check_history(t(one), t())[0], True)
    expect("removed and retired", check_history(t(one), t(retired=["one"]))[0], False)
    expect("unretired", check_history(t(retired=["one"]), t())[0], True)
    expect("revision down", check_history(t({**one, "revision": 2, "changed": "x"}), t(one))[0], True)
    expect("revision up, nothing said", check_history(t(one), t({**one, "revision": 2}))[0], True)
    expect("revision up, old sentence", check_history(t({**one, "revision": 2, "changed": "x"}), t({**one, "revision": 3, "changed": "x"}))[0], True)
    expect("revision up, new sentence", check_history(t(one), t({**one, "revision": 2, "changed": "Now does more."}))[0], False)
    expect("reworded is a note", check_history(t(one), t({**one, "body": "Second."}))[1], True)
    expect("reworded is no problem", check_history(t(one), t({**one, "body": "Second."}))[0], False)
    expect("new step is a note", check_history(t(one), t(one, {**one, "id": "two"}))[1], True)
    expect("new command is a note", check_history(t(one), t({**one, "cli": "betterlink x"}))[1], True)
    exempted = t(one); exempted["exempt"] = {"pages": {"about": "Has nothing to set up."}}
    expect("new exemption is a note", check_history(t(one), exempted)[1], True)
    expect("new exemption is no problem", check_history(t(one), exempted)[0], False)
    expect("same exemption says nothing", check_history(exempted, exempted)[1], False)
    return ok


def main(argv):
    if "--self-test" in argv:
        return 0 if self_test() else 1
    files_path = base_path = None
    it = iter(argv)
    for a in it:
        if a == "--files": files_path = next(it, None)
        elif a == "--base": base_path = next(it, None)
        else:
            print(f"Unknown argument {a}.", file=sys.stderr)
            return 2
    if not files_path:
        print(__doc__, file=sys.stderr)
        return 2
    files = [line.strip() for line in Path(files_path).read_text().splitlines() if line.strip()]
    problems, notes = check_note(files, os.environ.get("PR_BODY", "")), []
    if base_path and Path(base_path).is_file() and TOUR in files:
        try:
            base = json.loads(Path(base_path).read_text())
            head = json.loads((ROOT / TOUR).read_text())
        except (OSError, ValueError) as e:
            print(f"Couldn't compare the tour with the base ({e}); `make test` checks {TOUR} itself.")
        else:
            more, notes = check_history(base, head)
            problems += more
    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    for n in notes:
        print(f"::notice title=Tour::{n}" if gha else f"note: {n}")
    for p in problems:
        first, _, rest = p.partition("\n")
        print(f"::error title=Tour::{first}" if gha else f"error: {first}")
        if rest: print(rest)
    if not problems:
        print("Tour: ok." + ("" if ships(files) or TOUR in files else " Nothing in this PR ships."))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
