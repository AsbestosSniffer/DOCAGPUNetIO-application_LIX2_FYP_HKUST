#!/bin/bash
# Environment setup for DOCA SDK on server
# Usage: source setEnv.sh

export DOCA_PATH=/opt/mellanox/doca
export PKG_CONFIG_PATH=$DOCA_PATH/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
export LD_LIBRARY_PATH=$DOCA_PATH/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
export CPATH=$DOCA_PATH/include:$CPATH
export LIBRARY_PATH=$DOCA_PATH/lib/x86_64-linux-gnu:$LIBRARY_PATH

echo "DOCA environment set: $DOCA_PATH"
