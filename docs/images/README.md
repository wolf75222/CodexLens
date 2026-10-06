# Documentation images

These PNGs are ScreenCaptureKit compositor captures of the current 0.41.0 app running in an isolated QA bundle. Navigation and inspection used CUA. The bundle retained the production Mach-O sections and UUID; its signature, preferences, cache and investigation archive were private to the test.

The session is a synthetic anonymous on-disk history. Recorded fixture actions are not real user/agent activity. The chat image shows a selected version and an unsent draft, with no authenticated model answer. No personal account names, credentials or user conversations are shown. English interface labels coexist with French synthetic recorded text, which Lens preserves unchanged.

`provenance.json` contains capture method, version, UUID, dimensions and image hashes without private machine paths. `bash scripts/render-docs.sh` produces separate offscreen component renders for development and CI; those are not the committed compositor screenshots and do not faithfully capture all glass/material layers.

The detailed [Feature catalogue](../FEATURES.md) adds 17 native CUA captures. Their separate [capture notes](features/README.md) and [metadata](features/provenance.json) identify the format, anonymous scenarios and original image hashes.
