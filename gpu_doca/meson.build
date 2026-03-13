# DOCA GPUNetIO Trading Pipeline — Meson Build
# Build on server: meson setup build && ninja -C build

project('doca_trading', 'c', 'cpp', 'cuda',
    version: '0.1',
    default_options: ['c_std=c11', 'cpp_std=c++17', 'cuda_std=c++17'])

# DOCA SDK
doca_dep = dependency('doca', required: false)
cuda_dep = dependency('cuda', version: '>=12.0', required: true)

# Common include
common_inc = include_directories('../common')

# Check for DOCA
if doca_dep.found()
    add_project_arguments('-DHAVE_DOCA', language: ['c', 'cpp', 'cuda'])
    message('DOCA SDK found — building with full GPUNetIO support')
else
    message('DOCA SDK NOT found — building stub mode only')
endif

# Main DOCA application (C)
doca_src = files('doca_trading.c')
executable('doca_trading',
    doca_src,
    include_directories: common_inc,
    dependencies: [doca_dep],
    install: false)

# GPU kernels (CUDA)
gpu_kernel_src = files('gpu_kernels/packet_recv.cu')
executable('doca_gpu_kernels',
    gpu_kernel_src,
    include_directories: common_inc,
    dependencies: [cuda_dep, doca_dep],
    install: false)
