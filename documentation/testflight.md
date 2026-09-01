# TestFlight releases

The `TestFlight` GitHub Actions workflow builds a signed iOS IPA and uploads it
to App Store Connect. It runs only when started manually from the repository's
**Actions** tab.

## Apple setup

The Apple Developer team must contain all of the following:

- An App Store Connect app for bundle ID `com.monitormx.meshcoreopen`.
- An active Apple Distribution certificate, exported with its private key as a
  password-protected `.p12` file.
- An App Store distribution provisioning profile for the same bundle ID.
- An App Store Connect API key with at least the App Manager role. Save the
  downloaded `AuthKey_*.p8` file; Apple allows it to be downloaded only once.

## GitHub configuration

In **Settings > Secrets and variables > Actions**, add these repository values:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `APPSTORE_ISSUER_ID` | Issuer ID from App Store Connect |
| Variable | `APPSTORE_API_KEY_ID` | API key ID from App Store Connect |
| Secret | `APPSTORE_API_PRIVATE_KEY` | Complete contents of `AuthKey_*.p8` |
| Secret | `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64-encoded distribution `.p12` |
| Secret | `APPSTORE_CERTIFICATES_PASSWORD` | Password used when exporting the `.p12` |

Encode the certificate on macOS with:

```bash
base64 -i ios_distribution.p12 | pbcopy
```

The Apple Actions provisioning-profile project also provides setup scripts that
can create the certificate/profile and configure these GitHub values:
<https://github.com/Apple-Actions/download-provisioning-profiles#setup-script-examples>

## Upload a build

1. Open **Actions > TestFlight > Run workflow**.
2. Optionally enter release notes and start the workflow.
3. After Apple finishes processing the build, open the TestFlight tab in App
   Store Connect and add it to an internal tester group.

The workflow uses its GitHub run number as the iOS build number, so every upload
has a unique build number. It also saves the generated IPA as a workflow artifact
for 30 days.
