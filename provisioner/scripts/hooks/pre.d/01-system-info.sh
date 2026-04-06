#!/bin/bash
# Pre-job hook: logs system information before the job starts.
# Output uses ::group:: workflow commands for collapsible sections in the UI.
echo "::group::Graftery Pre-Job"
echo "Runner: $(hostname -s)"
echo "Date: $(date -u)"
echo "Uptime: $(uptime)"
echo "Disk: $(df -h / | tail -1)"
echo "Memory: $(memory_pressure 2>/dev/null | head -1 || echo 'unknown')"
echo "::endgroup::"
