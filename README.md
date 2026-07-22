# Monochrome iOS 12

An iPhone-focused Monochrome build with repaired playback initialization, safe-area layout, and an optional Apple Music-inspired liquid-glass appearance.

## Apple Music theme

Open **Settings → Appearance → Apple Music**. The selection is persisted by Monochrome and applies:

- translucent, saturated glass surfaces;
- restrained pink accent color;
- compact iPhone mini-player and navigation;
- softer borders, highlights, and depth;
- the existing iPhone 12 safe-area layout.

## GitHub Actions IPA

Every push to `main`, and every manual workflow dispatch, builds `Monochrome-iOS-12.ipa` on a macOS runner and uploads it as the `Monochrome-iOS-12-unsigned` artifact.

The artifact is intentionally unsigned because the repository does not contain an Apple certificate or provisioning profile. Sign it with your own Apple developer identity or a sideloading tool before installation.

See [IOS_REPAIR.md](IOS_REPAIR.md) for the playback diagnosis and native project details.
