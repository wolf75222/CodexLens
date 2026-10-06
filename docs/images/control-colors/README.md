# Control-color captures

These are untouched native macOS CUA App.getScreenshot JPEGs of isolated QA applications using anonymous session fixtures. No simulated iOS screen, personal conversation, credentials or model response is shown.

| Image | Source identity | Scope |
| --- | --- | --- |
| before-settings-blue.jpg | clean ad67b79, E55909E0-F59E-3DF0-B2AA-7F5C0D367D0D | Selected Lens Violet still leaves the system Settings tab blue |
| after-settings-violet.jpg | dirty color candidate on ad67b79, A7F553C4-D61E-3F1E-84C8-93B35809DFB0 | Owned native toolbar, one violet caption, language synchronization fixed |
| after-search-violet.jpg | dirty color candidate on ad67b79, CB4ED009-EAB3-39B5-81B2-24887C080508 | Compact default button and search focus/caret follow violet |

The three QA identities differ from the production bundle. Update/removal execution is intentionally unavailable in QA. The clean final build is verified separately; these images do not establish VoiceOver, other macOS versions, performance or production-update installation.

## Checksums

- `1727927c1e17ad19dd450b6785b1bcbbd22c87a94c202db0bfaa707445747cfe` — `before-settings-blue.jpg`
- `1502d2afa31064238e5de153fe34c1f2f88e1d5df89ffee3661bc0b3cc382672` — `after-settings-violet.jpg`
- `81c82f95b21466d28cc510dd4299870dd43d199e687fb77e53fc0aba0978a944` — `after-search-violet.jpg`
