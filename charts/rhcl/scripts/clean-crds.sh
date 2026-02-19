#!/bin/bash
#
# Clean runtime metadata from CRD files
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRDS_DIR="$(dirname "$SCRIPT_DIR")/crds"

echo "Cleaning runtime metadata from CRDs..."
echo ""

# Find all CRD YAML files and iterate safely using null-delimited output
CRD_COUNT=0
while IFS= read -r -d '' crd_file; do
  CRD_COUNT=$((CRD_COUNT + 1))
  echo "Processing: $(basename "$crd_file")"

  # Create temp file
  temp_file="${crd_file}.tmp"

  # Remove runtime metadata lines and empty status blocks using awk
  awk '
    # Skip runtime metadata fields
    /^  creationTimestamp:/ { next }
    /^  generation:/ { next }
    /^  resourceVersion:/ { next }
    /^  uid:/ { next }

    # Skip OLM annotations/labels
    /operatorframework.io\/installed-alongside/ { next }
    /olm.managed:/ { next }
    /operators.coreos.com/ { next }

    # Track if we are in status block
    /^status:$/ { in_status = 1; next }

    # If in status block, skip until we hit a top-level key
    in_status == 1 {
      if (/^[a-z]/) {
        in_status = 0
      } else {
        next
      }
    }

    # Print all other lines
    { print }
  ' "$crd_file" > "$temp_file"

  # Replace original file
  mv "$temp_file" "$crd_file"
done < <(find "$CRDS_DIR" -name "*.yaml" -type f -print0)

echo ""
echo "✅ Cleaned $CRD_COUNT CRD files"
