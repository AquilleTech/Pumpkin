#!/bin/bash
# patch-android.sh
# Patch script for Pumpkin Minecraft Server to compile on Android/Termux
#
# WHAT THIS SCRIPT DOES (and does NOT do):
#   - Adds an Android-specific Cargo profile to Cargo.toml (safe, additive)
#   - Creates pumpkin/src/android_compat.rs as a standalone helper module
#   - Does NOT blindly sed-replace Rust source (too risky, breaks code)
#   - Does NOT touch .cargo/config.toml (the workflow generates it from NDK path)
#
# USAGE: called by .github/workflows/build.yml after checkout

set -euo pipefail

echo "=== Applying Android Compatibility Patches for Pumpkin ==="
echo "Working directory: $(pwd)"

# Sanity check: make sure we're in the Pumpkin repo root
if [ ! -f "Cargo.toml" ] || ! grep -q 'name = "pumpkin"' pumpkin/Cargo.toml 2>/dev/null; then
    echo "ERROR: This script must be run from the Pumpkin repo root."
    exit 1
fi

mkdir -p .patches-backup

# =============================================================================
# PATCH 1: Add Android-specific Cargo profile to workspace Cargo.toml
# =============================================================================
echo ""
echo "[PATCH 1] Adding Android release profile to Cargo.toml..."

cp Cargo.toml .patches-backup/Cargo.toml.bak

if grep -q "\[profile\.release-android\]" Cargo.toml; then
    echo "  -> [profile.release-android] already present, skipping."
else
    cat >> Cargo.toml << 'CARGO_PATCH'

# Android-specific release profile
# Use: cargo build --target aarch64-linux-android --profile release-android
[profile.release-android]
inherits = "release"
opt-level = 3
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true
CARGO_PATCH
    echo "  -> Added [profile.release-android] to Cargo.toml."
fi

# =============================================================================
# PATCH 2: Create android_compat.rs helper module in pumpkin/src/
#
# This is a NEW file we create — we do NOT modify existing Pumpkin source.
# The developer must manually add `pub mod android_compat;` to pumpkin/src/main.rs
# (or lib.rs) and call android_compat::init() at the start of main() if desired.
#
# We do NOT auto-inject the mod declaration here because blindly sed-ing main.rs
# is fragile and can silently break things.
# =============================================================================
echo ""
echo "[PATCH 2] Creating pumpkin/src/android_compat.rs..."

COMPAT_FILE="pumpkin/src/android_compat.rs"

if [ -f "${COMPAT_FILE}" ]; then
    echo "  -> ${COMPAT_FILE} already exists, skipping."
else
    cat > "${COMPAT_FILE}" << 'ANDROID_COMPAT'
//! Android / Termux compatibility helpers for Pumpkin.
//!
//! To activate, add to pumpkin/src/main.rs (or lib.rs):
//!
//!   #[cfg(target_os = "android")]
//!   pub mod android_compat;
//!
//! Then call at the top of main():
//!
//!   #[cfg(target_os = "android")]
//!   android_compat::init();
//!
//! Dependencies required in pumpkin/Cargo.toml (already present in Pumpkin):
//!   [target.'cfg(target_os = "android")'.dependencies]
//!   # no extra deps needed; libc is pulled in transitively by tokio

#![allow(dead_code)]

use std::sync::atomic::{AtomicBool, Ordering};

static INIT_DONE: AtomicBool = AtomicBool::new(false);

/// Initialise Android-specific settings.
/// Call once at the very start of `main()`, before the Tokio runtime starts.
pub fn init() {
    if INIT_DONE.swap(true, Ordering::SeqCst) {
        return;
    }

    // Android default thread stack is often 1 MB, which is too small for
    // deeply recursive async Rust (world gen, etc.). Tokio reads this env var
    // when spawning worker threads.
    // 8 MB matches what a typical Linux desktop gives by default.
    // Set before the Tokio runtime is created.
    if std::env::var("RUST_MIN_STACK").is_err() {
        // SAFETY: single-threaded at this point (before runtime start)
        unsafe { std::env::set_var("RUST_MIN_STACK", "8388608") };
    }

    // Ignore SIGPIPE — Android Bionic does not do this automatically.
    // Without this, writing to a closed socket kills the process instead of
    // returning an error, which is almost never what a server wants.
    ignore_sigpipe();

    tracing::info!("Android compatibility layer initialised.");
}

/// Ignore SIGPIPE so broken-pipe errors surface as `Err(BrokenPipe)` rather
/// than killing the process.
#[cfg(target_os = "android")]
fn ignore_sigpipe() {
    // SAFETY: called before any other threads are spawned; sigaction is
    // async-signal-safe and does not interact with Rust's own signal handling.
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = libc::SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &sa, std::ptr::null_mut());
    }
}

#[cfg(not(target_os = "android"))]
fn ignore_sigpipe() {
    // No-op on non-Android: the workflow only compiles this crate for Android,
    // but keep the file compilable on all targets for editor tooling.
}

