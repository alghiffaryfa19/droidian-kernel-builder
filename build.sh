#!/bin/bash
#
# Droidian Kernel Build Script
# Based on: https://github.com/droidian/porting-guide/blob/master/kernel-compilation.md
#
# This script runs INSIDE the Droidian Docker container:
#   quay.io/droidian/build-essential:current-amd64
#
# Expected volume mounts:
#   /buildd              -> output directory for packages
#   /buildd/sources      -> kernel source tree
#   /buildd/builder      -> this builder repo (contains kernel-info.mk)
#

set -euo pipefail

SOURCES_DIR="/buildd/sources"
BUILDER_DIR="/buildd/builder"
KERNEL_INFO_MK="${BUILDER_DIR}/kernel-info.mk"

echo "============================================"
echo " Droidian Kernel Builder"
echo "============================================"
echo ""

# -------------------------------------------------------
# Step 1: Validate inputs
# -------------------------------------------------------
if [ ! -d "${SOURCES_DIR}" ]; then
    echo "ERROR: Kernel sources not found at ${SOURCES_DIR}"
    exit 1
fi

if [ ! -f "${KERNEL_INFO_MK}" ]; then
    echo "ERROR: kernel-info.mk not found at ${KERNEL_INFO_MK}"
    exit 1
fi

echo "[1/7] Inputs validated"
echo "  - Kernel sources: ${SOURCES_DIR}"
echo "  - kernel-info.mk: ${KERNEL_INFO_MK}"
echo ""

# -------------------------------------------------------
# Step 2: Copy droidian/ folder to kernel source root
# -------------------------------------------------------
echo "[2/7] Copying droidian/ folder to kernel source..."
DROIDIAN_DIR="${BUILDER_DIR}/droidian"
if [ -d "${DROIDIAN_DIR}" ]; then
    cp -rvL "${DROIDIAN_DIR}" "${SOURCES_DIR}/droidian"
    echo "  - Copied droidian/ folder (with config fragments)"
else
    echo "  - WARNING: droidian/ folder not found in builder repo, skipping"
fi
echo ""

# -------------------------------------------------------
# Step 3: Install linux-packaging-snippets
# -------------------------------------------------------
echo "[3/7] Installing linux-packaging-snippets..."
apt-get update -qq
apt-get install -y -qq linux-packaging-snippets devscripts equivs
echo ""

# -------------------------------------------------------
# Step 4: Create Debian packaging skeleton
# -------------------------------------------------------
echo "[4/7] Creating Debian packaging skeleton..."
cd "${SOURCES_DIR}"

# Ensure we have a valid git repo (droidian tooling requires this)
if [ ! -d ".git" ]; then
    echo "  - Initializing git repo (droidian tooling requires a git directory)"
    git init
    git add -A
    git -c user.email="builder@droidian" -c user.name="Builder" commit -m "Initial commit" --allow-empty
fi

# Create debian directory structure
mkdir -p debian/source

# Copy kernel-info.mk from builder repo
cp -v "${KERNEL_INFO_MK}" debian/kernel-info.mk

# debian/compat
echo 13 > debian/compat

# debian/source/format
echo "3.0 (native)" > debian/source/format

# debian/rules
cat > debian/rules <<'RULES'
#!/usr/bin/make -f

include /usr/share/linux-packaging-snippets/kernel-snippet.mk

%:
	dh $@
RULES
chmod +x debian/rules

echo "  - Created: debian/kernel-info.mk"
echo "  - Created: debian/compat"
echo "  - Created: debian/source/format"
echo "  - Created: debian/rules"
echo ""

# -------------------------------------------------------
# Step 5: Parse kernel-info.mk and generate debian/control + changelog
# -------------------------------------------------------
echo "[5/7] Generating debian/control and changelog..."

# Parse values from kernel-info.mk
parse_mk_var() {
    local var_name="$1"
    local default_val="${2:-}"
    local val
    val=$(grep -E "^${var_name}\s*=" debian/kernel-info.mk | head -1 | sed 's/.*=\s*//' | sed 's/\s*$//')
    if [ -z "$val" ]; then
        echo "$default_val"
    else
        echo "$val"
    fi
}

