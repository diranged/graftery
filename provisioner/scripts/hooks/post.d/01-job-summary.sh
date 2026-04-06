#!/bin/bash
# Post-job hook: logs job summary after the job completes.
# Output uses ::group:: workflow commands for collapsible sections in the UI.
echo "::group::Graftery Post-Job"
echo "Runner: $(hostname -s)"
echo "Date: $(date -u)"
echo "Job result: ${GITHUB_JOB_STATUS:-unknown}"
echo "Disk: $(df -h / | tail -1)"
echo "::endgroup::"
