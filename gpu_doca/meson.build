# DOCA GPUNetIO Trading Pipeline — Meson Build
# Build on server: source ../setEnv.sh && meson setup build && ninja -C build

project('doca_trading', 'c', 'cpp', 'cuda',
    version: '0.1',
    default_options: ['c_std=c11', 'cpp_std=c++17', 'cuda_std=c++17'])

# DOCA SDK — individual packages (DOCA 3.x uses per-library .pc files)
doca_gpunetio_dep = dependency('doca-gpunetio', required: false)
doca_common_dep = dependency('doca-common', required: false)
doca_eth_dep = dependency('doca-eth', required: false)
doca_flow_dep = dependency('doca-flow', required: false)

cuda_dep = dependency('cuda', version: '>=12.0', required: true,
                      modules: ['cudart_static', 'rt', 'pthread', 'dl'])

# Common include
common_inc = include_directories('../common')

# Determine DOCA availability
have_doca = doca_gpunetio_dep.found() and doca_common_dep.found() and doca_eth_dep.found()

if have_doca
    add_project_arguments('-DHAVE_DOCA', language: ['c', 'cpp', 'cuda'])
    add_project_arguments('-DALLOW_EXPERIMENTAL_API', language: ['c', 'cpp', 'cuda'])
    message('DOCA SDK found — building with full GPUNetIO support')
    doca_deps = [doca_gpunetio_dep, doca_common_dep, doca_eth_dep, doca_flow_dep]
else
    message('DOCA SDK NOT found — building stub mode only')
    doca_deps = []
endif

# Main DOCA application (C++)
doca_src = files('doca_trading.cpp')
executable('doca_trading',
    doca_src,
    include_directories: common_inc,
    dependencies: doca_deps + [cuda_dep],
    install: false)

# GPU kernels (CUDA)
gpu_kernel_src = files('gpu_kernels/packet_recv.cu')
executable('doca_gpu_kernels',
    gpu_kernel_src,
    include_directories: common_inc,
    dependencies: [cuda_dep] + doca_deps,
    install: false)
