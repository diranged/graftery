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

# Post-job hook: logs job summary after the job completes.
# Output uses ::group:: workflow commands for collapsible sections in the UI.
echo "::group::Graftery Post-Job"
echo "Runner: $(hostname -s)"
echo "Date: $(date -u)"
echo "Job result: ${GITHUB_JOB_STATUS:-unknown}"
echo "Disk: $(df -h / | tail -1)"
echo "::endgroup::"
