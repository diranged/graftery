#!/usr/bin/env python3

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

"""Generates ~/actions-runner/.setup_info for the GitHub Actions UI.

The .setup_info file is read by the runner agent and displayed in the
"Set up job" step, giving visibility into the VM environment.

Expects ARC_BASE_IMAGE environment variable to be set.
"""
import json, subprocess, os, glob, datetime

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return "not installed"

base_image = os.environ.get("ARC_BASE_IMAGE", "unknown")
os_ver = run("sw_vers -productVersion")
os_build = run("sw_vers -buildVersion")
arch = run("uname -m")
node = run("node --version")
python_ver = run("python3 --version")
ruby = run("ruby --version")

xcodes = []
for app in sorted(glob.glob("/Applications/Xcode*.app")):
    ver = run(app + "/Contents/Developer/usr/bin/xcodebuild -version | head -1")
    xcodes.append("  " + ver + " - " + app)

xcode_str = "\n".join(xcodes) if xcodes else "  none found"
now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

info = [
    {"group": "Graftery VM", "detail": "Managed by graftery\nBase image: " + base_image + "\nProvisioned: " + now},
    {"group": "OS Detail", "detail": "macOS " + os_ver + " (" + os_build + ")\nArchitecture: " + arch},
    {"group": "Software Detail", "detail": "Xcode:\n" + xcode_str + "\nNode: " + node + "\nPython: " + python_ver + "\nRuby: " + ruby},
]

runner_dir = os.environ.get("GRAFTERY_DIR", os.path.expanduser("~/actions-runner"))
path = os.path.join(runner_dir, ".setup_info")
with open(path, "w") as f:
    json.dump(info, f, indent=2)
print(".setup_info written to " + path)
