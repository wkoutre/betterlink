# Releasing betterlink

Releases are built, signed, notarized and stapled by `.github/workflows/release.yml` when a `v*` tag is pushed. It opens a **draft** GitHub Release; publishing it is a manual click.

Setup happens once, in four parts: Apple (a Developer ID certificate), App Store Connect (an API key for notarization), an update signing key for Sparkle, and GitHub (an environment holding seven secrets). Allow about 20 minutes.

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

The secrets go in an environment named `release` that only `v*` tags can use, so no branch can run code with your Developer ID. Run this in Terminal with the [GitHub CLI](https://cli.github.com) signed in as the repo owner. Set `REPO` to the repository that will publish releases (the public one, once it exists).

The easy way: from a betterlink checkout, `bash scripts/set-release-secrets.sh [owner/repo]` does all of the below, including the update key. (`--update-key-only` adds just that one.) It asks for each file and value, checks the .p12 password before saving anything, and reads the identity from the .p12 and the Key ID from the .p8's name.

Or by hand:

```sh
REPO=wkoutre/betterlink

# The environment, limited to tags matching v*.
gh api -X PUT "repos/$REPO/environments/release" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" \
  -f name='v*' -f type=tag

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

Prefer clicking? **Settings › Environments › New environment** `release`, then **Deployment branches and tags › Selected branches and tags › Add rule › Tag** `v*`, then **Add environment secret** seven times with the names above. For the .p12 and .p8, paste the output of `base64 -i <file> | pbcopy`; for `SPARKLE_UPDATE_KEY`, paste the key file's one line as it is.

Then delete the local files:

```sh
rm ~/Desktop/betterlink-devid.p12 ~/Desktop/AuthKey_XXXXXXXXXX.p8 ~/Desktop/betterlink-update.key
```

Keep them in your password manager first. You can always export the `.p12` again from Keychain. The `.p8` can't be downloaded twice, but a lost one just means generating a new one. The update key can't be replaced at all (part 3).

## What the signing covers

The app is signed with `scripts/app.entitlements` (allow-jit, so JavaScriptCore can JIT config.ts under the hardened runtime). The bundled command is signed with `scripts/cli.entitlements` (what Bun executables need). A stable Developer ID also keeps macOS permissions such as Full Disk Access across updates; an ad-hoc signed build loses them each time. Sparkle's framework, helpers and XPC services are signed again with the same Developer ID, because the hardened runtime only loads code from betterlink's own team.

## Cutting a release

1. In a pull request, set `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` to the new version. They must be equal, because Sparkle compares `CFBundleVersion`. Merge it.
2. Tag the merge commit and push the tag:

   ```sh
   git checkout main && git pull
   git tag v0.3.0 && git push origin v0.3.0
   ```

3. The `release` workflow runs `make test` and `make test-cli`, then builds, signs, notarizes and staples the app. It opens a **draft** GitHub Release with `betterlink-<version>.zip`, `betterlink-macos.zip` (the same file under a fixed name, which simplyautomated.io/betterlink/download points at), `SHA256SUMS`, `betterlink.rb` (the Homebrew cask, filled in) and `appcast.xml` (the Sparkle feed, with the zip's signature). A tag without the signing secrets, or with an update key that doesn't match `SUPublicEDKey`, fails instead of shipping.
4. Check the draft, then publish it. Publishing is what makes installed copies offer the update: their feed URL follows GitHub's latest published release.
5. Copy `betterlink.rb` into the Homebrew tap as `Casks/betterlink.rb`.

## Dry run

Run the `release` workflow by hand (**Actions › release › Run workflow**). It runs the tests, builds and zips unsigned, never sees the signing secrets, and publishes nothing; the checksum is in the run summary. Locally, `./scripts/release.sh` does the same and leaves the files in `dist/`.

After opening a `dist/` build on a Mac where an installed betterlink is the default browser, unregister it (see CONTRIBUTING.md) so links keep going to the installed copy.