/// Returns the appropriate temp directory for the current environment.
///
/// On Termux, `std::env::temp_dir()` may return `/data/local/tmp` which is
/// not writable in all contexts. Prefer `$TMPDIR` (set by Termux) if present.
pub fn temp_dir() -> std::path::PathBuf {
    #[cfg(target_os = "android")]
    {
        if let Ok(d) = std::env::var("TMPDIR") {
            return std::path::PathBuf::from(d);
        }
        // Termux prefix fallback
        if let Ok(prefix) = std::env::var("PREFIX") {
            return std::path::PathBuf::from(prefix).join("tmp");
        }
    }
    std::env::temp_dir()
}
ANDROID_COMPAT

    echo "  -> Created ${COMPAT_FILE}."
    echo ""
    echo "  IMPORTANT: To activate the compat layer, add the following to"
    echo "  pumpkin/src/main.rs (inside fn main, before runtime start):"
    echo ""
    echo "    #[cfg(target_os = \"android\")]"
    echo "    pub mod android_compat;"
    echo "    #[cfg(target_os = \"android\")]"
    echo "    android_compat::init();"
    echo ""
fi

# =============================================================================
# PATCH 3: libc dependency for android_compat.rs
#
# android_compat.rs uses libc for sigaction. libc is already an indirect
# dependency of Pumpkin (via tokio, etc.), but we need it as a direct dep
# in pumpkin/Cargo.toml so it can be used in our new file.
# =============================================================================
echo "[PATCH 3] Ensuring libc is a direct dependency in pumpkin/Cargo.toml..."

if grep -q '^\[target\.' pumpkin/Cargo.toml && grep -q 'libc' pumpkin/Cargo.toml; then
    echo "  -> libc already referenced in pumpkin/Cargo.toml, skipping."
else
    cp pumpkin/Cargo.toml .patches-backup/pumpkin_Cargo.toml.bak
    cat >> pumpkin/Cargo.toml << 'LIBC_DEP'

# Added by patch-android.sh — needed by android_compat.rs for sigaction
[target.'cfg(target_os = "android")'.dependencies]
libc = "0.2"
LIBC_DEP
    echo "  -> Added libc target dependency to pumpkin/Cargo.toml."
fi

# =============================================================================
# PATCH 4: Warn about wasmtime (plugin system) — not available on Android
#
# Pumpkin's plugin system uses wasmtime (see workspace Cargo.toml).
# wasmtime does NOT support Android targets. The build will fail if
# the wasmtime feature is enabled. We check and warn here; the proper
# fix is to gate it with a feature flag in upstream Pumpkin.
# =============================================================================
echo ""
echo "[PATCH 4] Checking for wasmtime dependency (unsupported on Android)..."

if grep -q 'wasmtime' pumpkin/Cargo.toml 2>/dev/null; then
    echo "  -> WARNING: pumpkin/Cargo.toml references wasmtime."
    echo "     wasmtime does not support Android targets."
    echo "     The build will likely fail unless wasmtime is behind a feature flag."
    echo "     Suggested fix in pumpkin/Cargo.toml:"
    echo ""
    echo "       # Change:"
    echo "       wasmtime = { workspace = true }"
    echo ""
    echo "       # To:"
    echo "       [target.'cfg(not(target_os = \"android\"))'.dependencies]"
    echo "       wasmtime = { workspace = true }"
    echo ""
    echo "     This patch does NOT auto-apply that change because it requires"
    echo "     careful review of all wasmtime call sites in the codebase."
else
    echo "  -> wasmtime not found in pumpkin/Cargo.toml, OK."
fi

# =============================================================================
# PATCH 5: Verify NDK toolchain is accessible
# =============================================================================
echo ""
echo "[PATCH 5] Verifying Android NDK toolchain..."

if [ -z "${NDK_PATH:-}" ]; then
    # Try common env var names set by the nttld/setup-ndk action
    NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
fi

if [ -z "${NDK_PATH}" ]; then
    echo "  -> WARNING: NDK_PATH / ANDROID_NDK_HOME not set. Skipping NDK check."
    echo "     Make sure the NDK is set up before running this script in CI."
else
    CLANG="${NDK_PATH}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
    if [ -f "${CLANG}" ]; then
        echo "  -> NDK clang found: ${CLANG}"
        "${CLANG}" --version | head -1
    else
        echo "  -> ERROR: NDK clang not found at: ${CLANG}"
        echo "     Expected NDK layout (r26c):"
        echo "       \$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/*-clang"
        exit 1
    fi
fi

# =============================================================================
echo ""
echo "=== Android Patches Applied Successfully ==="
echo ""
echo "Next steps:"
echo "  Build:  cargo build --target aarch64-linux-android --profile release-android"
echo "  Deploy: adb push target/aarch64-linux-android/release-android/pumpkin /data/local/tmp/"
echo "          adb shell chmod +x /data/local/tmp/pumpkin"
echo ""
echo "On Termux (native, no cross-compile needed):"
echo "  pkg install rust"
echo "  cargo build --release"
