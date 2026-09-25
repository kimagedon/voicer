# Contributing

## Build

```sh
./build.sh                                   # build/Voicer.app
build/Voicer.app/Contents/MacOS/Voicer --demo    # preview the HUD
```

The first build downloads the model into `Models/` and whisper.cpp into `vendor/`. Later builds take a few seconds.

Every ad-hoc build asks for Accessibility again. To keep the permission across rebuilds, create a self-signed *Code Signing* certificate named `Voicer Dev` in Keychain Access, then build with `SIGN_ID="Voicer Dev" ./build.sh`.

## Changes

Collaborators push to `main`. Everyone else forks the repo and opens a pull request. Keep each change focused, and add a screenshot if it touches the HUD.

Write code, comments and UI text in English. Don't commit models, build output, or secrets.

## Release

1. Bump the version in `Resources/Info.plist`.
2. Run `./build.sh --zip`.
3. Run `gh release create v<version> build/Voicer-<version>.zip`.
