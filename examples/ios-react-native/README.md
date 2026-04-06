# Example: iOS / React Native (Expo)

This example configures Graftery to build iOS apps using React Native with Expo, CocoaPods, and Xcode.

## What gets baked into the VM image

These scripts run once during image provisioning. The prepared image is cached and reused for every job — so slow installs (CocoaPods, ccache) only happen once.

| Script | What it does |
|--------|-------------|
| `50-install-cocoapods.sh` | Installs CocoaPods via rbenv Ruby, symlinks `pod` to `/usr/local/bin/`, sets UTF-8 locale, pre-fetches the spec repo |
| `51-install-ccache.sh` | Installs ccache and symlinks it as the default clang/clang++ for faster native module compilation |

## Setup

Copy the scripts to your Graftery scripts directory:

```bash
# macOS app (GUI)
cp examples/ios-react-native/bake.d/*.sh \
  ~/Library/Application\ Support/graftery/scripts/bake.d/

# Or for CLI usage
cp examples/ios-react-native/bake.d/*.sh /path/to/your/scripts/bake.d/
```

Restart the runner — it will detect the new scripts and reprovision the image automatically.

## What goes in your GitHub Actions workflow

These belong in your repo's workflow, not baked into the image — they change per-commit/PR:

```yaml
# .github/workflows/build-ios.yml
jobs:
  build:
    runs-on: [self-hosted, your-runner-label]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version-file: .node-version

      # Cache node_modules
      - uses: actions/cache@v4
        with:
          path: node_modules
          key: node-modules-${{ hashFiles('package-lock.json') }}

      - run: npm ci

      # Cache CocoaPods
      - uses: actions/cache@v4
        with:
          path: ios/Pods
          key: pods-${{ hashFiles('ios/Podfile.lock') }}

      - run: npx expo prebuild --platform ios --no-install
      - run: cd ios && pod install

      # Cache ccache compilation results
      - uses: actions/cache@v4
        with:
          path: ~/.ccache
          key: ccache-${{ github.ref }}-${{ github.sha }}
          restore-keys: |
            ccache-${{ github.ref }}-
            ccache-

      # Cache Xcode DerivedData
      - uses: actions/cache@v4
        with:
          path: ~/Library/Developer/Xcode/DerivedData
          key: derived-data-${{ hashFiles('ios/Podfile.lock') }}-${{ github.sha }}
          restore-keys: |
            derived-data-${{ hashFiles('ios/Podfile.lock') }}-

      - run: |
          cd ios
          xcodebuild -workspace YourApp.xcworkspace \
            -scheme YourApp \
            -configuration Release \
            -sdk iphoneos \
            -archivePath build/YourApp.xcarchive \
            archive
```

## What the Cirrus base image already includes

The `ghcr.io/cirruslabs/macos-runner:sonoma` image ships with:

- macOS Sonoma 14.x
- Xcode 16.0 + 16.1
- Node.js (via nvm)
- Ruby 3.x (via rbenv)
- Python 3.x
- Git, Homebrew, jq
- GitHub Actions runner agent

You don't need to bake any of these.

## Optimization tips

1. **CocoaPods cache is the biggest win** — `pod install` without cache downloads all pod source code (~500MB+ for a typical React Native app). The `actions/cache` for `ios/Pods` keyed on `Podfile.lock` avoids this.

2. **ccache needs warming** — The first build after a cache miss is slow. Subsequent builds reuse compiled objects. The cache key uses `github.ref` so each branch has its own cache, with fallback to other branches.

3. **DerivedData cache** — Xcode's incremental compilation is very effective when DerivedData persists. Cache it keyed on `Podfile.lock` (native deps) + SHA.

4. **Don't cache node_modules in the image** — It changes too frequently. Use `actions/cache` in the workflow instead.
