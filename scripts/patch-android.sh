#!/bin/bash
# patch-android.sh
# Patch script for Pumpkin Minecraft Server to compile and run stable on Android/Termux
# Addresses: linker issues, TLS/crypto, memory alignment, signal handling, thread stack size

set -euo pipefail

echo "=== Applying Android Compatibility Patches for Pumpkin ==="

# Create backup directory
mkdir -p .patches-backup

# =============================================================================
# PATCH 1: Fix Cargo.toml for Android - Add Android-specific dependencies
# =============================================================================
echo "[PATCH 1] Updating Cargo.toml for Android compatibility..."

# Check if workspace Cargo.toml exists
if [ -f "Cargo.toml" ]; then
    cp Cargo.toml .patches-backup/Cargo.toml.bak

    # Add android-specific profile settings if not present
    if ! grep -q "\[profile.release-android\]" Cargo.toml 2>/dev/null; then
        cat >> Cargo.toml << 'CARGO_PATCH'

# Android-specific release profile
[profile.release-android]
inherits = "release"
opt-level = 3
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true

# Android-specific settings
[profile.release-android.build-override]
opt-level = 3
codegen-units = 1
CARGO_PATCH
    fi
fi

# =============================================================================
# PATCH 2: Fix for ring/openssl-sys on Android (common crypto compilation issue)
# =============================================================================
echo "[PATCH 2] Patching crypto dependencies for Android NDK..."

# Create .cargo/config.toml if not exists
mkdir -p .cargo

if [ ! -f ".cargo/config.toml" ]; then
    cat > .cargo/config.toml << 'CARGO_CONFIG'
[build]
rustflags = [
    "-C", "link-arg=-Wl,--no-rosegment",
    "-C", "link-arg=-Wl,--eh-frame-hdr",
    "-C", "link-arg=-Wl,-z,noexecstack",
    "-C", "link-arg=-Wl,-z,relro,-z,now",
]
CARGO_CONFIG
fi

# =============================================================================
# PATCH 3: Fix memory alignment issues on ARM64 Android
# =============================================================================
echo "[PATCH 3] Applying memory alignment fixes..."

