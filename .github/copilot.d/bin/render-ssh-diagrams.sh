#!/usr/bin/env bash
# @codebase
# Export SSH keys architecture Mermaid diagrams to SVG images
# Requires: mermaid-cli available via npm
# Usage: ./render-ssh-diagrams.sh [output-dir] [theme] [--install]

set -euo pipefail

install_mermaid=false
if [[ "${1:-}" == "--install" ]]; then
    install_mermaid=true
    shift || true
fi

# Determine script directory to find docs relative to repo root
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

output_dir="${1:-.github/copilot.d/ssh-diagrams}"
theme="${2:-dark}"

# Make paths absolute if they're relative
if [[ ! "$output_dir" = /* ]]; then
    output_dir="$repo_root/$output_dir"
fi

diagram_file="$repo_root/docs/ssh-keys-diagrams.adoc"

# Check if diagram file exists
if [[ ! -f "$diagram_file" ]]; then
    echo "Error: $diagram_file not found" >&2
    exit 1
fi

# Install mermaid-cli if needed
if ! command -v mmdc >/dev/null 2>&1; then
    if ! command -v npx >/dev/null 2>&1; then
        echo "Error: Neither mmdc nor npx found."
        echo ""
        echo "Installation options:"
        echo "  Option 1: Use Flox environment (asciidoc has nodejs/npm):"
        echo "    flox activate -d <fleet-path>/flox/asciidoc -- $0"
        echo ""
        echo "  Option 2: Install npm/node locally"
        echo ""
        echo "  Option 3: Install globally:"
        echo "    npm install -g @mermaid-js/mermaid-cli"
        exit 1
    fi
    # Use npx if mmdc not found
    MMDC_CMD="npx @mermaid-js/mermaid-cli"
else
    MMDC_CMD="mmdc"
fi

mkdir -p "$output_dir"

echo "Rendering SSH diagrams to SVG..."
echo "  Input:  $diagram_file"
echo "  Output: $output_dir/"
echo "  Theme:  $theme"
echo

# Extract and render each diagram
diagrams=(
    "C2: Container Architecture"
    "C3: Pipeline Architecture (4 Stages)"
    "Data Flow: Profile YAML through Pipeline"
    "Sequence: home-manager switch → SSH Ready"
    "Key Decision Points in Pipeline"
    "Nix Module Wiring Diagram"
    "Runtime File Structure Evolution"
)

for diagram_title in "${diagrams[@]}"; do
    # Convert title to filename
    filename=$(echo "$diagram_title" | \
               sed 's/^[^:]*: //; s/ /-/g; s/(//g; s/)//g; s/→/to/; s/\.//g' | \
               tr '[:upper:]' '[:lower:]')
    
    output_file="$output_dir/${filename}.svg"
    
    # Extract mermaid code block for this diagram from AsciiDoc format
    # Uses a simple state machine: find heading -> [mermaid] -> ---- (start) -> ---- (end)
    awk -v target_diagram="== $diagram_title" '
        # Look for the target diagram heading
        $0 == target_diagram { in_section=1; next }
        # Stop when we hit another == heading
        $0 ~ /^== / && in_section && NR > NR_start { exit }
        # Mark start of mermaid block
        in_section && $0 == "[mermaid]" { in_mermaid=1; next }
        # Find opening ----
        in_mermaid && $0 == "----" && !NR_start { NR_start=NR; next }
        # Find closing ---- and exit
        in_mermaid && NR_start && $0 == "----" && NR > NR_start { exit }
        # Output code lines (after opening ----, before closing ----)
        NR_start && in_mermaid && NR > NR_start { print }
    ' "$diagram_file" > "/tmp/mermaid_${filename}.mmd"
    
    if [[ -s "/tmp/mermaid_${filename}.mmd" ]]; then
        echo "  ✓ Rendering $(echo "$diagram_title" | cut -c1-50)..."
        $MMDC_CMD -i "/tmp/mermaid_${filename}.mmd" \
             -o "$output_file" \
             -t "$theme" \
             --outputFormat svg \
             2>/dev/null || {
            echo "    ⚠ Warning: Failed to render $(basename "$output_file")"
        }
    else
        echo "  ⚠ Skipped $(echo "$diagram_title" | cut -c1-50) (extract failed)"
    fi
    
    rm -f "/tmp/mermaid_${filename}.mmd"
done

echo
echo "✓ Rendering complete!"
echo "  Output directory: $output_dir/"
ls -lh "$output_dir"/*.svg 2>/dev/null | awk '{print "    • " $9 " (" $5 ")"}'
echo
echo "View diagrams:"
echo "  • Open in preview: open $output_dir/"
echo "  • View in browser: file://$(cd "$output_dir" && pwd)/"
