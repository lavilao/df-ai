#!/bin/bash
set -e

# ============================================================
# build_and_test_r8.sh
# Build df-ai against DFHack 0.47.05-r8 and install into DF
# ============================================================

WORKSPACE="/home/luis/dwarf-bench"
DFHACK_TAG="0.47.05-r8"
DFHACK_SRC="/tmp/dfhack-src"
DFHACK_BUILD="/tmp/dfhack-build"
DF_DIR="/tmp/df-build/df_linux"
BOOST_LOCAL="$HOME/boost-dev"
XSLT_LOCAL="$HOME/xslt-dev"
LOCAL_LIB="/tmp/lib"

# --- Step 0: Check prerequisites ---
echo "=== Step 0: Checking prerequisites ==="
for tool in cmake ninja g++ git perl; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool not found. Install it first."
        exit 1
    fi
done

# Check Perl XML modules
if ! perl -e 'use XML::LibXML; use XML::LibXSLT; 1' &>/dev/null; then
    echo "ERROR: Perl XML::LibXML and/or XML::LibXSLT not found."
    echo "Install them via cpan or your package manager."
    exit 1
fi
echo "All prerequisites OK."

# --- Step 1: Extract DF 47.05 ---
echo "=== Step 1: Extracting DF 47.05 ==="
mkdir -p /tmp/df-build
if [ ! -d "$DF_DIR" ]; then
    tar xf "$WORKSPACE/df_47_05_linux.tar.bz2" -C /tmp/df-build
    echo "DF extracted to $DF_DIR"
else
    echo "DF already extracted at $DF_DIR"
fi

# --- Step 2: Clone DFHack source (with submodules) ---
echo "=== Step 2: Cloning DFHack $DFHACK_TAG ==="
if [ ! -d "$DFHACK_SRC" ]; then
    git clone --recursive --branch "$DFHACK_TAG" https://github.com/DFHack/dfhack.git "$DFHACK_SRC"
    echo "DFHack cloned to $DFHACK_SRC"
else
    echo "DFHack source already exists at $DFHACK_SRC"
fi

# --- Step 3: Copy df-ai into plugins ---
echo "=== Step 3: Setting up df-ai as plugin ==="
rm -rf "$DFHACK_SRC/plugins/df-ai"
cp -r "$WORKSPACE/df-ai" "$DFHACK_SRC/plugins/df-ai"

# Init submodules for df-ai (weblegends etc.)
cd "$DFHACK_SRC/plugins/df-ai"
git submodule update --init --recursive 2>/dev/null || true

# --- Step 4: Set up external plugin link ---
echo "=== Step 4: Registering df-ai as external plugin ==="
mkdir -p "$DFHACK_SRC/plugins/external"
cat > "$DFHACK_SRC/plugins/external/CMakeLists.txt" << 'CMEOF'
# Add external plugins here - this file is ignored by git
add_subdirectory(df-ai)
CMEOF

# --- Step 5: Configure build ---
echo "=== Step 5: Configuring CMake ==="
mkdir -p "$DFHACK_BUILD"
cd "$DFHACK_BUILD"
cmake "$DFHACK_SRC" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE:string=Release \
    -DCMAKE_INSTALL_PREFIX="$DF_DIR" \
    -DDFHACK_BUILD_ARCH=64 \
    -DBOOST_ROOT="$BOOST_LOCAL/usr" \
    2>&1 | tail -5
echo "CMake configured successfully."

# --- Step 6: Build df-ai ---
echo "=== Step 6: Building df-ai ==="
ninja df-ai
echo "df-ai built successfully."

# --- Step 7: Install everything ---
echo "=== Step 7: Installing DFHack + df-ai ==="
ninja install
echo "Installation complete."

# --- Step 8: Verify ---
echo "=== Step 8: Verification ==="
PLUGIN="$DF_DIR/hack/plugins/df-ai.plug.so"
if [ -f "$PLUGIN" ]; then
    echo "PASS: df-ai.plug.so installed at $PLUGIN"
    file "$PLUGIN"
else
    echo "FAIL: df-ai.plug.so not found!"
    exit 1
fi

echo ""
echo "=== Build complete! ==="
echo "To test: cd $DF_DIR && ./dfhack"
echo "Then run: enable df-ai"
