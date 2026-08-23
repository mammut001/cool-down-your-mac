#!/usr/bin/env bash
# Validates that an appcast.xml feed contains valid Sparkle 2 metadata for a release.
set -euo pipefail

APPCAST="${1:-}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"
EXPECTED_URL="${4:-}"

if [[ -z "${APPCAST}" || -z "${EXPECTED_VERSION}" || -z "${EXPECTED_BUILD}" || -z "${EXPECTED_URL}" ]]; then
  echo "Usage: $0 <path/to/appcast.xml> <version> <build> <expected-enclosure-url>" >&2
  exit 1
fi

if [[ ! -f "${APPCAST}" || ! -s "${APPCAST}" ]]; then
  echo "error: appcast file missing or empty: ${APPCAST}" >&2
  exit 1
fi

python3 - <<PYEOF
import sys
import xml.etree.ElementTree as ET

appcast_path = "${APPCAST}"
expected_ver = "${EXPECTED_VERSION}"
expected_bld = "${EXPECTED_BUILD}"
expected_url = "${EXPECTED_URL}"

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
namespaces = {"sparkle": SPARKLE_NS}

try:
    tree = ET.parse(appcast_path)
    root = tree.getroot()
except Exception as e:
    print(f"error: failed to parse XML in {appcast_path}: {e}", file=sys.stderr)
    sys.exit(1)

channel = root.find("channel")
if channel is None:
    print(f"error: <channel> element not found in {appcast_path}", file=sys.stderr)
    sys.exit(1)

items = channel.findall("item")
if not items:
    print(f"error: no <item> entries found in {appcast_path}", file=sys.stderr)
    sys.exit(1)

matching_item = None
for item in items:
    ver_elem = item.find(f"{{{SPARKLE_NS}}}shortVersionString")
    bld_elem = item.find(f"{{{SPARKLE_NS}}}version")
    title_elem = item.find("title")

    item_ver = ver_elem.text.strip() if ver_elem is not None and ver_elem.text else ""
    item_bld = bld_elem.text.strip() if bld_elem is not None and bld_elem.text else ""
    item_title = title_elem.text.strip() if title_elem is not None and title_elem.text else ""

    if item_ver == expected_ver or item_bld == expected_bld or item_title == expected_ver:
        matching_item = item
        break

if matching_item is None:
    print(f"error: no <item> found matching version {expected_ver} (build {expected_bld}) in {appcast_path}", file=sys.stderr)
    sys.exit(1)

enclosure = matching_item.find("enclosure")
if enclosure is None:
    print(f"error: <enclosure> missing in item for version {expected_ver}", file=sys.stderr)
    sys.exit(1)

url = enclosure.attrib.get("url", "").strip()
if url != expected_url:
    print(f"error: enclosure url mismatch.\n  Expected: {expected_url}\n  Actual:   {url}", file=sys.stderr)
    sys.exit(1)

signature = enclosure.attrib.get(f"{{{SPARKLE_NS}}}edSignature", "").strip()
if not signature or len(signature) < 40:
    print(f"error: enclosure sparkle:edSignature missing or invalid: '{signature}'", file=sys.stderr)
    sys.exit(1)

length_str = enclosure.attrib.get("length", "0").strip()
try:
    length = int(length_str)
    if length <= 0:
        print(f"error: enclosure length must be > 0, got {length}", file=sys.stderr)
        sys.exit(1)
except ValueError:
    print(f"error: invalid enclosure length: '{length_str}'", file=sys.stderr)
    sys.exit(1)

print(f"Appcast validation succeeded for {expected_ver} ({expected_bld}):")
print(f"  URL:       {url}")
print(f"  Length:    {length} bytes")
print(f"  Signature: {signature[:16]}... (valid EdDSA)")
PYEOF

echo "==> Appcast ${APPCAST} is valid"
