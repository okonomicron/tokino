#!/usr/bin/env bash
# Prints the UDID of a booted-capable iPhone simulator running at least the
# app's minimum iOS version, creating one if the image has none.
#
# Hardcoding a device name ('iPhone 17') breaks whenever the runner image
# changes its pre-created devices, which is a confusing failure a long way from
# the cause. Discovering one is stable across image updates.
#
# Usage: ios-simulator-udid.sh [minimum-major-version]
set -euo pipefail

MIN_MAJOR="${1:-26}"

find_udid() {
  xcrun simctl list devices available --json | MIN_MAJOR="$MIN_MAJOR" python3 -c '
import json, os, re, sys

minimum = int(os.environ["MIN_MAJOR"])
devices = json.load(sys.stdin)["devices"]
best = None

for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version[0] < minimum:
        continue
    for entry in entries:
        if "iPhone" not in entry.get("name", ""):
            continue
        # Prefer the newest runtime, so the app is tested against the OS its
        # users are most likely to be on.
        if best is None or version > best[0]:
            best = (version, entry["udid"], entry["name"], runtime)

if best is None:
    sys.exit(1)

print(best[1])
print(f"{best[2]} on iOS {best[0][0]}.{best[0][1]}", file=sys.stderr)
'
}

if udid=$(find_udid); then
  echo "$udid"
  exit 0
fi

# Nothing suitable exists: create a device on the newest runtime that meets the
# minimum. A missing device is a recoverable image difference, not a failure.
echo "No iPhone simulator on iOS ${MIN_MAJOR}+; creating one." >&2

runtime=$(xcrun simctl list runtimes --json | MIN_MAJOR="$MIN_MAJOR" python3 -c '
import json, os, re, sys

minimum = int(os.environ["MIN_MAJOR"])
best = None
for runtime in json.load(sys.stdin)["runtimes"]:
    if not runtime.get("isAvailable"):
        continue
    match = re.search(r"iOS-(\d+)-(\d+)", runtime.get("identifier", ""))
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if version[0] >= minimum and (best is None or version > best[0]):
        best = (version, runtime["identifier"])

if best is None:
    sys.exit("no available iOS runtime at or above the minimum")
print(best[1])
')

# Pick a device type the runtime actually supports rather than guessing a name.
device_type=$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
types = json.load(sys.stdin)["devicetypes"]
iphones = [t for t in types if "iPhone" in t.get("name", "")]
if not iphones:
    sys.exit("no iPhone device types available")
print(iphones[-1]["identifier"])
')

xcrun simctl create "tokino-ci" "$device_type" "$runtime" >/dev/null
find_udid
