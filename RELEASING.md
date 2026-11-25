# Releasing betterlink

Every merge to `main` ships a release. `.github/workflows/release.yml` runs the tests, bumps the version, tags it, builds, signs, notarizes and staples the app, **publishes** the GitHub Release, and updates the Homebrew tap. Nobody tags or clicks anything. See [Cutting a release](#cutting-a-release).

Setup happens once, in five parts: Apple (a Developer ID certificate), App Store Connect (an API key for notarization), an update signing key for Sparkle, GitHub (an environment holding seven secrets), and a deploy key for the Homebrew tap. Allow about 20 minutes.

Everything below runs on your Mac. Keep the files it makes (`.p12`, `.p8`) out of the repo and delete them, or move them to your password manager, when you finish.

## 1. Developer ID certificate (Apple)

You need the **Account Holder** role on the Apple Developer team. A Developer ID certificate can only be created by that role.

1. Open **Xcode › Settings › Accounts**. Sign in with your Apple ID if your account isn't listed.
2. Select your team, click **Manage Certificates…**, click **+** at the bottom left, and choose **Developer ID Application**.
3. Close the sheet. The certificate and its private key are now in your login keychain.

   No Xcode? Use the web instead. In Keychain Access choose **Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority…**, enter your email, choose **Saved to disk**, and save the `.certSigningRequest`. Then go to [developer.apple.com › Certificates › +](https://developer.apple.com/account/resources/certificates/add), choose **Developer ID Application**, pick the **G2 Sub-CA** profile, upload the request, download the `.cer`, and double-click it to install it into the **login** keychain (not iCloud: macOS refuses an iCloud import with error -25294). It only pairs with its private key on the Mac that made the request.

4. Find the identity's exact name. You'll need it as `MACOS_SIGN_IDENTITY`:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   It prints something like `1) ABC123… "Developer ID Application: Your Name (TEAMID1234)"`. The part in quotes is the name.

   Nothing printed? Run it without `-v`. If the identity shows up there, macOS doesn't trust it yet: install Apple's [Developer ID G2 intermediate](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer) into **login** and try again. If it doesn't show up at all, this Mac has no private key for it; make the certificate with Xcode (step 1) instead.

5. Export the certificate with its private key:
   1. Open **Keychain Access**, choose the **login** keychain, then the **My Certificates** tab.
   2. Find **Developer ID Application: …** and check that it has a disclosure arrow with a private key under it. Without the key, the export is useless.
   3. Right-click it, choose **Export "Developer ID Application: …"**, pick the format **Personal Information Exchange (.p12)**, and save it as `~/Desktop/betterlink-devid.p12`.
   4. Set a strong password when asked. That password is `MACOS_CERTIFICATE_PASSWORD`. Keychain may then ask for your Mac login password to allow the export.

## 2. Notarization API key (App Store Connect)

1. Go to [App Store Connect › Users and Access › Integrations › App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) and open the **Team Keys** tab. If it shows **Request Access**, click it and accept; that's a one-time step for the Account Holder.
2. Click **Generate API Key** (or **+**). Name it `betterlink notarization` and give it the **Developer** role. Click **Generate**.
3. Click **Download** on the new key and save `AuthKey_XXXXXXXXXX.p8` to your Desktop. **Apple lets you download it only once.**
4. Note two values on that page:
   - **Key ID**: the key's row, column "Key ID" (10 characters). This is `NOTARY_KEY_ID`.
   - **Issuer ID**: the UUID above the keys table. This is `NOTARY_ISSUER`.

## 3. Update signing key (Sparkle)

betterlink updates itself with [Sparkle](https://sparkle-project.org). Installed copies check `releases/latest/download/appcast.xml` once a day and install an update only if its EdDSA signature matches the public key built into the app (`SUPublicEDKey` in `Info.plist`). The private half signs each release in CI as the secret `SPARKLE_UPDATE_KEY`.

1. Make the key once, from a betterlink checkout. `scripts/set-release-secrets.sh` (part 4) does this for you, or by hand:

   ```sh
   swift scripts/update-key.swift keygen ~/Desktop/betterlink-update.key
   ```

   It prints the public key.
2. Put the public key in `Info.plist` under `SUPublicEDKey`, in a pull request.
3. **Keep the key file in your password manager.** Installed copies trust only this key. If it's lost, they can't be updated; people would have to download betterlink again by hand.

## 4. GitHub environment and secrets

The secrets go in an environment named `release` that only the `main` branch can use, so no other branch, and no pull request, can run code with your Developer ID. Run this in Terminal with the [GitHub CLI](https://cli.github.com) signed in as the repo owner. Set `REPO` to the repository that will publish releases (the public one, once it exists).

The easy way: from a betterlink checkout, `bash scripts/set-release-secrets.sh [owner/repo]` does all of the below, including the update key. (`--update-key-only` adds just that one.) It asks for each file and value, checks the .p12 password before saving anything, and reads the identity from the .p12 and the Key ID from the .p8's name.

Or by hand:

```sh
REPO=wkoutre/betterlink

# The environment, limited to the main branch.
gh api -X PUT "repos/$REPO/environments/release" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" \
  -f name='main' -f type=branch

# The seven secrets. Each command reads its value from a file or prompts for it,
# so nothing lands in your shell history.
base64 -i ~/Desktop/betterlink-devid.p12 | gh secret set MACOS_CERTIFICATE_P12 --env release --repo "$REPO"
gh secret set MACOS_CERTIFICATE_PASSWORD --env release --repo "$REPO"   # paste the .p12 password, then Enter
gh secret set MACOS_SIGN_IDENTITY --env release --repo "$REPO"          # paste: Developer ID Application: Your Name (TEAMID1234)
base64 -i ~/Desktop/AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8 --env release --repo "$REPO"
gh secret set NOTARY_KEY_ID --env release --repo "$REPO"                # paste the Key ID
gh secret set NOTARY_ISSUER --env release --repo "$REPO"                # paste the Issuer ID
gh secret set SPARKLE_UPDATE_KEY --env release --repo "$REPO" < ~/Desktop/betterlink-update.key

# Check: seven names, all in the release environment.
gh secret list --env release --repo "$REPO"
```

Prefer clicking? **Settings › Environments › New environment** `release`, then **Deployment branches and tags › Selected branches and tags › Add rule › Branch** `main`, then **Add environment secret** seven times with the names above. For the .p12 and .p8, paste the output of `base64 -i <file> | pbcopy`; for `SPARKLE_UPDATE_KEY`, paste the key file's one line as it is.

Then delete the local files:

```sh
rm ~/Desktop/betterlink-devid.p12 ~/Desktop/AuthKey_XXXXXXXXXX.p8 ~/Desktop/betterlink-update.key
```

Keep them in your password manager first. You can always export the `.p12` again from Keychain. The `.p8` can't be downloaded twice, but a lost one just means generating a new one. The update key can't be replaced at all (part 3).

## What the signing covers

The app is signed with `scripts/app.entitlements` (allow-jit, so JavaScriptCore can JIT config.ts under the hardened runtime). The bundled command is signed with `scripts/cli.entitlements` (what Bun executables need). A stable Developer ID also keeps macOS permissions such as Full Disk Access across updates; an ad-hoc signed build loses them each time. Sparkle's framework, helpers and XPC services are signed again with the same Developer ID, because the hardened runtime only loads code from betterlink's own team.

## 5. Homebrew tap deploy key

The workflow copies each release's cask into [wkoutre/homebrew-tap](https://github.com/wkoutre/homebrew-tap). The built-in workflow token can't write to another repository, so it uses a deploy key that can write to the tap and nothing else:

```sh
bash scripts/set-release-secrets.sh --auto-release
```

It makes an SSH key on your Mac, adds the public half to the tap as a deploy key with write access, saves the private half as `HOMEBREW_TAP_DEPLOY_KEY` in its own `homebrew-tap` environment (main only, so a required reviewer on `release` isn't asked twice per release), and deletes the local copy. It also limits `release` to `main`: it adds that branch rule and removes the old `v*` tag rule, which would otherwise let any pushed tag reach the signing keys. Without the key, releases still publish; the workflow's summary warns that the tap needs a manual copy.

## Cutting a release

Merge a pull request. That's it. On every push to `main` that changes more than docs, tests or CI (`**/*.md`, `LICENSE`, `.github/**`, `Tests/**`, `cli/test/**` and the two setup scripts `scripts/set-release-secrets.sh` / `scripts/set-version.sh` don't count), the `release` workflow:

1. **test**: runs `make test` and `make test-cli` on `main`.
2. **version**: reads `CFBundleShortVersionString` from `Info.plist`.
   - If that version has no tag yet, it is released as is. This is how to ship a minor or major version: set it in your pull request with `scripts/set-version.sh minor` (or `major`, or `0.4.0`).
   - Otherwise it bumps the patch (`scripts/set-version.sh patch`), commits `betterlink X.Y.Z` to `main` as `github-actions[bot]`, and tags it `vX.Y.Z`. Pushes made with the workflow token never start another workflow run, so the bump commit doesn't loop.

   Don't bump the patch by hand in a pull request; CI does it.
3. **release**: builds, signs, notarizes and staples the app, uploads `betterlink-<version>.zip`, `betterlink-macos.zip` (the same file under a fixed name, which simplyautomated.io/betterlink/download points at), `SHA256SUMS`, `betterlink.rb` (the Homebrew cask) and `appcast.xml` (the Sparkle feed) to a draft, then publishes it in one step. Installed copies see the update within a day: their feed URL follows GitHub's latest published release. A run without the signing secrets, or with an update key that doesn't match `SUPublicEDKey`, fails instead of shipping.
4. **tap**: copies `betterlink.rb` into the tap as `Casks/betterlink.rb`.

Merges while a release runs wait for it, then release together.

Merges that land while a release runs collapse: GitHub keeps one waiting run, a newer merge replaces it, and that run tests and ships `main`'s tip, so it carries every change merged in the meantime. A burst of merges costs at most two releases.

### Approval or a wait timer

The `release` environment (Settings › Environments › release) decides whether a release waits for a person:

- **Wait timer, no reviewer** (what betterlink uses): each release waits 10 minutes before the signing job, then ships by itself. To ship sooner, open the run and click **Start all waiting jobs** (admins can bypass the timer). To stop one, click **Cancel workflow** during the wait. Nobody has to click anything for a release to go out.
- **Required reviewer**: each release pauses before the signing job until you click **Approve** in the run. While it waits, it holds the release queue, so every later merge waits too. The tap job uses its own environment, so that is the only click.

Switch to the wait timer (10 minutes, skippable by an admin) from a Mac where `gh` is signed in as the owner:

```sh
printf '%s' '{"wait_timer":10,"reviewers":[],"can_admins_bypass":true,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  | gh api -X PUT repos/wkoutre/betterlink/environments/release --input -
```

This keeps the main-only branch rule. What the reviewer guarded against: without it, anyone who can push to `main` (you, and any token or app you've given push access) can ship a signed update to every installed copy, after the timer. Everything else stays: the keys reach only runs from `main`, `main` can't be force-pushed or deleted, release tags can't move, actions are pinned to commits, and pull requests from forks never see the secrets.

Change the environment only while no release run is waiting in it: removing a required reviewer rejects a job that is waiting for that reviewer.

To release a docs-only change anyway: **Actions › release › Run workflow**, check **publish**.

When a run fails, fix the cause and click **Re-run failed jobs**. It reuses the version the first attempt tagged, so no number is skipped, and a release that is already published isn't touched again.

## Dry run

Run the `release` workflow by hand (**Actions › release › Run workflow**) with **publish** unchecked. It runs the tests, builds and zips unsigned, never sees the signing secrets, and publishes nothing; the checksum is in the run summary. Locally, `./scripts/release.sh` does the same and leaves the files in `dist/`.

After opening a `dist/` build on a Mac where an installed betterlink is the default browser, unregister it (see CONTRIBUTING.md) so links keep going to the installed copy.
