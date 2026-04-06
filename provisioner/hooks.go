package provisioner

// Hook scripts are now handled entirely via the shared directory mount:
//
// 1. The provisioner writes hook scripts to the host staging directory
//    at hooks/pre.d/ and hooks/post.d/
// 2. The staging directory is mounted into the VM via tart --dir
// 3. The static bake script 03-install-hooks.sh copies them from the
//    mount into /opt/arc-runner/hooks/ and configures the runner's .env
//
// No dynamic bash generation (GenerateHookInstaller) is needed anymore.
// The 03-install-hooks.sh script is a real file in scripts/bake.d/,
// not a Go-generated script.
