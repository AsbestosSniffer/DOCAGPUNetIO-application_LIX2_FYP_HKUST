# Build & Server Setup Guide

This document covers everything needed to build and run the project on the HKUST server.

---

## 1. Server Access

```bash
ssh lix2@lxcpu1.cse.ust.hk
# Password authentication (ED25519 key fingerprint: SHA256:hTyj6Fm52MkBSCjLVNixCKOBVzVf1kwL6eYRBs1EQLo)
```

The server is Ubuntu 24.04.4 LTS with kernel 6.17.0-14-generic.

---

## 2. Server Environment (Verified)

These were verified on 2026-03-12:

| Component | Version | Status |
|-----------|---------|--------|
| OS | Ubuntu 24.04.4 LTS | Working |
| CUDA Toolkit | 13.1 (V13.1.115) | Working |
| NVIDIA Driver | 590.48.01 | Working |
| GPU 0 | NVIDIA A2 (16GB) | **13.3GB used by VLLM** |
| GPU 1 | NVIDIA A2 (16GB) | **Free (~15.2GB available)** |
| BlueField-3 | MT43244 (ConnectX-7) | Detected (2 ports) |
| DOCA SDK | /opt/mellanox/doca/ | Installed |
| GCC/G++ | System default | Working |
| Node.js | 18.19.1 (for wscat) | Installed |
| Binance API | api.binance.com reachable | Confirmed |
| sudo | Available | Yes |

### GPU Memory Status

```
GPU 0:  13817MiB / 15356MiB  (VLLM + qdrant running)
GPU 1:    112MiB / 15356MiB  (only Xorg + qdrant, ~15.2GB free)
```

**All development and benchmarking targets GPU 1.** The code calls `cudaSetDevice(1)` explicitly. If VLLM is stopped on GPU 0, you can switch by changing this call or passing an environment variable.

### PCIe Topology

```
         GPU0    GPU1    NIC0    NIC1
GPU0      X      PHB     NODE    NODE
GPU1     PHB      X      NODE    NODE
NIC0     NODE    NODE     X      PIX
NIC1     NODE    NODE    PIX      X
```

- GPU0 and GPU1 share a PCIe Host Bridge (PHB) — good for GPU-to-GPU transfers
- GPUs and NICs are on the same NUMA node but different PCIe bridges (NODE) — workable for GPUDirect, not ideal
- Both NICs share a single PCIe bridge (PIX) — bonding possible

---

## 3. Clone and Build

### Step 1: Get the Code

```bash
cd ~
git clone <your-repo-url> DOCAGPUNetIO-application_LIX2_FYP_HKUST
cd DOCAGPUNetIO-application_LIX2_FYP_HKUST
git checkout development
```

### Step 2: Build Systems 1 + 2 + Tools

```bash
make all
```

This builds:
- `cpu_baseline/cpu_baseline` — System 1 (CPU baseline, g++)
- `gpu_rdma/gpu_rdma_pipeline` — System 2 (GPU RDMA, nvcc)
- `mini_trader/csv_to_bin_converter` — CSV-to-binary converter (g++)
- `mini_trader/udp_replayer` — UDP packet replayer (g++)

**Expected output:**
```
g++ -O3 -std=c++17 -Wall -Icommon cpu_baseline/cpu_pipeline.cpp -o cpu_baseline/cpu_baseline -lpthread
nvcc -O3 -std=c++17 -arch=sm_86 -Icommon gpu_rdma/src/gpu_pipeline.cu -o gpu_rdma/gpu_rdma_pipeline
g++ -O3 -std=c++17 -Wall -Imini_trader/include mini_trader/src/csv_to_bin_converter.cpp -o mini_trader/csv_to_bin_converter
g++ -O3 -std=c++17 -Wall -Imini_trader/include mini_trader/src/udp_replayer.cpp -o mini_trader/udp_replayer
```

### Step 3: Build System 3 (DOCA GPUNetIO) — Optional

System 3 requires the DOCA SDK. Only build this on the server:

```bash
cd gpu_doca
meson setup build
ninja -C build
```

If you get errors about missing DOCA headers, ensure the SDK path is set:

```bash
export PKG_CONFIG_PATH=/opt/mellanox/doca/lib/pkgconfig:$PKG_CONFIG_PATH
export LD_LIBRARY_PATH=/opt/mellanox/doca/lib:$LD_LIBRARY_PATH
```

Or source the environment file:

```bash
source setEnv.csh
```

### Step 4: Build Legacy Tools (Optional)

To build the original mini_trader pipeline separately:

```bash
cd mini_trader
make all
```

---

## 4. Build Targets Reference

