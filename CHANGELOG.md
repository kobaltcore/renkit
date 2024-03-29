# Version 4.1.0
This release changes the notarization process to be more useful on non-Apple platforms.

Specifically, `renotize` will now:
1. Sign and notarize the `.app` bundle on all platforms, replacing the original ZIP file with its notarized version.
2. On macOS, it will additionally sign and notarize a DMG image.

# Version 4.0.3
This minor release implements better output during notarization to make it easier to follow what the tool is doing at any given moment (see #15), specifically with view of the potentially-long notarization wait times from Apple's servers.

# Version 4.0.2
This minor release fixes two bugs reported in #13 and #14.

# Version 4.0.1
This is a minor maintenance release to reduce compatibility issues with openssl on recent Linux systems and images. renkit should now be compatible with more Linux distributions than before.

# Version 4.0.0
First major release of the `renkit` Rust rewrite.
