# ═══════════════════════════════════════════════════════════════════════
#  FYP Top-Level Makefile — DOCA GPUNetIO Trading System
# ═══════════════════════════════════════════════════════════════════════
#
# Standard targets (no WebSocket dependency):
#   make cpu        — Build System 1 (CPU baseline): synthetic, file, UDP modes
#   make gpu        — Build System 2 (GPU RDMA pipeline): synthetic, file, UDP modes
#   make tools      — Build converter + replayer (from mini_trader/)
#   make all        — Build cpu + gpu + tools
#
# Live WebSocket targets (requires libwebsockets + nlohmann-json):
#   make cpu-live   — Build CPU baseline with --live mode (Binance WebSocket)
#   make gpu-live   — Build GPU RDMA with --live mode (Binance WebSocket)
#   make ws-test    — Build standalone WebSocket test client
#   make live       — Build all live variants
#
# Other targets:
#   make doca       — Build System 3 (DOCA GPUNetIO) — requires DOCA SDK
#   make bench      — Run benchmark suite
#   make clean      — Remove all binaries
#
# GPU selection: defaults to GPU 1 (sm_86 for A2).
# Override with: make gpu CUDA_ARCH=86

NVCC      = nvcc
CXX       = g++
CXXFLAGS  = -O3 -std=c++17 -Wall
NVCCFLAGS = -O3 -std=c++17
CUDA_ARCH ?= 86

COMMON    = common

# WebSocket libraries (for live targets)
WS_LIBS   = -lwebsockets -lssl -lcrypto -lpthread
WS_FLAGS  = -DHAS_WEBSOCKETS

# ═══════════════════════════════════════════════════════════════════════
#  STANDARD BUILDS (no WebSocket dependency)
# ═══════════════════════════════════════════════════════════════════════

# ─── System 1: CPU Baseline ───────────────────────────────────────────
CPU_SRC = cpu_baseline/cpu_pipeline.cpp
CPU_BIN = cpu_baseline/cpu_baseline

cpu: $(CPU_BIN)

$(CPU_BIN): $(CPU_SRC) $(COMMON)/market_event.h $(COMMON)/benchmark.h $(COMMON)/pnl_tracker.h $(COMMON)/binance_feed.h
	$(CXX) $(CXXFLAGS) -I$(COMMON) $(CPU_SRC) -o $(CPU_BIN) -lpthread

# ─── System 2: GPU RDMA Pipeline ─────────────────────────────────────
GPU_SRC = gpu_rdma/src/gpu_pipeline.cu
GPU_BIN = gpu_rdma/gpu_rdma_pipeline

gpu: $(GPU_BIN)

$(GPU_BIN): $(GPU_SRC) $(COMMON)/market_event.h $(COMMON)/benchmark.h $(COMMON)/pnl_tracker.h $(COMMON)/binance_feed.h
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -I$(COMMON) $(GPU_SRC) -o $(GPU_BIN)

# ─── System 3: DOCA GPUNetIO (meson build, separate) ─────────────────
doca:
	@echo "DOCA build requires meson. Run:"
	@echo "  cd gpu_doca && meson setup build && ninja -C build"

# ─── Legacy Tools (from mini_trader/) ─────────────────────────────────
CONVERTER_SRC = mini_trader/src/csv_to_bin_converter.cpp
CONVERTER_BIN = mini_trader/csv_to_bin_converter

REPLAYER_SRC  = mini_trader/src/udp_replayer.cpp
REPLAYER_BIN  = mini_trader/udp_replayer

LEGACY_GPU_SRC = mini_trader/src/gpu_staging.cu
LEGACY_GPU_BIN = mini_trader/gpu_staging

RECEIVER_SRC  = mini_trader/src/udp_receiver.cpp
RECEIVER_BIN  = mini_trader/udp_receiver

tools: $(CONVERTER_BIN) $(REPLAYER_BIN)

