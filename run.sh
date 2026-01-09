#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# c4c2w - Build and run the conversion container
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-c4c2w:latest}"
CONFIG_FILE="${CONFIG_FILE:-./config.yaml}"
OUTPUT_DIR="${OUTPUT_DIR:-./out}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  c4c2w - Container for Container2Wasm                                     ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed or not in PATH${NC}"
    exit 1
fi

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}Building image:${NC} $IMAGE_NAME"
docker build -t "$IMAGE_NAME" .

echo ""
echo -e "${GREEN}Creating output directory:${NC} $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo ""
echo -e "${GREEN}Running conversion container...${NC}"
echo "  Config: $CONFIG_FILE"
echo "  Output: $OUTPUT_DIR"
echo ""

# Run the container
# --privileged: Required for Docker-in-Docker
# -v $(pwd)/out:/out: Mount output directory
# -v /var/lib/docker: Keep Docker daemon state inside the container
# -v config.yaml: Use custom config if specified
docker run --rm --privileged \
    -v "$(realpath "$OUTPUT_DIR"):/out" \
    -v /var/lib/docker \
    -v "$(realpath "$CONFIG_FILE"):/work/config.yaml:ro" \
    "$IMAGE_NAME"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Conversion complete!                                                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Output artifacts:"
find "$OUTPUT_DIR" -type f -name "manifest.json" -exec sh -c '
    dir=$(dirname "$1")
    name=$(jq -r ".name" "$1")
    mode=$(jq -r ".mode" "$1")
    size=$(jq -r ".total_size" "$1")
    size_mb=$(echo "scale=2; $size / 1048576" | bc)
    echo "  📦 $name ($mode) - ${size_mb}MB"
' sh {} \;