VARIANT=$(parse_mk_var "VARIANT" "android")
KERNEL_BASE_VERSION=$(parse_mk_var "KERNEL_BASE_VERSION" "0.0.0")
DEVICE_VENDOR=$(parse_mk_var "DEVICE_VENDOR" "vendor")
DEVICE_MODEL=$(parse_mk_var "DEVICE_MODEL" "device")
DEVICE_FULL_NAME=$(parse_mk_var "DEVICE_FULL_NAME" "Unknown Device")
DEB_TOOLCHAIN=$(parse_mk_var "DEB_TOOLCHAIN" "")
DEB_BUILD_ON=$(parse_mk_var "DEB_BUILD_ON" "amd64")
DEB_BUILD_FOR=$(parse_mk_var "DEB_BUILD_FOR" "arm64")
BUILD_CC=$(parse_mk_var "BUILD_CC" "clang")
BUILD_LLVM=$(parse_mk_var "BUILD_LLVM" "0")
CLANG_VERSION=$(parse_mk_var "CLANG_VERSION" "")
CLANG_CUSTOM=$(parse_mk_var "CLANG_CUSTOM" "0")

# Resolve DEVICE_FULL_NAME if it contains makefile variable references
# e.g., "Android Generic Kernel Image ($(DEVICE_MODEL))" -> replace $(DEVICE_MODEL) with actual value
DEVICE_FULL_NAME=$(echo "$DEVICE_FULL_NAME" | sed "s/\$(DEVICE_MODEL)/${DEVICE_MODEL}/g" | sed "s/\$(DEVICE_VENDOR)/${DEVICE_VENDOR}/g")

PACKAGE_NAME="linux-${VARIANT}-${DEVICE_VENDOR}-${DEVICE_MODEL}"
PKG_VERSION="${KERNEL_BASE_VERSION}-$(date +%Y%m%d%H%M%S)"

echo "  - Package: ${PACKAGE_NAME}"
echo "  - Version: ${PKG_VERSION}"
echo "  - Full name: ${DEVICE_FULL_NAME}"
echo "  - Build arch: ${DEB_BUILD_ON} -> ${DEB_BUILD_FOR}"

# Build dependencies
BUILD_DEPS="debhelper (>= 13), linux-packaging-snippets"

# Add clang/llvm toolchain to build-deps
if [ -n "${CLANG_VERSION}" ] && [ "${CLANG_CUSTOM}" != "1" ]; then
    BUILD_DEPS="${BUILD_DEPS}, clang-android-${CLANG_VERSION}, llvm-android-${CLANG_VERSION}"
fi

# Add DEB_TOOLCHAIN entries to build-deps
if [ -n "${DEB_TOOLCHAIN}" ]; then
    BUILD_DEPS="${BUILD_DEPS}, ${DEB_TOOLCHAIN}"
fi

# Add common kernel build deps
BUILD_DEPS="${BUILD_DEPS}, bc, bison, flex, libssl-dev, libelf-dev, cpio, kmod"

# Generate debian/control
cat > debian/control <<EOF
Source: ${PACKAGE_NAME}
Section: kernel
Priority: optional
Maintainer: Droidian Builder <builder@droidian.org>
Build-Depends: ${BUILD_DEPS}
Standards-Version: 4.6.0

Package: linux-image-${KERNEL_BASE_VERSION}-${DEVICE_VENDOR}-${DEVICE_MODEL}
Architecture: ${DEB_BUILD_FOR}
Description: Linux kernel for ${DEVICE_FULL_NAME}
 This package contains the Linux kernel for ${DEVICE_FULL_NAME}.

Package: linux-bootimage-${KERNEL_BASE_VERSION}-${DEVICE_VENDOR}-${DEVICE_MODEL}
Architecture: ${DEB_BUILD_FOR}
Description: Linux boot image for ${DEVICE_FULL_NAME}
 This package contains the boot image for ${DEVICE_FULL_NAME}.

Package: linux-headers-${KERNEL_BASE_VERSION}-${DEVICE_VENDOR}-${DEVICE_MODEL}
Architecture: ${DEB_BUILD_FOR}
Description: Linux kernel headers for ${DEVICE_FULL_NAME}
 This package contains the kernel headers for ${DEVICE_FULL_NAME}.
EOF

# Generate debian/changelog
cat > debian/changelog <<EOF
${PACKAGE_NAME} (${PKG_VERSION}) unstable; urgency=medium

  * Automated build

 -- Droidian Builder <builder@droidian.org>  $(date -R)
EOF

