# Regatta build runbook (macOS, Apple Silicon)

Hard-won setup for building the Regatta/cmux app from a clean machine. Verified on macOS 26 (arm64) building the baseline successfully.

## Toolchain

| Tool | Version | Install |
|---|---|---|
| Xcode | **26.0** | `xcodes install 26.0` (Apple ID required), then `sudo xcodes select 26.0`, `sudo xcodebuild -license accept`, `sudo xcodebuild -runFirstLaunch` |
| **Metal Toolchain** | bundled w/ 26.0 | `xcodebuild -downloadComponent MetalToolchain` ← **easy to miss; Ghostty's Metal shaders won't compile without it** |
| Zig | **0.15.2** (exact) | Ghostty pins `0.15.2`. Homebrew ships a newer Zig, so install the exact build separately and put it first on `PATH`: download `zig-aarch64-macos-0.15.2` from ziglang.org. |
| bun | latest | `brew install bun` (webviews build) |
| rust | latest | `brew install rust` (nucleo FFI build) |
| node | 20+ | already present via nvm here |

### PATH for builds
Zig 0.15.2 must resolve ahead of any Homebrew Zig, and node/bun/cargo must be reachable:
```bash
export PATH="$HOME/zig/zig-aarch64-macos-0.15.2:$HOME/.nvm/versions/node/<ver>/bin:/opt/homebrew/bin:$PATH"
```

## Build steps

```bash
./scripts/setup.sh              # init submodules (ghostty, bonsplit, homebrew-cmux);
                                # fetches a PREBUILT GhosttyKit.xcframework (no Ghostty source compile);
                                # installs git hooks
./scripts/reload.sh --tag dev   # build the `cmux` scheme into isolated DerivedData/bundle-id/socket
                                # add --launch to open the app after building
```

`reload.sh --tag <tag>` is preferred over bare `xcodebuild` — untagged builds share the default debug socket/bundle id and steal focus. The app is emitted as `cmux DEV <tag>.app` under `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/Build/Products/Debug/`.

## Tests

```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -destination 'platform=macOS'
```
The `cmux-unit` scheme is separate from the `cmux` app scheme. **Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`** or Xcode silently ignores them (`./scripts/lint-pbxproj-test-wiring.sh` guards this in CI).

## Gotchas

- **`reload.sh` exit code:** it returns non-zero on failure but a wrapping shell that ends in `tail`/`echo` will mask it — check for `** BUILD SUCCEEDED **` / `RELOAD_EXIT`, not the wrapper's code.
- **Metal toolchain** is the most common first-build failure on a fresh Xcode 26 (`cannot execute tool 'metal'`).
- **Zig version**: a mismatched Zig (e.g. Homebrew 0.16) fails the Ghostty `cli-helper` build phase.