| Command | What it builds | Compiler |
|---------|---------------|----------|
| `make cpu` | cpu_baseline/cpu_baseline | g++ |
| `make gpu` | gpu_rdma/gpu_rdma_pipeline | nvcc (sm_86) |
| `make tools` | csv_to_bin_converter + udp_replayer | g++ |
| `make all` | cpu + gpu + tools | Both |
| `make legacy_gpu` | mini_trader/gpu_staging | nvcc |
| `make legacy_receiver` | mini_trader/udp_receiver | nvcc |
| `make doca` | (instructions only -- use meson) | meson/ninja |
| `make bench` | Build all + run quick benchmarks | Both |
| `make bench-full` | Build all + run full benchmarks | Both |
| `make clean` | Remove all binaries | N/A |

### Changing GPU Architecture

Default is sm_86 (A2 Ampere). Override with:

```bash
make gpu CUDA_ARCH=80    # For A100
make gpu CUDA_ARCH=89    # For L4/L40
make gpu CUDA_ARCH=90    # For H100
```

---

## 5. Dependencies

### Required (always)

| Package | Purpose | Check |
|---------|---------|-------|
| CUDA Toolkit 12+ | nvcc compiler, CUDA runtime | `nvcc --version` |
| GCC/G++ (C++17) | CPU baseline, tools | `g++ --version` |
| GNU Make | Build system | `make --version` |
| bash | Scripts | `bash --version` |

### Required for Real Data Testing

| Package | Purpose | Check |
|---------|---------|-------|
| curl | Binance data download | `curl --version` |
| unzip | Extract downloaded archives | `unzip -v` |

### Required for Live WebSocket Feed (--live mode)

| Package | Purpose | Install |
|---------|---------|---------|
| libwebsockets-dev | WebSocket client (TLS/WSS) | `sudo apt install libwebsockets-dev` |
| nlohmann-json3-dev | JSON parsing (Binance messages) | `sudo apt install nlohmann-json3-dev` |
| libssl-dev | TLS for WSS connections | `sudo apt install libssl-dev` |

Build live variants with: `make live`

### Required for System 3 (DOCA)

| Package | Purpose | Check |
|---------|---------|-------|
| DOCA SDK | GPUNetIO headers and libraries | `ls /opt/mellanox/doca/` |
| meson | DOCA build system | `meson --version` |
| ninja | Build backend | `ninja --version` |

### Optional

| Package | Purpose | Check |
|---------|---------|-------|
| python3 + matplotlib | Benchmark chart generation | `python3 -c "import matplotlib"` |
| nsys (Nsight Systems) | GPU profiling | `nsys --version` |
| wscat (node-ws) | WebSocket testing | `wscat --version` |

### Installing Missing Dependencies

```bash
# meson + ninja (for DOCA build)
pip3 install meson ninja

# matplotlib (for benchmark charts)
pip3 install matplotlib

# wscat (already installed on server)
sudo apt install node-ws
```

---

## 6. Verifying the Build

After `make all`, run these smoke tests:

```bash
# Test 1: CPU baseline with synthetic data (should take < 5 seconds)
./cpu_baseline/cpu_baseline 100000 1000
# Expected: prints latency stats, throughput, PnL summary

# Test 2: GPU pipeline with synthetic data (should take < 5 seconds)
./gpu_rdma/gpu_rdma_pipeline 100000 1000
# Expected: prints latency stats, throughput, PnL summary

# Test 3: Verify GPU 1 is being used
nvidia-smi
# GPU 1 memory should increase slightly during test
```

If Test 2 fails with CUDA errors:
1. Check `nvidia-smi` — is GPU 1 available?
2. Try `CUDA_VISIBLE_DEVICES=1 ./gpu_rdma/gpu_rdma_pipeline 100000 1000`
3. Check driver: `nvidia-smi` should show driver 590.48.01 and CUDA 13.1

---

## 7. Profiling with Nsight Systems

For GPU kernel profiling:

```bash
nsys profile --stats=true ./gpu_rdma/gpu_rdma_pipeline 1000000 10000
```

This generates a `.nsys-rep` file you can open in Nsight Systems GUI (Windows/Linux) for timeline analysis of H2D, kernel, and D2H operations.

---

## 8. Troubleshooting

| Problem | Solution |
|---------|----------|
| `nvcc: command not found` | Add CUDA to PATH: `export PATH=/usr/local/cuda/bin:$PATH` |
| `CUDA error: no CUDA-capable device` | Check `nvidia-smi`, ensure driver is loaded |
| `CUDA error: out of memory` | GPU 1 may be full; check with `nvidia-smi` |
| `make: *** No rule to make target` | Ensure you're in the repo root, not mini_trader/ |
| `cannot find -lpthread` | Install: `sudo apt install libc6-dev` |
| `DOCA headers not found` | Set `PKG_CONFIG_PATH` as shown in Step 3 |
| `meson: command not found` | Install: `pip3 install meson` |
| `Permission denied` running scripts | `chmod +x benchmark/run_benchmarks.sh mini_trader/binance_downloader.sh` |
| Binance download fails | University firewall may block data.binance.vision; try from a different network |
| `Address already in use (port 9999)` | `lsof -i :9999` and kill the process, or use a different port |