echo "  - Created: debian/control"
echo "  - Created: debian/changelog"
echo ""

# -------------------------------------------------------
# Step 6: Install build dependencies
# -------------------------------------------------------
echo "[6/7] Installing build dependencies..."

# Enable arm64 architecture for cross-packages (e.g. linux-initramfs-halium-generic:arm64)
dpkg --add-architecture arm64
apt-get update -qq

# Explicitly install clang/llvm toolchain
if [ -n "${CLANG_VERSION}" ] && [ "${CLANG_CUSTOM}" != "1" ]; then
    echo "  - Installing clang-android-${CLANG_VERSION}..."
    apt-get install -y clang-android-${CLANG_VERSION} || {
        echo "ERROR: Failed to install clang-android-${CLANG_VERSION}"
        echo "Available clang-android packages:"
        apt-cache search clang-android || true
        exit 1
    }
fi

# Install cross-compiler and kernel build tools
echo "  - Installing cross-compiler and build tools..."
apt-get install -y \
    binutils-aarch64-linux-gnu \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    linux-packaging-snippets \
    bc bison flex libssl-dev libelf-dev cpio kmod \
    python3 python-is-python3 \
    dwarves \
    rsync lz4 || true

# Install DEB_TOOLCHAIN packages if specified
if [ -n "${DEB_TOOLCHAIN}" ]; then
    echo "  - Installing DEB_TOOLCHAIN packages..."
    # Convert comma-separated list to space-separated, keep arch qualifiers like :arm64
    TOOLCHAIN_PKGS=$(echo "${DEB_TOOLCHAIN}" | tr ',' '\n' | sed 's/^ *//' | sed 's/ *$//' | tr '\n' ' ')
    apt-get install -y ${TOOLCHAIN_PKGS} || {
        echo "  WARNING: Some DEB_TOOLCHAIN packages failed to install, trying one by one..."
        for pkg in ${TOOLCHAIN_PKGS}; do
            apt-get install -y "$pkg" || echo "    SKIP: $pkg"
        done
    }
fi

# Try mk-build-deps as fallback for any remaining deps
mk-build-deps --install --remove \
    --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y' \
    debian/control 2>/dev/null || true

# Verify clang is accessible
BUILD_PATH_VAL=$(parse_mk_var "BUILD_PATH" "")
# Resolve makefile variable in BUILD_PATH (e.g. $(CLANG_VERSION))
BUILD_PATH_VAL=$(echo "$BUILD_PATH_VAL" | sed "s/\$(CLANG_VERSION)/${CLANG_VERSION}/g")

echo ""
echo "  - Verifying toolchain..."
if [ -n "${BUILD_PATH_VAL}" ]; then
    echo "  - BUILD_PATH: ${BUILD_PATH_VAL}"
    ls -la "${BUILD_PATH_VAL}/clang" 2>/dev/null && echo "  - clang found at ${BUILD_PATH_VAL}/clang" || {
        echo "  - clang not found at ${BUILD_PATH_VAL}/clang"
        echo "  - Contents of ${BUILD_PATH_VAL}:"
        ls -la "${BUILD_PATH_VAL}/" 2>/dev/null || echo "    Directory does not exist!"
        echo "  - Searching for clang..."
        find /usr/lib/llvm-android* -name "clang" 2>/dev/null || echo "    No clang found in /usr/lib/llvm-android*"
        which clang 2>/dev/null || true
    }
fi

echo ""

# -------------------------------------------------------
# Step 7: Build the kernel
# -------------------------------------------------------
echo "[7/7] Building kernel packages..."
echo "  This may take a while..."
echo ""

dpkg-buildpackage -d -b --no-sign -a"${DEB_BUILD_FOR}" -j"$(nproc)"

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo ""

# Extract boot.img from build output and .deb packages
echo "Collecting boot images..."

# Copy all .img files from kernel build output
if [ -d "out/KERNEL_OBJ" ]; then
    find "out/KERNEL_OBJ" -maxdepth 1 -name "*.img" -exec cp -v {} /buildd/ \;
    echo "  - Copied .img files from kernel build output"
fi



echo ""
echo "Built packages:"
ls -lah /buildd/*.deb 2>/dev/null || echo "  No .deb files found in /buildd/"
echo ""
echo "Boot images:"
ls -lah /buildd/*.img 2>/dev/null || echo "  No .img files found in /buildd/"
echo ""
echo "Done."
