#!/usr/bin/env python3
"""Writes betterlink's changelog from git history: one entry per release tag.

There is no changelog file to keep up to date. Every merge to main is one
squash commit whose subject is the pull request's title, and every release is
a `vX.Y.Z` tag (RELEASING.md). So a release's changes are the commits between
its tag and the one before, and this script reads them:

- A commit that only touches what the release workflow ignores (its
  `paths-ignore`: docs, tests, CI) changed nothing anyone runs, so it is left
  out. That list is read from .github/workflows/release.yml, not repeated here.
- The release bot's version bumps ("betterlink 0.3.22") are left out.
- The line is the commit's subject, with its "(#123)" kept as the pull
  request's number. A "Changelog:" line in the commit message replaces it;
  "Changelog: none" leaves the commit out.

`make build` writes the result into the app (Contents/Resources/changelog.json),
where the Changelog page and `betterlink changelog list` read it, and the
release workflow publishes the same entry as the GitHub Release's notes. So
the window, the command and the release page can't disagree.

  scripts/gen-changelog.py [--out FILE]      the whole changelog as JSON
  scripts/gen-changelog.py --markdown 0.3.22 one release's notes, as Markdown
  scripts/gen-changelog.py --require 0.3.22  fail unless that release has an entry
  scripts/gen-changelog.py --self-test       this file's own cases (make test)

Without git history (a shallow clone, a source archive) it writes what it can
find, an empty list at worst, and says so; only --require fails.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/release.yml"
DEFAULT_REPO = "wkoutre/betterlink"

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
BUMP = re.compile(r"^betterlink \d+\.\d+\.\d+(?: \[skip ci\])?$")
PR = re.compile(r"\s*\(#(\d+)\)\s*$")
TRAILER = re.compile(r"(?im)^Changelog:[ \t]*(.*?)[ \t]*$")
HIDE = re.compile(r"^(none|skip|-)\.?$", re.I)


def git(*args, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def ignored_patterns(root=ROOT):
    """The release workflow's paths-ignore globs: what never ships in the app."""
    text = (root / WORKFLOW).read_text()
    m = re.search(r"^\s*paths-ignore:\s*\n((?:\s*-\s*.+\n)+)", text, re.M)
    if not m:
        sys.exit(f"gen-changelog: couldn't find paths-ignore in {WORKFLOW}. If it moved, teach scripts/gen-changelog.py where it is.")
    out = []
    for line in m.group(1).splitlines():
        item = re.sub(r"\s+#.*$", "", line.strip()[1:].strip()).strip().strip("\"'")
        if item: out.append(item)
    return out


