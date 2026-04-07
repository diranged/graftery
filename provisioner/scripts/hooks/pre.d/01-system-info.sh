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

# Pre-job hook: logs system information before the job starts.
# Output uses ::group:: workflow commands for collapsible sections in the UI.
echo "::group::Graftery Pre-Job"
echo "Runner: $(hostname -s)"
echo "Date: $(date -u)"
echo "Uptime: $(uptime)"
echo "Disk: $(df -h / | tail -1)"
echo "Memory: $(memory_pressure 2>/dev/null | head -1 || echo 'unknown')"
echo "::endgroup::"
