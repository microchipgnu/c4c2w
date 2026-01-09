#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# c4c2w entrypoint - Convert containers to WASM using container2wasm
# ─────────────────────────────────────────────────────────────────────────────

CONFIG="${CONFIG:-/work/config.yaml}"
OUTDIR="${OUTDIR:-/out}"
WASI_SPLIT_MB="${WASI_SPLIT_MB:-50}"
C2W_EXTRA_FLAGS="${C2W_EXTRA_FLAGS:-}"

mkdir -p "$OUTDIR"

# ─────────────────────────────────────────────────────────────────────────────
# Start Docker daemon (DinD image doesn't auto-start unless using default entrypoint)
# ─────────────────────────────────────────────────────────────────────────────
echo "starting dockerd..."
dockerd --host=unix:///var/run/docker.sock &
DOCKERD_PID=$!

cleanup() {
    echo "stopping dockerd..."
    kill "$DOCKERD_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for docker to be ready
until docker info >/dev/null 2>&1; do
    echo "waiting for docker..."
    sleep 0.5
done

echo "docker is ready"

# ─────────────────────────────────────────────────────────────────────────────
# Set up QEMU for cross-platform builds (needed for amd64 builds on arm64 hosts)
# ─────────────────────────────────────────────────────────────────────────────
echo "setting up multiarch support (QEMU)..."
docker run --rm --privileged tonistiigi/binfmt --install all 2>/dev/null || echo "  (binfmt setup skipped or failed)"
echo "multiarch ready"

echo "using config: $CONFIG"
echo "output dir: $OUTDIR"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Generate manifest.json for an output
# ─────────────────────────────────────────────────────────────────────────────
generate_manifest() {
    local name="$1"
    local arch="$2"
    local mode="$3"
    local out_path="$4"
    local manifest_file="${out_path}/manifest.json"
    
    local files_json="[]"
    local total_size=0
    
    if [[ "$mode" == "emscripten" ]]; then
        # List all files in the output directory
        files_json=$(find "$out_path" -type f ! -name "manifest.json" -exec sh -c '
            for f; do
                size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
                sha=$(sha256sum "$f" 2>/dev/null | cut -d" " -f1 || shasum -a 256 "$f" | cut -d" " -f1)
                name=$(basename "$f")
                printf "{\"name\":\"%s\",\"size\":%s,\"sha256\":\"%s\"}\n" "$name" "$size" "$sha"
            done
        ' sh {} + | jq -s '.')
    else
        # List chunk files for WASI split output
        files_json=$(find "$out_path" -type f -name "part-*" | sort | while read -r f; do
            size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
            sha=$(sha256sum "$f" 2>/dev/null | cut -d" " -f1 || shasum -a 256 "$f" | cut -d" " -f1)
            fname=$(basename "$f")
            printf '{"name":"%s","size":%s,"sha256":"%s"}\n' "$fname" "$size" "$sha"
        done | jq -s '.')
    fi
    
    total_size=$(echo "$files_json" | jq '[.[].size] | add // 0')
    
    jq -n \
        --arg name "$name" \
        --arg arch "$arch" \
        --arg mode "$mode" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson total_size "$total_size" \
        --argjson files "$files_json" \
        '{
            name: $name,
            arch: $arch,
            mode: $mode,
            created: $created,
            total_size: $total_size,
            files: $files
        }' > "$manifest_file"
    
    echo "  manifest: $manifest_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Generate reassemble script for split WASI files
# ─────────────────────────────────────────────────────────────────────────────
generate_reassemble_script() {
    local name="$1"
    local out_path="$2"
    
    cat > "${out_path}/reassemble.sh" << 'REASSEMBLE_EOF'
#!/usr/bin/env bash
# Reassemble split WASM chunks into a single .wasm file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-output.wasm}"

echo "Reassembling chunks into $OUTPUT..."

# Find and sort part files, then concatenate
cat "$SCRIPT_DIR"/part-* > "$OUTPUT"

# Verify with manifest if available
if [[ -f "$SCRIPT_DIR/manifest.json" ]]; then
    expected_size=$(jq '.total_size' "$SCRIPT_DIR/manifest.json")
    actual_size=$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT")
    
    if [[ "$expected_size" -eq "$actual_size" ]]; then
        echo "✓ Size verified: $actual_size bytes"
    else
        echo "⚠ Size mismatch: expected $expected_size, got $actual_size"
        exit 1
    fi
fi

echo "Done: $OUTPUT"
REASSEMBLE_EOF

    chmod +x "${out_path}/reassemble.sh"
    echo "  reassemble script: ${out_path}/reassemble.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Process each container from config
# ─────────────────────────────────────────────────────────────────────────────
containers_json="$(yq -o=json '.containers' "$CONFIG")"
container_count=$(echo "$containers_json" | jq 'length')

echo "found $container_count container(s) to convert"
echo ""

echo "$containers_json" | jq -c '.[]' | while read -r c; do
    name="$(echo "$c" | jq -r '.name')"
    arch="$(echo "$c" | jq -r '.arch // "amd64"')"
    mode="$(echo "$c" | jq -r '.mode // .target // "wasi"')"  # compat with old "target" key
    image="$(echo "$c" | jq -r '.image // empty')"
    dockerfile="$(echo "$c" | jq -r '.dockerfile // empty')"
    split_mb="$(echo "$c" | jq -r '.output.split_mb // 50')"
    extra_flags="$(echo "$c" | jq -r '.c2w.extra_flags // empty')"
    network_enabled="$(echo "$c" | jq -r '.network // false')"
    
    # Merge container-specific flags with global flags
    all_flags="${C2W_EXTRA_FLAGS} ${extra_flags}"
    
    # Note: Networking in container2wasm is handled at runtime via c2w-net proxy,
    # not at build time. The 'network' config option is informational only.
    
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "▶ $name"
    if [[ "$network_enabled" == "true" ]]; then
        echo "  arch: $arch | mode: $mode | network: enabled"
    else
        echo "  arch: $arch | mode: $mode | network: disabled"
    fi
    echo "═══════════════════════════════════════════════════════════════════════════"
    
    # Prepare source image tag
    local_tag="c4c2w/${name}:local"
    src=""
    
    if [[ -n "$dockerfile" ]]; then
        echo "  building dockerfile -> $local_tag"
        echo "$dockerfile" | docker buildx build \
            --progress=plain \
            --load \
            --platform="linux/${arch}" \
            -t "$local_tag" \
            -
        src="$local_tag"
    elif [[ -n "$image" ]]; then
        echo "  pulling image: $image"
        docker pull --platform="linux/${arch}" "$image"
        src="$image"
    else
        echo "  ERROR: $name has neither 'image' nor 'dockerfile' defined"
        exit 1
    fi
    
    echo "  source: $src"
    echo "  converting..."
    
    if [[ "$mode" == "emscripten" ]]; then
        # Emscripten mode: emits a folder with wasm + js artifacts
        out_path="${OUTDIR}/${name}"
        mkdir -p "$out_path"
        
        # shellcheck disable=SC2086
        c2w --to-js --target-arch="$arch" $all_flags "$src" "$out_path/"
        
        generate_manifest "$name" "$arch" "$mode" "$out_path"
        echo "  output: $out_path/"
        
    else
        # WASI mode: emits a single wasm, then optionally split
        out_wasm="${OUTDIR}/${name}.wasm"
        out_path="${OUTDIR}/${name}"
        
        # shellcheck disable=SC2086
        c2w --target-arch="$arch" $all_flags "$src" "$out_wasm"
        
        # Split for GitHub-friendly chunks
        mkdir -p "$out_path"
        split -b "${split_mb}m" "$out_wasm" "${out_path}/part-"
        rm -f "$out_wasm"
        
        generate_manifest "$name" "$arch" "$mode" "$out_path"
        generate_reassemble_script "$name" "$out_path"
        echo "  output: ${out_path}/ (split into ${split_mb}MB chunks)"
    fi
    
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════════════"
echo "✓ All conversions finished"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "Output directory contents:"
ls -la "$OUTDIR"

