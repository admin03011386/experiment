# SimEnc Project - AI Coding Assistant Instructions

## Project Overview
SimEnc is a similarity-preserving encryption system for Docker image deduplication, published at USENIX ATC 2024. The project is research-oriented and combines:
- **Modified Docker Distribution Registry** (Go): Core storage and deduplication engine
- **ML Training Pipeline** (Python/PyTorch): Semantic hash model for similarity detection  
- **Evaluation Tools** (Python/Jupyter): Trace replay and deduplication ratio analysis

## Architecture & Key Components

### Directory Structure
```
03/docker/distribution/     # Production registry with SimEnc modifications
03/SimEnc-main/
├── distribution/           # Alternative SimEnc distribution fork
├── partial/                # C++ gzip partial decode/encode tools (libz_j)
├── training/               # ML model training pipeline
│   ├── clustering/         # coarse/fine label generation (xdelta3-based)
│   └── training/           # PyTorch model training scripts
├── inference/              # Jupyter notebooks for deduplication analysis
├── warmup_and_run/         # Trace replay client/server
└── workload/               # Docker image crawler and trace mapping
```

### Critical Data Flow
1. **Push**: Blob → partial decode → 512KiB chunks → semantic hash → cluster-based dedup storage
2. **Pull**: Cluster lookup → chunk assembly → partial encode → gzip blob reconstruction
3. Core implementation: [registry/storage/blobserver.go](03/docker/distribution/registry/storage/blobserver.go) - `constructFromUnpackFiles()`, `packAllFilesToPartial()`

## Build Commands

### Go Registry (from `03/docker/distribution/` or `03/SimEnc-main/distribution/`)
```bash
make                        # Build registry binary to ./bin/registry
go build -mod=vendor ./cmd/registry  # Direct build with vendor deps
```

### Partial Tools (from `03/SimEnc-main/partial/`)
```bash
cd libz_j && make           # Build libz_j.a static library
g++ decode_docker.cpp -o decode -L. libz_j/libz_j.a
g++ encode_docker.cpp -o encode -L. libz_j/libz_j.a
```

### Training Tools (from `03/SimEnc-main/training/clustering/`)
```bash
g++ ../xdelta3/xdelta3.c ../xxhash.c ../lz4.c coarse_xdelta3.cpp -o coarse -lpthread
g++ ../xdelta3/xdelta3.c ../xxhash.c ../lz4.c fine_xdelta3.cpp -o fine -lpthread
```

## Running the System

### 1. Start Registry
```bash
cd ./bin && ./registry serve config.yaml
```
Config location: [03/docker/distribution/bin/config.yaml](03/docker/distribution/bin/config.yaml)

### 2. Warmup Phase (push layers)
```bash
python3 warmup_run.py -c warmup -i config.yaml
```

### 3. Run Phase (get layers)
```bash
python3 client.py -i 127.0.0.1 -p 8081
python3 warmup_run.py -c run -i config.yaml
```

## Code Conventions

### Go Registry Code
- Uses `github.com/docker/distribution` module with vendor dependencies (`-mod=vendor`)
- Custom dedup logic prefixed with `j_` (e.g., `j_dedup.go`, `j_build_fri()`)
- Redis cluster for caching: configured via `redis:` section in config.yaml
- Compression via `klauspost/pgzip` and `pierrec/lz4`

### Python ML Code
- PyTorch models expect 512KiB binary chunks normalized to `(byte-128)/128`
- Two-stage training: backbone model (`train_baseline.py`) → hash network (`train_hashlayer_gh.py`)
- Hash size typically 128 bits, using GreedyHash loss function
- Pre-trained models available via Google Drive (see README)

### Notebook Workflow
- [inference/SimEnc_partial.ipynb](03/SimEnc-main/inference/SimEnc_partial.ipynb): Main inference pipeline
- Uses `fastcdc` CLI tool for content-defined chunking analysis
- DBSCAN/KMeans clustering on Hamming distance of semantic hashes

## External Dependencies
- **Redis Cluster**: Required for production caching (ports 6379-6384 typical)
- **dxf Python library**: Docker registry client for trace replay
- **fastcdc**: CLI tool for chunking analysis in notebooks
- **Pre-trained models**: Download from Google Drive link in README

## Important Patterns
- Partial decode/encode preserves gzip headers and CRC, only transforms deflate stream
- Layer recipes stored in Redis with TTL for cache invalidation
- Concurrent blob processing uses `panjf2000/ants` goroutine pool
- Trace data format: JSON with `repo_name`, `uri`, `size`, `delay` fields