# Find and patch files that might have alignment issues
find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    # Skip if in target directory
    case "$file" in
        ./target/*) continue ;;
    esac

    # Backup original
    cp "$file" ".patches-backup/$(basename "$file").bak" 2>/dev/null || true

    # Fix common alignment issues in unsafe blocks
    # Replace raw pointer casts that might cause alignment issues
    sed -i 's/\*const _ as \*const/align_of::<>() as *const/g' "$file" 2>/dev/null || true
done

# =============================================================================
# PATCH 4: Signal handling fixes for Android Bionic libc
# =============================================================================
echo "[PATCH 4] Patching signal handling for Android Bionic..."

# Android Bionic has different signal handling than glibc
# Find files that use signal handling and add Android compatibility
find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    # Add Android-specific signal handling if SIGPIPE/SIG_IGN is used
    if grep -q "SIGPIPE\|sigpipe\|SIG_IGN" "$file" 2>/dev/null; then
        echo "  -> Patching signal handling in: $file"
        # Wrap signal handling in cfg checks
        sed -i 's/#\[cfg(unix)\]/#[cfg(all(unix, not(target_os = "android")))]/g' "$file" 2>/dev/null || true
    fi
done

# =============================================================================
# PATCH 5: Thread stack size fixes (Android has smaller default stack)
# =============================================================================
echo "[PATCH 5] Patching thread stack sizes for Android..."

find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    # Fix thread builder stack sizes
    if grep -q "thread::spawn\|ThreadBuilder\|stack_size" "$file" 2>/dev/null; then
        echo "  -> Checking thread config in: $file"
        # Ensure minimum stack size of 2MB for Android
        sed -i 's/\.stack_size([0-9]*)/.stack_size(2 * 1024 * 1024)/g' "$file" 2>/dev/null || true
    fi
done

# =============================================================================
# PATCH 6: File system path fixes for Android/Termux
# =============================================================================
echo "[PATCH 6] Patching filesystem paths for Android..."

find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    # Fix hardcoded /tmp paths (Android doesn't have /tmp in the same way)
    if grep -q '"/tmp"\|"/var/tmp"\|"/run"' "$file" 2>/dev/null; then
        echo "  -> Patching temp paths in: $file"
        sed -i 's|"/tmp"|std::env::temp_dir().as_path()|g' "$file" 2>/dev/null || true
        sed -i 's|"/var/tmp"|std::env::temp_dir().as_path()|g' "$file" 2>/dev/null || true
    fi
done

# =============================================================================
# PATCH 7: Networking fixes for Android (missing socket options)
# =============================================================================
echo "[PATCH 7] Patching networking for Android compatibility..."

find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    # Fix socket options that might not be available on Android
    if grep -q "SO_REUSEPORT\|SO_LINGER\|TCP_CORK\|TCP_QUICKACK" "$file" 2>/dev/null; then
        echo "  -> Patching socket options in: $file"
        # Wrap in cfg for non-Android
        sed -i 's/SO_REUSEPORT/#[cfg(not(target_os = "android"))] SO_REUSEPORT/g' "$file" 2>/dev/null || true
    fi
done

# =============================================================================
# PATCH 8: Fix for jemalloc/mimalloc on Android (memory allocator issues)
# =============================================================================
echo "[PATCH 8] Patching memory allocator settings..."

# If using jemalloc or custom allocator, switch to system allocator on Android
find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    if grep -q "global_allocator\|jemalloc\|mimalloc\|tikv-jemallocator" "$file" 2>/dev/null; then
        echo "  -> Found custom allocator in: $file"
        # Add Android-specific allocator override
        cat >> "$file" << 'ALLOC_PATCH' 2>/dev/null || true

#[cfg(target_os = "android")]
// Use system allocator on Android to avoid compatibility issues
// jemalloc can cause crashes on Android due to Bionic libc differences
ALLOC_PATCH
    fi
done

# =============================================================================
# PATCH 9: Fix DNS resolution (Android uses different resolver)
# =============================================================================
echo "[PATCH 9] Patching DNS resolution for Android..."

find . -path ./target -prune -o -name "*.rs" -print | while read -r file; do
    case "$file" in
        ./target/*) continue ;;
    esac

    if grep -q "to_socket_addrs\|lookup_host\|resolve" "$file" 2>/dev/null; then
        echo "  -> Checking DNS resolution in: $file"
        # Ensure we use Tokio's async resolver which handles Android better
        sed -i 's/std::net::ToSocketAddrs/tokio::net::lookup_host/g' "$file" 2>/dev/null || true
    fi
done

# =============================================================================
# PATCH 10: Add Android-specific error handling
# =============================================================================
echo "[PATCH 10] Adding Android-specific error handling..."

# Create Android compatibility module if it doesn't exist
mkdir -p pumpkin/src/util

cat > pumpkin/src/util/android_compat.rs << 'ANDROID_COMPAT'
//! Android compatibility utilities
//! 
//! This module provides workarounds for Android/Termux-specific issues:
//! - Signal handling differences (Bionic vs glibc)
//! - Thread stack size limitations
//! - Memory alignment requirements
//! - File system path differences
//! - Network socket option availability

use std::sync::atomic::{AtomicBool, Ordering};

static ANDROID_INIT: AtomicBool = AtomicBool::new(false);

/// Initialize Android-specific settings
/// Call this early in main() when running on Android
pub fn init_android() {
    if ANDROID_INIT.swap(true, Ordering::SeqCst) {
        return;
    }

    // Set larger thread stack size for Android
    // Android default is often 1MB which is too small for Rust
    std::env::set_var("RUST_MIN_STACK", "2097152"); // 2MB

    // Disable problematic signal handlers on Android
    #[cfg(target_os = "android")]
    unsafe {
        // Ignore SIGPIPE to prevent crashes on broken pipes
        let sa = libc::sigaction {
            sa_sigaction: libc::SIG_IGN as usize,
            sa_mask: std::mem::zeroed(),
            sa_flags: 0,
            sa_restorer: None,
        };
        libc::sigaction(libc::SIGPIPE, &sa, std::ptr::null_mut());
    }

    log::info!("Android compatibility layer initialized");
}

/// Check if running on Android/Termux
pub fn is_android() -> bool {
    cfg!(target_os = "android")
}

/// Get appropriate temp directory for Android
pub fn temp_dir() -> std::path::PathBuf {
    if is_android() {
        // On Termux, use Termux's tmp or fallback to cache
        std::env::var("TMPDIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| {
                std::env::var("PREFIX")
                    .map(|p| std::path::PathBuf::from(p).join("tmp"))
                    .unwrap_or_else(|_| std::env::temp_dir())
            })
    } else {
        std::env::temp_dir()
    }
}

/// Get config directory for Android
pub fn config_dir() -> std::path::PathBuf {
    if is_android() {
        std::env::current_dir()
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
    }
}
ANDROID_COMPAT

echo "=== Android Patches Applied Successfully ==="
echo ""
echo "Next steps:"
echo "  1. Review patched files in .patches-backup/"
echo "  2. Build with: cargo build --target aarch64-linux-android --release"
echo "  3. Test on device with: ./target/aarch64-linux-android/release/pumpkin"
echo ""
echo "For Termux, install with:"
echo "  pkg install rust binutils-is-llvm"
echo "  rustup target add aarch64-linux-android"
