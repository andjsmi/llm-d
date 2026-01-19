#!/bin/bash
set -Eeu

cd /tmp

# . /usr/local/bin/setup-sccache
. "${VIRTUAL_ENV}/bin/activate"

# if [ "${USE_SCCACHE}" = "true" ]; then
#     export CC="sccache gcc" CXX="sccache g++" NVCC="sccache nvcc"
# fi

if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then
  rpm -ivh --nodeps /tmp/packages/rpms/amd64/libnl3-cli*.rpm
  rpm -ivh --nodeps /tmp/packages/rpms/amd64/libnl3-devel*.rpm
  rpm -ivh --nodeps /tmp/packages/rpms/amd64/numactl-devel*.rpm
fi

git clone "${UCCL_REPO}" --recursive && cd uccl

TARGET="cuda"

WHEEL_DIR="wheelhouse-${TARGET}"
PY_VER="$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")"
ARCH="$(uname -m)"
BUILD_TYPE="ep"
IS_EFA=$( [ -d "/sys/class/infiniband/" ] && ls /sys/class/infiniband/ 2>/dev/null | grep -q rdmap && echo "EFA support: true" ) || echo "EFA support: false"


if [[ "$TARGET" == "therock" ]]; then

  # Setup requested Python (PyPA images have all versions pre-installed)
  PY_V=$(echo ${PY_VER} | tr -d .)
  export PATH=/opt/python/cp${PY_V}-cp${PY_V}/bin:$PATH

  # Python environment with ROCm from TheRock
  python3 -m venv /tmp/venv && . /tmp/venv/bin/activate
  pip3 install --no-cache-dir --upgrade pip
  pip3 install --no-cache-dir build auditwheel pybind11
  pip3 install --no-cache-dir rocm[libraries,devel] --index-url ${ROCM_IDX_URL}
fi

echo "HERE!"
echo $(find / -name declare)


build_ep() {
  local TARGET="$1"
  local ARCH="$2"
  local IS_EFA="$3"

  set -euo pipefail
  echo "[container] build_ep Target: $TARGET"

  if [[ "$TARGET" == "therock" ]]; then
    echo "Skipping GPU-driven build on therock (no GPU-driven support yet)."
  elif [[ "$TARGET" == rocm* || "$TARGET" == cuda* ]]; then
    cd ep
    # This may be needed if you traverse through different git commits
    # make clean && rm -r build || true
    python3 setup.py build
    cd ..
    echo "[container] Copying GPU-driven .so to uccl/"
    mkdir -p uccl/lib
    cp ep/build/**/*.so uccl/
  fi
}


echo "HERE!"
if [[ "$TARGET" == rocm* ]]; then
  build_rccl_nccl_h
fi

if [[ "$BUILD_TYPE" == "ccl_rdma" ]]; then
  build_ccl_rdma "$TARGET" "$ARCH" "$IS_EFA"
elif [[ "$BUILD_TYPE" == "ccl_efa" ]]; then
  build_ccl_efa "$TARGET" "$ARCH" "$IS_EFA"
elif [[ "$BUILD_TYPE" == "p2p" ]]; then
  build_p2p "$TARGET" "$ARCH" "$IS_EFA"
elif [[ "$BUILD_TYPE" == "ep" ]]; then
  build_ep "$TARGET" "$ARCH" "$IS_EFA"
elif [[ "$BUILD_TYPE" == "ukernel" ]]; then
  build_ukernel "$TARGET" "$ARCH" "$IS_EFA"
elif [[ "$BUILD_TYPE" == "all" ]]; then
  build_ccl_rdma "$TARGET" "$ARCH" "$IS_EFA"
  build_ccl_efa "$TARGET" "$ARCH" "$IS_EFA"
  build_p2p "$TARGET" "$ARCH" "$IS_EFA"
  # build_ep "$TARGET" "$ARCH" "$IS_EFA"
  # build_ukernel "$TARGET" "$ARCH" "$IS_EFA"
fi

ls -lh uccl/
ls -lh uccl/lib/

# Emit TheRock init code
if [[ "$TARGET" == "therock" ]]; then
  echo "
def initialize():
  import rocm_sdk
  rocm_sdk.initialize_process(preload_shortnames=[
    \"amd_comgr\",
    \"amdhip64\",
    \"roctx64\",
    \"hiprtc\",
    \"hipblas\",
    \"hipfft\",
    \"hiprand\",
    \"hipsparse\",
    \"hipsolver\",
    \"rccl\",
    \"hipblaslt\",
    \"miopen\",
  ],
  check_version=\"$(rocm-sdk version)\")
" > uccl/_rocm_init.py

  # Back-up setup.py and emit UCCL package dependence on TheRock
  BACKUP_FN=$(mktemp -p . -t setup.py.XXXXXX)
  cp ./setup.py ${BACKUP_FN}
  sed -i "s/\"rocm\": \[\],/\"rocm\": \[\"rocm\[libraries\]==$(rocm-sdk version)\"\, \"torch\", \"numpy\"],/;" setup.py

  export PIP_EXTRA_INDEX_URL=${ROCM_IDX_URL}
fi

python3 -m build

if [[ "$TARGET" == "therock" ]]; then
  # Undo UCCL package dependence on TheRock wheels after the build is done
  mv ${BACKUP_FN} setup.py
fi

yum install elfutils-libelf elfutils-libelf-devel
uv pip install patchelf auditwheel

auditwheel repair dist/uccl-*.whl \
  --exclude "libtorch*.so" \
  --exclude "libc10*.so" \
  --exclude "libibverbs.so.1" \
  --exclude "libcudart.so.12" \
  --exclude "libamdhip64.so.*" \
  --exclude "libcuda.so.1" \
  --exclude "libefa.so.1" \
  -w /io/${WHEEL_DIR}

auditwheel show /io/${WHEEL_DIR}/*.whl


# Add backend tag to wheel filename using local version identifier
if [[ "$TARGET" == rocm* || "$TARGET" == "therock" ]]; then
  # Adjust TARGET to the preferred wheel name suffix for python-packaged ROCm, e.g. "rocm7.9.0rc1"
  if [[ "$TARGET" == "therock" ]]; then
    TARGET="rocm$(rocm-sdk version)"
  fi
  cd /io/${WHEEL_DIR}
  for wheel in uccl-*.whl; do
    if [[ -f "$wheel" ]]; then
      # Extract wheel name components: uccl-version-python-abi-platform.whl
      if [[ "$wheel" =~ ^(uccl-)([^-]+)-([^-]+-[^-]+-.+)(\.whl)$ ]]; then
        name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
        python_abi_platform="${BASH_REMATCH[3]}"
        suffix="${BASH_REMATCH[4]}"
        
        # Add backend to version using local identifier: uccl-version+backend-python-abi-platform.whl
        new_wheel="${name}${version}+${TARGET}-${python_abi_platform}${suffix}"
        
        echo "Renaming wheel: $wheel -> $new_wheel"
        mv "$wheel" "$new_wheel"
      else
        echo "Warning: Could not parse wheel filename: $wheel"
      fi
    fi
  done
  cd /io
fi



cd /tmp/uccl/ep/deep_ep_wrapper
python setup.py bdist_wheel
cp dist/deep_ep-*.whl /io/${WHEEL_DIR}/



# uv pip install /io/${WHEEL_DIR}/uccl-*.whl
