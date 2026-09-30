# Beat Haptics for Music 16.1.1

Experimental injected dylib for the stock iOS Music app. The source repository
contains no Apple binaries and no user credentials.

## TrollStore IPA limitation

A re-signed Music 16.1.1 IPA can launch under TrollStore, but the iPhone XR
test on iOS 16.1.1 showed that the installed process is **not granted** key
private privileges needed by Music. The live device log reported
`com.apple.accounts.appleaccount.fullaccess - Entitled: NO`, followed by
`com.apple.accounts` errors 7/9 and an unresolved active account, even though
the entitlement is present in the IPA's code signature. The app then presents
itself as offline and cannot play downloaded tracks. This is consistent with a
process trust limitation, not a missing URL or Music account token. A functional
integration needs injection into the original, appropriately trusted Music
process; the TrollStore IPA is not currently a usable solution.

It observes authenticated catalog requests within Music, fetches the
`audio-analysis` relationship for the currently playing catalog song, and
schedules its beat/bar timeline with Core Haptics. It does not implement or
claim to reproduce Apple's Music Haptics AHAP assets.

The injected library must use the arm64e ABI: Music 16.1.1 itself is arm64e,
and dyld rejects an arm64-only library before any injected code can run.
When packaging the IPA, add a non-empty `NSAppleMusicUsageDescription` string
to the main app's `Info.plist` before re-signing it. The original system app
does not include that key; accessing `MPMusicPlayerController` from the
modified app otherwise causes a TCC privacy-violation abort at launch.

The arm64e module loads on an iPhone XR, but end-to-end beat playback has not
been validated because the re-signed app cannot access the Music account.
Whether Music 16.1.1 exposes usable authorization headers through
`NSURLSession`, and whether Core Haptics continues while Music is backgrounded,
remain untested. Logs use the `[BeatHaptics]` prefix and never print
authorization headers or cookies.
