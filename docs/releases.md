# Releases and automatic updates

GitHub Actions creates each release from a version tag. The workflow signs, notarizes, packages, and publishes the app and its Sparkle appcast.

The workflow gets the Sparkle public key from the private key. Local builds do not start Sparkle unless they contain a valid public key.

## Requirements

Get these items before you configure the repository:

- A Developer ID Application certificate from Apple.
- The certificate and private key in one password-protected `.p12` file.
- An App Store Connect API key that your team can use for notarization.
- The GitHub CLI with access to `mbokinala/tamarin`.

## Add the Apple secrets

If `gh auth status` reports an invalid token, authenticate the GitHub CLI again.

```sh
gh auth login -h github.com
```

1. Encode the `.p12` file and add it to GitHub Secrets.

   ```sh
   base64 -i DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64
   ```

2. Add the password for the `.p12` file.

   ```sh
   gh secret set DEVELOPER_ID_APPLICATION_P12_PASSWORD
   ```

3. Encode the App Store Connect API key and add it to GitHub Secrets.

   ```sh
   base64 -i AuthKey_KEY_ID.p8 | gh secret set APP_STORE_CONNECT_API_KEY_P8_BASE64
   ```

4. Add the API key ID.

   ```sh
   gh secret set APP_STORE_CONNECT_API_KEY_ID
   ```

5. If you use a Team API key, add the API issuer ID.

   ```sh
   gh secret set APP_STORE_CONNECT_API_ISSUER_ID
   ```

   Individual API keys do not use an issuer ID.

Each `gh secret set` command without input opens a secure prompt.

CAUTION: Protect `main` and require review for workflow changes. A changed release workflow can expose the signing secrets.

## Add the Sparkle secret

1. Resolve the Swift packages into a temporary directory.

   ```sh
   sparkle_packages_dir="$(mktemp -d /tmp/tamarin-sparkle.XXXXXX)"
   xcodebuild -resolvePackageDependencies \
     -project Tamarin.xcodeproj \
     -scheme Tamarin \
     -clonedSourcePackagesDirPath "$sparkle_packages_dir"
   ```

2. Set the path to the Sparkle tools.

   ```sh
   sparkle_bin="$sparkle_packages_dir/artifacts/sparkle/Sparkle/bin"
   ```

3. Generate the Sparkle key in the login keychain.

   ```sh
   "$sparkle_bin/generate_keys" --account com.mbokinala.Tamarin
   ```

4. Export the private key to a temporary file.

   ```sh
   sparkle_key_dir="$(mktemp -d /tmp/tamarin-sparkle-key.XXXXXX)"
   sparkle_key_file="$sparkle_key_dir/private-key"
   "$sparkle_bin/generate_keys" \
     --account com.mbokinala.Tamarin \
     -x "$sparkle_key_file"
   ```

5. Store an encrypted backup of the private key outside this repository.

6. Add the private key to GitHub Secrets.

   ```sh
   gh secret set SPARKLE_PRIVATE_KEY < "$sparkle_key_file"
   ```

7. Remove the temporary private key and directory.

   ```sh
   rm -f "$sparkle_key_file"
   rmdir "$sparkle_key_dir"
   ```

CAUTION: Never commit the Sparkle private key. Loss of this key can prevent safe automatic updates for installed copies.

## Publish a release

1. Make sure that the release commit is on `main`.

2. Create an annotated version tag.

   ```sh
   git tag -a v1.0.0 -m "Tamarin 1.0.0"
   ```

3. Push the tag.

   ```sh
   git push origin v1.0.0
   ```

The tag must use the `vMAJOR.MINOR.PATCH` format. The workflow uses this value for both app version fields.

The workflow publishes these release assets:

- `Tamarin-MAJOR.MINOR.PATCH.dmg`
- `Tamarin-MAJOR.MINOR.PATCH.dSYM.zip`
- `appcast.xml`

The disk image contains `Tamarin.app` and an `Applications` link.

The workflow publishes full updates. It does not create delta updates from older release archives.

Sparkle reads the latest appcast from this URL:

```text
https://github.com/mbokinala/tamarin/releases/latest/download/appcast.xml
```

Do not move or reuse a published version tag. Create a new version tag for each new release.

## Release process

The release workflow does these operations:

1. Imports the Developer ID Application certificate into a temporary keychain.
2. Gets the Sparkle public key from `SPARKLE_PRIVATE_KEY`.
3. Archives and exports the app with Developer ID signing.
4. Creates and signs a disk image.
5. Sends the disk image to the Apple notarization service.
6. Adds the notarization ticket to the disk image.
7. Creates and signs the Sparkle appcast.
8. Creates a GitHub release with automatic release notes.

The workflow removes the temporary keychain at the end of the job.
