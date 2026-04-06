#!/bin/bash
# Installs the arc-runner startup script into the VM.
# This script is invoked by the host via `tart exec` after the VM boots,
# and handles reading the JIT config from the shared mount, starting
# the GitHub Actions runner, and shutting down the VM when done.
set -euo pipefail

RUNNER_DIR="${GRAFTERY_DIR:-/Users/admin/actions-runner}"

cat > /tmp/arc-runner-startup.sh << 'STARTUPEOF'
#!/bin/bash
set -euo pipefail

SHARED_DIR="/Volumes/My Shared Files/shared"
JIT_CONFIG_FILE="${SHARED_DIR}/.runner_jit_config"
RUNNER_DIR="/Users/admin/actions-runner"
RUNNER_NAME=$(hostname -s)

# Set the machine hostname to the runner name for identification.
sudo scutil --set LocalHostName "$RUNNER_NAME" 2>/dev/null || true
sudo scutil --set ComputerName "$RUNNER_NAME" 2>/dev/null || true

echo "arc-runner-startup: runner=$RUNNER_NAME waiting for JIT config"

# Wait for the shared directory to be mounted and JIT config to appear.
for i in $(seq 1 120); do
    if [ -f "$JIT_CONFIG_FILE" ]; then
        echo "arc-runner-startup: JIT config found after ${i}s"
        break
    fi
    sleep 1
done

if [ ! -f "$JIT_CONFIG_FILE" ]; then
    echo "arc-runner-startup: ERROR: JIT config not found after 120s"
    sudo /sbin/shutdown -h now
    exit 1
fi

JIT_CONFIG=$(cat "$JIT_CONFIG_FILE")

echo "arc-runner-startup: starting runner"
cd "$RUNNER_DIR"
./run.sh --jitconfig "$JIT_CONFIG" || true

echo "arc-runner-startup: runner exited, shutting down"
sudo /sbin/shutdown -h now
STARTUPEOF

sudo mv /tmp/arc-runner-startup.sh /usr/local/bin/arc-runner-startup.sh
sudo chmod 755 /usr/local/bin/arc-runner-startup.sh
echo "startup script written to /usr/local/bin/arc-runner-startup.sh"
