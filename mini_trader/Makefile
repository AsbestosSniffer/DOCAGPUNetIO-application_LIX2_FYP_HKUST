# Results logger
LOGGER_SRCS=src/results_logger.cpp
LOGGER_OUT=results_logger

logger: $(LOGGER_OUT)

$(LOGGER_OUT): $(LOGGER_SRCS)
	g++ -O3 -std=c++17 $(LOGGER_SRCS) -o $(LOGGER_OUT)
# GPU staging and pipeline
GPU_SRCS=src/gpu_staging.cu
GPU_OUT=gpu_staging

gpu: $(GPU_OUT)

$(GPU_OUT): $(GPU_SRCS)
	nvcc -O3 -std=c++17 -Iinclude $(GPU_SRCS) -o $(GPU_OUT)
# UDP receiver
RECEIVER_SRCS=src/udp_receiver.cpp
RECEIVER_OUT=udp_receiver

receiver: $(RECEIVER_OUT)

$(RECEIVER_OUT): $(RECEIVER_SRCS)
	g++ -O3 -std=c++17 -Iinclude $(RECEIVER_SRCS) -o $(RECEIVER_OUT)
# UDP replayer
REPLAYER_SRCS=src/udp_replayer.cpp
REPLAYER_OUT=udp_replayer

replayer: $(REPLAYER_OUT)

$(REPLAYER_OUT): $(REPLAYER_SRCS)
	g++ -O3 -std=c++17 -Iinclude $(REPLAYER_SRCS) -o $(REPLAYER_OUT)
# CSV→BIN converter
CONVERTER_SRCS=src/csv_to_bin_converter.cpp
CONVERTER_OUT=csv_to_bin_converter

converter: $(CONVERTER_OUT)

$(CONVERTER_OUT): $(CONVERTER_SRCS)
	g++ -O3 -std=c++17 -Iinclude $(CONVERTER_SRCS) -o $(CONVERTER_OUT)
NVCC=nvcc
CXXFLAGS=-O3 -std=c++17
NVCCFLAGS=-O3 -std=c++17

INCLUDES=-Iinclude

SRCS=src/main.cu src/kernels.cu src/market_sim.cpp
OUT=mini_trader_stream

all: $(OUT)

$(OUT): $(SRCS)
	$(NVCC) $(NVCCFLAGS) $(INCLUDES) $(SRCS) -o $(OUT)

clean:
	rm -f $(OUT)