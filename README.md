# c4c2w - Container for Container2Wasm

A Docker-in-Docker container that converts container images to WebAssembly using [container2wasm](https://github.com/ktock/container2wasm).

## Features

- **Docker-in-Docker base**: Uses official `docker:27-dind` image (no openrc hacks)
- **Modern c2w**: container2wasm v0.8.3 with latest fixes
- **Clean outputs**: Artifacts written directly to mounted `/out` directory
- **Build matrix**: YAML config supports multiple containers with different architectures and modes
- **Split output**: Large WASM files automatically split into GitHub-friendly chunks
- **Manifest generation**: Each output includes `manifest.json` with checksums
- **Reassemble script**: WASI outputs include a script to reconstruct the full WASM

## Quick Start

```bash
# Clone and enter the repo
cd c4c2w

# Edit config.yaml to define your containers
vim config.yaml

# Run the conversion
./run.sh
```

Outputs will be in `./out/`:

```
out/
├── amd64-alpine-bun-wasi/
│   ├── part-aa
│   ├── part-ab
│   ├── ...
│   ├── manifest.json
│   └── reassemble.sh
└── amd64-busybox-wasi/
    ├── part-aa
    ├── manifest.json
    └── reassemble.sh
```

## Configuration

### `config.yaml`

```yaml
containers:
  # From inline Dockerfile
  - name: my-app-wasi
    arch: amd64
    mode: wasi
    output:
      split_mb: 50
    dockerfile: |
      FROM alpine:3.20
      RUN apk add --no-cache curl
      CMD ["sh"]

  # From Docker Hub image
  - name: busybox-wasi
    arch: amd64
    mode: wasi
    image: busybox:latest

  # Emscripten mode (for browser with JS)
  - name: alpine-browser
    arch: amd64
    mode: emscripten
    image: alpine:3.20

  # With networking enabled
  - name: my-networked-app
    arch: amd64
    mode: wasi
    network: true
    image: alpine:3.20
```

### Config Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Unique identifier for output |
| `arch` | string | `amd64` | Target architecture (`amd64`, `arm64`) |
| `mode` | string | `wasi` | Conversion mode (`wasi`, `emscripten`) |
| `image` | string | - | Source image from registry |
| `dockerfile` | string | - | Inline Dockerfile content |
| `network` | boolean | `false` | Enable networking support (adds `--net=socket`) |
| `output.split_mb` | number | `50` | Split WASM into chunks (MB) |
| `c2w.extra_flags` | string | - | Additional c2w flags |

## Output Modes

### WASI Mode (`mode: wasi`)

Produces a single WASM file, automatically split into chunks:

```
out/<name>/
├── part-aa          # First chunk
├── part-ab          # Second chunk
├── ...
├── manifest.json    # Metadata + checksums
└── reassemble.sh    # Script to reconstruct WASM
```

To reassemble:

```bash
cd out/my-app-wasi
./reassemble.sh output.wasm

# Or manually:
cat part-* > output.wasm
```

### Emscripten Mode (`mode: emscripten`)

Produces browser-ready artifacts:

```
out/<name>/
├── out.wasm
├── out.js
├── worker.js        # (if applicable)
└── manifest.json
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE_NAME` | `c4c2w:latest` | Docker image name to build |
| `CONFIG_FILE` | `./config.yaml` | Path to config file |
| `OUTPUT_DIR` | `./out` | Output directory |
| `WASI_SPLIT_MB` | `50` | Default split size (can override in config) |
| `C2W_EXTRA_FLAGS` | - | Global extra flags for all c2w calls |

## Advanced Usage

### Custom config file

```bash
CONFIG_FILE=./my-config.yaml ./run.sh
```

### Custom output directory

```bash
OUTPUT_DIR=/mnt/artifacts ./run.sh
```

### Run container directly

```bash
docker build -t c4c2w:latest .

docker run --rm --privileged \
  -v $(pwd)/out:/out \
  -v /var/lib/docker \
  -v $(pwd)/custom-config.yaml:/work/config.yaml:ro \
  c4c2w:latest
```

### Pass extra c2w flags

```bash
docker run --rm --privileged \
  -v $(pwd)/out:/out \
  -v /var/lib/docker \
  -e C2W_EXTRA_FLAGS="--debug" \
  c4c2w:latest
```

## Networking

When `network: true` is set for a container, the WASM output will include networking support via the `--net=socket` flag. This enables the container to make network connections when run with a compatible runtime.

### Running with Network Support

Network-enabled WASM containers require the `c2w-net` proxy to bridge network traffic:

```bash
# Terminal 1: Start the network proxy
c2w-net --listen=0.0.0.0:8080

# Terminal 2: Run the WASM with network mapping
cd out/my-networked-app
./reassemble.sh app.wasm
wasmtime --tcplisten=127.0.0.1:8080 app.wasm
```

For browser-based networking (emscripten mode with networking), you'll need to configure a WebSocket proxy. See the [container2wasm networking examples](https://github.com/container2wasm/container2wasm/tree/main/examples/networking) for detailed setup instructions.

## Running WASM Output

### WASI (with wasmtime)

```bash
# Reassemble first
cd out/my-app-wasi
./reassemble.sh my-app.wasm

# Run with wasmtime
wasmtime my-app.wasm
```

### Browser (emscripten)

The emscripten output includes JS glue code. Serve the output directory:

```bash
cd out/alpine-browser
npx serve .
```

Then open `http://localhost:3000` (you'll need an HTML harness - see container2wasm examples).

## GitHub Actions CI/CD

This repository includes workflows for validating and releasing WASM containers.

### Workflows

| Workflow | Trigger | Description |
|----------|---------|-------------|
| **Release** | Manual | Builds containers and creates a GitHub release |
| **Validate** | PRs, push | Quick syntax validation of config files |

### Creating a Release

Releases are created manually to give you full control:

1. Go to **Actions** → **Release WASM Containers**
2. Click **Run workflow**
3. Enter a release tag (e.g., `v1.0.0`)
4. Optionally mark as pre-release
5. Click **Run workflow**

The workflow will:
- Build the c4c2w Docker image
- Convert all containers in `config.yaml` to WASM
- Upload artifacts to GitHub Actions
- Create a GitHub Release with all files

### Downloading Releases

Get WASM containers from [Releases](../../releases):

```bash
# Download a specific release
gh release download v1.0.0 -D ./wasm

# Reassemble WASI containers
cd wasm/my-app-wasi
./reassemble.sh app.wasm
wasmtime app.wasm
```

## Requirements

- Docker with `--privileged` support
- ~10GB disk space for Docker daemon state
- Internet access to pull base images

## How It Works

1. **Build**: Creates a Docker-in-Docker container with c2w installed
2. **Start**: Launches dockerd inside the container with fuse-overlayfs
3. **Process**: For each entry in `config.yaml`:
   - Builds Dockerfile or pulls image
   - Runs `c2w` to convert to WASM
   - Splits output and generates manifest
4. **Output**: Writes all artifacts to `/out` (mounted from host)

## Troubleshooting

### "permission denied" errors

Make sure you're running with `--privileged`:

```bash
docker run --rm --privileged ...
```

### Docker daemon won't start

Check if fuse-overlayfs is available. The container configures Docker to use it automatically.

### Conversion takes forever

container2wasm conversion can be slow for large images. Consider:
- Using smaller base images (Alpine vs Ubuntu)
- Building minimal images with only required dependencies
- Increasing available memory

## License

MIT

