#!/bin/bash
# Installs ccache for faster C/C++ compilation of React Native native modules.
#
# ccache caches compiled object files. When the same source file is compiled
# again with the same flags, ccache returns the cached result instantly.
# This dramatically speeds up rebuilds of native modules (Hermes, Folly, etc.)
# that don't change between most app builds.
#
# The symlinks make clang/clang++ go through ccache transparently — no
# changes needed in the Xcode build settings or Podfile.
#
# For ccache to be effective across builds, the workflow must cache
# ~/.ccache using actions/cache.
set -euo pipefail

echo "Installing ccache..."
brew install --quiet ccache

# Symlink ccache as the default compiler so xcodebuild uses it automatically
sudo ln -sf "$(brew --prefix ccache)/libexec/clang" /usr/local/bin/clang
sudo ln -sf "$(brew --prefix ccache)/libexec/clang++" /usr/local/bin/clang++

ccache --version | head -1
echo "ccache installed and symlinked"
