#!/bin/bash
# Installs pre/post job hooks from the shared mount into the VM.
#
# During provisioning, the host mounts a directory containing all resolved
# hook scripts at /Volumes/My Shared Files/scripts/. This script copies
# them to /opt/arc-runner/hooks/ and creates wrapper scripts that the
# GitHub Actions runner invokes via ACTIONS_RUNNER_HOOK_JOB_STARTED and
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED environment variables.
#
# This is a STATIC script (not dynamically generated) — the provisioner
# writes the actual hook scripts to the shared mount before this runs.
set -euo pipefail

SHARED_SCRIPTS="/Volumes/My Shared Files/scripts"
HOOKS_DIR="/opt/arc-runner/hooks"
RUNNER_DIR="${GRAFTERY_DIR:-/Users/admin/actions-runner}"

sudo mkdir -p "$HOOKS_DIR/pre.d" "$HOOKS_DIR/post.d"

# Copy hook scripts from the shared mount if they exist.
if [ -d "$SHARED_SCRIPTS/hooks/pre.d" ]; then
    for f in "$SHARED_SCRIPTS/hooks/pre.d"/*.sh; do
        [ -f "$f" ] || continue
        sudo cp "$f" "$HOOKS_DIR/pre.d/"
        sudo chmod 755 "$HOOKS_DIR/pre.d/$(basename "$f")"
        echo "Installed pre-job hook: $(basename "$f")"
    done
fi

if [ -d "$SHARED_SCRIPTS/hooks/post.d" ]; then
    for f in "$SHARED_SCRIPTS/hooks/post.d"/*.sh; do
        [ -f "$f" ] || continue
        sudo cp "$f" "$HOOKS_DIR/post.d/"
        sudo chmod 755 "$HOOKS_DIR/post.d/$(basename "$f")"
        echo "Installed post-job hook: $(basename "$f")"
    done
fi

# Create wrapper scripts that iterate the .d/ directories.
# The || true ensures a failing hook doesn't prevent the job from running.
cat > /tmp/pre-job.sh << 'WRAPPEREOF'
#!/bin/bash
for f in /opt/arc-runner/hooks/pre.d/*.sh; do
    [ -x "$f" ] && bash "$f" || true
done
WRAPPEREOF
sudo mv /tmp/pre-job.sh "$HOOKS_DIR/pre-job.sh"
sudo chmod 755 "$HOOKS_DIR/pre-job.sh"

cat > /tmp/post-job.sh << 'WRAPPEREOF'
#!/bin/bash
for f in /opt/arc-runner/hooks/post.d/*.sh; do
    [ -x "$f" ] && bash "$f" || true
done
WRAPPEREOF
sudo mv /tmp/post-job.sh "$HOOKS_DIR/post-job.sh"
sudo chmod 755 "$HOOKS_DIR/post-job.sh"

# Configure the GitHub Actions runner to use our hooks.
cat >> "$RUNNER_DIR/.env" << 'ENVEOF'
ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/arc-runner/hooks/pre-job.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/arc-runner/hooks/post-job.sh
ENVEOF

echo "Runner hooks installed to $HOOKS_DIR"
