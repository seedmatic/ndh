#!/usr/bin/env bash
# @codebase
# Export SSH keys architecture Mermaid diagrams to JPEG images
# Requires: mermaid-cli (npm install -g @mermaid-js/mermaid-cli)
# Usage: ./render-ssh-diagrams.sh [output-dir] [theme]

set -euo pipefail

output_dir="${1:-.github/copilot.d/ssh-diagrams}"
theme="${2:-dark}"
diagram_file="docs/ssh-keys-diagrams.adoc"

# Check if diagram file exists
if [[ ! -f "$diagram_file" ]]; then
    echo "Error: $diagram_file not found" >&2
    exit 1
fi

# Check if mermaid-cli is installed
if ! command -v mmdc >/dev/null 2>&1; then
    echo "Error: mermaid-cli not installed. Install with: npm install -g @mermaid-js/mermaid-cli" >&2
    exit 1
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
    "C3: Pipeline Architecture \(4 Stages\)"
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
    
    # Extract mermaid code block for this diagram
    # Find the heading, extract code block until next heading or EOF
    awk -v diagram="## $diagram_title" '
        $0 ~ diagram { found=1; next }
        found && /^```mermaid/ { in_code=1; next }
        found && in_code && /^```$/ { in_code=0; found=0 }
        found && in_code { print }
    ' "$diagram_file" > "/tmp/mermaid_${filename}.mmd"
    
    if [[ -s "/tmp/mermaid_${filename}.mmd" ]]; then
        echo "  ✓ Rendering $(echo "$diagram_title" | cut -c1-50)..."
        mmdc -i "/tmp/mermaid_${filename}.mmd" \
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
