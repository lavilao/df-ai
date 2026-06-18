# df-ai: Adding DFHack 0.47.05-r8 Support

## Overview

This document describes all changes required to make df-ai compile and run against DFHack 0.47.05-r8. The prior code targeted r7.

---

## 1. Breaking API Change: `Units::isCitizen()`

### What changed

In DFHack r8, `Units::isCitizen()` gained an optional second parameter:

```cpp
// r7 signature:
bool isCitizen(df::unit *unit);

// r8 signature:
bool isCitizen(df::unit *unit, bool ignore_sanity = false);
```

**The default behavior changed.** In r7, `isCitizen()` always excluded insane citizens. In r8, the default (`ignore_sanity = false`) includes them.

### Required fix

All 11 call sites must pass `true` to preserve r7 behavior:

```cpp
// Before (breaks with r8):
if (Units::isCitizen(u)) { ... }

// After (preserves r7 behavior):
if (Units::isCitizen(u, true)) { ... }
```

### Files changed

| File | Line(s) |
|------|---------|
| `population_death.cpp` | 52 |
| `camera.cpp` | 204 |
| `stocks_find.cpp` | 900 |
| `military.cpp` | 135, 155 |
| `population.cpp` | 165, 193 |
| `population_nobles.cpp` | 71 |
| `population_military.cpp` | 695, 729, 752 |

---

## 2. GCC 14+ Compilation Fixes

These are not r8-specific but are required to build on modern GCC (14+).

### 2a. Pessimizing-move warnings (`-Werror=pessimizing-move`)

`std::move()` on a return value prevents copy elision. GCC 14 treats this as an error.

```cpp
// Before (error with GCC 14):
std::vector<std::string> names{ std::move(value.getMemberNames()) };

// After:
std::vector<std::string> names{ value.getMemberNames() };
```

Files changed:
- `apply.h` line 228
- `blueprint_template.cpp` lines 112, 218, 229

### 2b. Boost coroutine2 false positive (`-Werror=maybe-uninitialized`)

GCC 14 emits a false positive `-Wmaybe-uninitialized` warning inside Boost.Coroutine2 headers (specifically `state.hpp:70`). This is not a df-ai bug - it's a GCC/Boost incompatibility.

**Fix:** Add `-Wno-error=maybe-uninitialized` to df-ai's compile flags in `CMakeLists.txt`:

```cmake
DFHACK_PLUGIN(df-ai ${PROJECT_SRCS} LINK_LIBRARIES ${PROJECT_LIBS}
    COMPILE_FLAGS_GCC "-Wall -Wextra -Werror -Wno-unused-parameter -Wno-error=maybe-uninitialized"
    COMPILE_FLAGS_MSVC "/W3 /WX")
```

---

## 3. No Other Breaking Changes

Verified by comparing DFHack r7 and r8 headers and changelogs:

- `Items::getOwner()` - unchanged from r7 fix
- `Constructions::findAtTile()` - changed to binary search internally, but df-ai doesn't use it
- `isUndead()` - gained optional parameter, but df-ai doesn't call it
- Removed `resume` plugin - df-ai doesn't use it
- `gui/create-item --restricted` removed - df-ai doesn't use it

---

## 4. Build Environment Setup

### 4a. Dependencies

DFHack requires these system packages:

```
gcc cmake ninja-build git zlib1g-dev libsdl1.2-dev perl perl-XML-LibXML perl-XML-LibXSLT
```

df-ai additionally requires:

```
libboost-context-dev (Boost >= 1.67.0)
```

### 4b. Perl XML modules (required for DFHack code generation)

DFHack uses Perl to generate C++ headers from XML structure definitions during cmake configure.

**Ubuntu/Debian:**
```bash
apt-get install libxml-libxml-perl libxml-libxslt-perl
```

**If libxslt-dev is missing (no sudo):**
The `.so` symlink for libxslt is missing. Fix:
```bash
# Create symlink in a user-accessible location
mkdir -p /tmp/lib
ln -sf /usr/lib/x86_64-linux-gnu/libxslt.so.1 /tmp/lib/libxslt.so
ln -sf /usr/lib/x86_64-linux-gnu/libexslt.so.0 /tmp/lib/libexslt.so

# Extract dev headers locally
apt-get download libxslt1-dev libxml2-dev
mkdir -p ~/xslt-dev
dpkg -x libxslt1-dev*.deb ~/xslt-dev
dpkg -x libxml2-dev*.deb ~/xslt-dev

# Build XML::LibXSLT manually
cd /tmp
wget https://cpan.metacpan.org/authors/id/S/SH/SHLOMIF/XML-LibXSLT-2.003000.tar.gz
tar xzf XML-LibXSLT-2.003000.tar.gz
cd XML-LibXSLT-2.003000
perl Makefile.PL \
    LIBS="-L/tmp/lib -lxslt -lexslt" \
    INC="-I$HOME/xslt-dev/usr/include -I$HOME/xslt-dev/usr/include/x86_64-linux-gnu -I$HOME/xslt-dev/usr/include/libxml2"
make && make install
```