$(CONVERTER_BIN): $(CONVERTER_SRC)
	$(CXX) $(CXXFLAGS) -Imini_trader/include $(CONVERTER_SRC) -o $(CONVERTER_BIN)

$(REPLAYER_BIN): $(REPLAYER_SRC)
	$(CXX) $(CXXFLAGS) -Imini_trader/include $(REPLAYER_SRC) -o $(REPLAYER_BIN)

legacy_gpu: $(LEGACY_GPU_BIN)

$(LEGACY_GPU_BIN): $(LEGACY_GPU_SRC)
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -Imini_trader/include $(LEGACY_GPU_SRC) -o $(LEGACY_GPU_BIN)

legacy_receiver: $(RECEIVER_BIN)

$(RECEIVER_BIN): $(RECEIVER_SRC)
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) -Imini_trader/include -x cu $(RECEIVER_SRC) -o $(RECEIVER_BIN)

# ═══════════════════════════════════════════════════════════════════════
#  LIVE BUILDS (with Binance WebSocket — requires libwebsockets)
# ═══════════════════════════════════════════════════════════════════════

# ─── System 1: CPU Baseline + Live ────────────────────────────────────
CPU_LIVE_BIN = cpu_baseline/cpu_baseline_live

cpu-live: $(CPU_LIVE_BIN)

$(CPU_LIVE_BIN): $(CPU_SRC) $(COMMON)/binance_ws_feed.h
	$(CXX) $(CXXFLAGS) $(WS_FLAGS) -I$(COMMON) $(CPU_SRC) -o $(CPU_LIVE_BIN) $(WS_LIBS)

# ─── System 2: GPU RDMA + Live ────────────────────────────────────────
GPU_LIVE_BIN = gpu_rdma/gpu_rdma_pipeline_live

gpu-live: $(GPU_LIVE_BIN)

$(GPU_LIVE_BIN): $(GPU_SRC) $(COMMON)/binance_ws_feed.h
	$(NVCC) $(NVCCFLAGS) -arch=sm_$(CUDA_ARCH) $(WS_FLAGS) -I$(COMMON) $(GPU_SRC) -o $(GPU_LIVE_BIN) $(WS_LIBS)

# ─── Standalone WebSocket Test ────────────────────────────────────────
WS_TEST_SRC = common/binance_ws_main.cpp
WS_TEST_BIN = binance_ws_test

ws-test: $(WS_TEST_BIN)

$(WS_TEST_BIN): $(WS_TEST_SRC) $(COMMON)/binance_ws_feed.h
	$(CXX) $(CXXFLAGS) $(WS_FLAGS) -I$(COMMON) $(WS_TEST_SRC) -o $(WS_TEST_BIN) $(WS_LIBS)

# ═══════════════════════════════════════════════════════════════════════
#  AGGREGATE TARGETS
# ═══════════════════════════════════════════════════════════════════════

all: cpu gpu tools

live: cpu-live gpu-live ws-test

everything: all live

# ─── Benchmark ───────────────────────────────────────────────────────
bench: all
	chmod +x benchmark/run_benchmarks.sh
	benchmark/run_benchmarks.sh quick

bench-full: all
	chmod +x benchmark/run_benchmarks.sh
	benchmark/run_benchmarks.sh full

# ─── Clean ───────────────────────────────────────────────────────────
clean:
	rm -f $(CPU_BIN) $(GPU_BIN) $(CONVERTER_BIN) $(REPLAYER_BIN)
	rm -f $(CPU_LIVE_BIN) $(GPU_LIVE_BIN) $(WS_TEST_BIN)
	rm -f $(LEGACY_GPU_BIN) $(RECEIVER_BIN)
	rm -f mini_trader/mini_trader_stream mini_trader/results_logger
	rm -rf gpu_doca/build/

.PHONY: all cpu gpu doca tools legacy_gpu legacy_receiver
.PHONY: cpu-live gpu-live ws-test live everything
.PHONY: bench bench-full clean
