# Third-party notices

## Codex icon reference

`Assets/Brand/CodexProvided.svg` was obtained from [LobeHub lobe-icons](https://github.com/lobehub/lobe-icons/blob/master/packages/static-svg/icons/codex-color.svg). The editable Lens icons are derived from this vector, with a magnifying glass and macOS icon treatment added by this project. The original vector SHA-256 is `4a2f43ce46b5b6e3722c95088f88d26ef91e6a8c2e598e70642a1c54367386e4`.

The following upstream copyright notice and license apply to that vector. This copyright license does not grant rights to OpenAI trademarks. Codex Lens is independent and is not endorsed by OpenAI. See [OpenAI's brand guidance](https://openai.com/brand/) for names and marks.

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Build-only packaging tools

The release tooling uses dmgbuild 1.6.7, ds-store 1.3.3 and mac-alias 2.2.3. These MIT-licensed tools are installed in the build environment, not linked to or shipped inside the application. Their exact wheel hashes are pinned in `scripts/requirements-release.txt`.

- [dmgbuild license](https://github.com/dmgbuild/dmgbuild/blob/main/LICENSE)
- [ds-store license](https://github.com/dmgbuild/ds_store/blob/main/LICENSE)
- [mac-alias license](https://github.com/dmgbuild/mac_alias/blob/main/LICENSE)

## System libraries and external Codex

The app uses Apple's system frameworks and the system SQLite library. It has no remote production SwiftPM packages. Codex itself is not bundled with Lens; users install and authenticate it separately.