def glob_regex(pattern):
    """GitHub's path filter globs: ** crosses folders, * doesn't."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i): out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i): out += ".*"; i += 2
        elif pattern[i] == "*": out += "[^/]*"; i += 1
        else: out += re.escape(pattern[i]); i += 1
    return re.compile(f"^{out}$")


def version_key(tag):
    return tuple(int(x) for x in TAG.match(tag).groups())


def entry(subject, body):
    """The changelog line for one commit, or None to leave it out."""
    if BUMP.match(subject.strip()): return None
    said = [t for t in TRAILER.findall(body or "") if t]
    pr = None
    m = PR.search(subject)
    if m: pr, subject = int(m.group(1)), subject[:m.start()]
    if said:
        if HIDE.match(said[-1]): return None
        subject = said[-1]
    text = subject.strip()
    if not text: return None
    return {"text": text, "pr": pr}


def commits(rev_range, cwd):
    """(subject, body, files) for each first-parent commit in the range, oldest first."""
    raw = git("log", "--first-parent", "--reverse", "--format=%H%x1f%s%x1f%b%x1e", rev_range, cwd=cwd)
    out = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record: continue
        sha, subject, body = record.split("\x1f", 2)
        files = git("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", sha, cwd=cwd).split()
        out.append((subject, body, files))
    return out


def changes(rev_range, ignored, cwd):
    out = []
    for subject, body, files in commits(rev_range, cwd):
        # An empty file list is a merge or an empty commit: keep what it says.
        if files and all(any(p.match(f) for p in ignored) for f in files): continue
        e = entry(subject, body)
        if e: out.append(e)
    return out


def build(cwd=ROOT, repo=None):
    ignored = [glob_regex(p) for p in ignored_patterns(cwd)]
    notes = []
    try:
        git("rev-parse", "--verify", "-q", "HEAD", cwd=cwd)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {"repository": repo or DEFAULT_REPO, "releases": [], "unreleased": []}, ["no git history here"]
    if git("rev-parse", "--is-shallow-repository", cwd=cwd).strip() == "true":
        notes.append("a shallow clone: releases before its first commit are missing")
    tags = sorted((t for t in git("tag", "--merged", "HEAD", "-l", "v*", cwd=cwd).split() if TAG.match(t)), key=version_key)
    releases, previous = [], None
    for tag in tags:
        stamp = int(git("log", "-1", "--format=%ct", f"{tag}^{{commit}}", cwd=cwd).strip())
        date = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).strftime("%Y-%m-%d")
        rev_range = f"{previous}..{tag}" if previous else tag
        releases.append({"version": tag[1:], "date": date, "changes": changes(rev_range, ignored, cwd)})
        previous = tag
    unreleased = changes(f"{previous}..HEAD" if previous else "HEAD", ignored, cwd)
    if not tags: notes.append("no release tags")
    releases.reverse()  # newest first, as the window shows them
    return {"repository": repo or DEFAULT_REPO, "releases": releases, "unreleased": unreleased}, notes


def markdown(log, version):
    rel = next((r for r in log["releases"] if r["version"] == version), None)
    if rel is None: return None
    repo = log["repository"]
    lines = []
    for c in rel["changes"]:
        pr = f" ([#{c['pr']}](https://github.com/{repo}/pull/{c['pr']}))" if c.get("pr") else ""
        lines.append(f"- {c['text']}{pr}")
    if not lines: lines.append("- Maintenance: nothing you would notice changed.")
    i = [r["version"] for r in log["releases"]].index(version)
    if i + 1 < len(log["releases"]):
        before = log["releases"][i + 1]["version"]
        lines += ["", f"**Full changes**: https://github.com/{repo}/compare/v{before}...v{version}"]
    return "\n".join(lines) + "\n"


def self_test():
    ok = True

    def expect(name, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print(f"self-test failed: {name}:\n  got  {got!r}\n  want {want!r}", file=sys.stderr)

    expect("subject and number", entry("Fit numbers on one line (#91)", ""), {"text": "Fit numbers on one line", "pr": 91})
    expect("no number", entry("A plain commit", ""), {"text": "A plain commit", "pr": None})
    expect("bump", entry("betterlink 0.3.22 [skip ci]", ""), None)
    expect("old bump", entry("betterlink 0.3.11", ""), None)
    expect("a fix that names a version stays", entry("Permissions page: say why; betterlink 0.3.1 (#3)", "")["pr"], 3)
    expect("Changelog: rewords", entry("CI: idle cost (#70)", "Body.\n\nChangelog: Sidebar rows redraw less.\n"),
           {"text": "Sidebar rows redraw less.", "pr": 70})
    expect("Changelog: none hides", entry("Refactor (#5)", "Changelog: none"), None)
    expect("the last Changelog: line wins", entry("X (#5)", "Changelog: none\nChangelog: Y"), {"text": "Y", "pr": 5})
    expect("glob **/*.md", bool(glob_regex("**/*.md").match("docs/tour.md")) and bool(glob_regex("**/*.md").match("README.md")), True)
    expect("glob .github/**", bool(glob_regex(".github/**").match(".github/workflows/x.yml")), True)
    expect("glob Tests/** not Sources", bool(glob_regex("Tests/**").match("Sources/Tests/x")), False)
    expect("the workflow's list is read", "Tests/**" in ignored_patterns(), True)

    # A small repository with three releases, as main is shaped.
    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        (repo / ".github/workflows").mkdir(parents=True)
        (repo / WORKFLOW).write_text((ROOT / WORKFLOW).read_text())
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull}

        def run(*a): subprocess.run(["git", *a], cwd=repo, check=True, capture_output=True, env=env)

        def commit(message, path, when):
            p = repo / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(p.read_text() + "x" if p.exists() else "x")
            run("add", "-A")
            # The committer date is what dates a release.
            env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"] = when
            run("-c", "commit.gpgsign=false", "commit", "-q", "-m", message)

        run("init", "-q", "-b", "main")
        commit("betterlink 0.1.0", "Info.plist", "2026-01-01T10:00:00Z")
        commit("First feature (#1)", "Sources/a.swift", "2026-01-01T11:00:00Z")
        run("tag", "v0.1.0")
        commit("Docs only (#2)", "README.md", "2026-01-02T10:00:00Z")
        commit("Tests and CI only (#3)", "Tests/x.swift", "2026-01-02T11:00:00Z")
        commit("A fix (#4)", "Sources/b.swift", "2026-01-02T12:00:00Z")
        commit("Internal (#5)\n\nChangelog: none", "Sources/c.swift", "2026-01-02T13:00:00Z")
        commit("betterlink 0.1.1 [skip ci]", "Info.plist", "2026-01-03T09:00:00Z")
        run("tag", "v0.1.1")
        commit("CI only (#6)", ".github/workflows/x.yml", "2026-01-04T09:00:00Z")
        commit("betterlink 0.1.2 [skip ci]", "Info.plist", "2026-01-04T10:00:00Z")
        run("tag", "v0.1.2")
        commit("Not yet released (#7)", "Sources/d.swift", "2026-01-05T10:00:00Z")
        run("tag", "not-a-version")

        log, _ = build(repo, repo="o/r")
        expect("versions, newest first", [r["version"] for r in log["releases"]], ["0.1.2", "0.1.1", "0.1.0"])
        expect("dates come from the tag", [r["date"] for r in log["releases"]], ["2026-01-04", "2026-01-03", "2026-01-01"])
        expect("0.1.1 skips docs, tests, hidden and the bump", log["releases"][1]["changes"], [{"text": "A fix", "pr": 4}])
        expect("0.1.0 has its feature", log["releases"][2]["changes"], [{"text": "First feature", "pr": 1}])
        expect("a release of CI changes only is empty", log["releases"][0]["changes"], [])
        expect("unreleased", log["unreleased"], [{"text": "Not yet released", "pr": 7}])
        expect("markdown", markdown(log, "0.1.1"),
               "- A fix ([#4](https://github.com/o/r/pull/4))\n\n**Full changes**: https://github.com/o/r/compare/v0.1.0...v0.1.1\n")
        expect("markdown of an empty release", markdown(log, "0.1.2").splitlines()[0], "- Maintenance: nothing you would notice changed.")
        expect("markdown of a missing release", markdown(log, "9.9.9"), None)

    print("gen-changelog self-test: " + ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", help="write the JSON here instead of to standard output")
    ap.add_argument("--markdown", metavar="VERSION", help="print one release's notes as Markdown")
    ap.add_argument("--require", metavar="VERSION", help="fail unless this release has an entry")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test: return self_test()

    log, notes = build(repo=os.environ.get("GITHUB_REPOSITORY"))
    for n in notes: print(f"gen-changelog: {n}.", file=sys.stderr)
    version = a.require or a.markdown
    if version and not any(r["version"] == version for r in log["releases"]):
        print(f"gen-changelog: no release v{version} in this clone's history (fetch its tags: git fetch --tags).", file=sys.stderr)
        return 1
    if a.markdown:
        sys.stdout.write(markdown(log, a.markdown))
        return 0
    if a.require and not a.out: return 0
    text = json.dumps(log, indent=1, ensure_ascii=False) + "\n"
    if a.out:
        Path(a.out).write_text(text)
        print(f"gen-changelog: {len(log['releases'])} releases -> {a.out}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
