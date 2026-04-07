#!/bin/bash

# Copyright 2026 Matt Wise
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Installs CocoaPods into the VM image.
#
# The Cirrus base image ships with system Ruby 2.6 which is too old for
# modern CocoaPods. This script uses the rbenv Ruby 3.x that's already
# installed, then symlinks `pod` to /usr/local/bin/ so it's available
# in all shells (including GitHub Actions' --noprofile --norc bash).
set -euo pipefail

echo "Installing CocoaPods..."

# Set up rbenv — tart exec doesn't load shell profiles
export PATH="/Users/admin/.rbenv/shims:/Users/admin/.rbenv/bin:$PATH"
eval "$(rbenv init - 2>/dev/null)" || true

echo "Ruby version: $(ruby --version)"

gem install cocoapods

# Symlink to /usr/local/bin/ for PATH availability in all shells
sudo ln -sf "$(rbenv which pod)" /usr/local/bin/pod

# Set UTF-8 locale — CocoaPods crashes without it
cat >> /Users/admin/actions-runner/.env << 'ENVEOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
ENVEOF

# Pre-fetch the spec repo (~2GB index, rarely changes).
# This avoids a 30s+ clone on the first `pod install` in a job.
pod repo update

pod --version
echo "CocoaPods installed successfully"
