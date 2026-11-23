# Security policy

betterlink sees every link you open and decides which browser loads it, so a bug that sends a link to the wrong browser or profile, or lets another party change where links go, is a security bug.

## Reporting a vulnerability

Please report it privately, either through GitHub (open the repository's **Security** tab and choose **Report a vulnerability**) or by email to nick@simplyautomated.io. Don't open a public issue.

Include the betterlink version (**About** in the window, or `betterlink --version`), your macOS version, and the link or `rules.json` that shows the problem. Strip anything private from them first.

Expect a reply within a week. Fixes ship in the next release, and the advisory credits you unless you ask otherwise.

## Supported versions

Only the latest release gets security fixes.

## Out of scope

The README lists the [accepted risks](README.md#accepted-risks): another program already running as you can edit your settings, and lookalike domains open in the fallback profile.
