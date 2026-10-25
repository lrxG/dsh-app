/// The one place the phone UI reads the release number from.
///
/// Keep in sync with `version:` in `pubspec.yaml` — the build reads that value
/// for `versionName`/`versionCode`, while this constant is what the pages show
/// (Flutter does not expose the manifest version without an extra plugin).
const String appVersion = '0.1.13';