### 4c. Boost (required for df-ai)

df-ai uses `boost::coroutines2` for its exclusive callback system.

```bash
apt-get download libboost1.83-dev libboost-context1.83-dev
mkdir -p ~/boost-dev
dpkg -x libboost1.83-dev*.deb ~/boost-dev
dpkg -x libboost-context1.83-dev*.deb ~/boost-dev
```

### 4d. SDL libraries (required to run DF)

DF 0.47.05 expects `libSDL_image-1.2.so.0` and `libSDL_ttf-2.0.so.0` at runtime:

```bash
apt-get download libsdl-image1.2 libsdl-ttf2.0-0
mkdir -p /tmp/sdl-rt
dpkg -x libsdl-image1.2_*.deb /tmp/sdl-rt
dpkg -x libsdl-ttf2.0-0_*.deb /tmp/sdl-rt
cp /tmp/sdl-rt/usr/lib/x86_64-linux-gnu/libSDL_image-1.2.so.0 <DF_DIR>/libs/
cp /tmp/sdl-rt/usr/lib/x86_64-linux-gnu/libSDL_ttf-2.0.so.0 <DF_DIR>/libs/
```

---

## 5. Build Process

### 5a. Extract DF

```bash
mkdir -p /tmp/df-build
tar xf df_47_05_linux.tar.bz2 -C /tmp/df-build
# DF is now at /tmp/df-build/df_linux
```

### 5b. Clone DFHack source

```bash
git clone --recursive --branch 0.47.05-r8 https://github.com/DFHack/dfhack.git /tmp/dfhack-src
```

### 5c. Add df-ai to the plugin tree

```bash
# Copy df-ai into the plugins directory
cp -r /path/to/df-ai /tmp/dfhack-src/plugins/df-ai

# Init submodules (weblegends etc.)
cd /tmp/dfhack-src/plugins/df-ai
git submodule update --init --recursive

# Register as external plugin
mkdir -p /tmp/dfhack-src/plugins/external
cat > /tmp/dfhack-src/plugins/external/CMakeLists.txt << 'EOF'
add_subdirectory(df-ai)
EOF
```

### 5d. Configure and build

```bash
mkdir -p /tmp/dfhack-build
cd /tmp/dfhack-build

cmake /tmp/dfhack-src \
    -G Ninja \
    -DCMAKE_BUILD_TYPE:string=Release \
    -DCMAKE_INSTALL_PREFIX=/tmp/df-build/df_linux \
    -DDFHACK_BUILD_ARCH=64 \
    -DBOOST_ROOT=$HOME/boost-dev/usr

ninja df-ai          # build just df-ai
ninja install         # install everything to DF directory
```

### 5e. Verify

```bash
ls -la /tmp/df-build/df_linux/hack/plugins/df-ai.plug.so
# Should be ~3MB ELF shared object

ldd /tmp/df-build/df_linux/hack/plugins/df-ai.plug.so
# libdfhack.so and liblua.so "not found" is normal - loaded at runtime by DFHack
```

### 5f. Run

```bash
cd /tmp/df-build/df_linux
LD_LIBRARY_PATH=/tmp/df-build/df_linux/libs ./dfhack
# In the DFHack console:
enable df-ai
```

---

## 6. Files Changed in df-ai

| File | Change type | Description |
|------|-------------|-------------|
| `population_death.cpp` | API compat | `isCitizen(u, true)` |
| `camera.cpp` | API compat | `isCitizen(u, true)` |
| `stocks_find.cpp` | API compat | `isCitizen(u, true)` |
| `military.cpp` | API compat | `isCitizen(u, true)` x2 |
| `population.cpp` | API compat | `isCitizen(u, true)` x2 |
| `population_nobles.cpp` | API compat | `isCitizen(u, true)` |
| `population_military.cpp` | API compat | `isCitizen(u, true)` x3 |
| `apply.h` | GCC 14 fix | Remove `std::move()` on temporary |
| `blueprint_template.cpp` | GCC 14 fix | Remove `std::move()` on temporary x3 |
| `CMakeLists.txt` | GCC 14 fix | Add `-Wno-error=maybe-uninitialized` |

---

## 7. Automation Script

`build_and_test_r8.sh` automates the full process. Run it from the workspace:

```bash
./build_and_test_r8.sh
```

---

## 8. Notes for Future DFHack Version Updates

1. **Check `Units.h`** for signature changes to predicates like `isCitizen()`, `isUndead()`, `isDanger()`
2. **Check `CMakeLists.txt`** library names (e.g., `jsoncpp_lib_static` -> `jsoncpp_static` changed between r6 and r7)
3. **Check for new `-Werror` flags** in DFHack's build system that may conflict with df-ai code
4. **Check for removed/renamed plugins** that df-ai might reference
5. **Compare changelogs** at https://dfhack.readthedocs.io/en/stable/docs/NEWS.html
