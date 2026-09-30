# Beat Haptics for Music 16.1.1

Experimental injected dylib for the stock iOS Music app. The source repository
contains no Apple binaries and no user credentials.

It observes authenticated catalog requests within Music, fetches the
`audio-analysis` relationship for the currently playing catalog song, and
schedules its beat/bar timeline with Core Haptics. It does not implement or
claim to reproduce Apple's Music Haptics AHAP assets.

This is not validated on a physical iPhone yet. In particular, whether the
Music 16.1.1 network client exposes usable authorization headers through
`NSURLSession`, and whether Core Haptics continues while Music is backgrounded,
require device testing. Logs use the `[BeatHaptics]` prefix and never print
authorization headers or cookies.
