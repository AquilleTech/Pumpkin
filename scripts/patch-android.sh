#!/bin/bash
# patch-android.sh - Android compatibility patches for Pumpkin
# Dipanggil oleh .github/workflows/build-android.yml

set -euo pipefail

echo "=== Applying Android patches ==="

# Cek kita di root repo yang benar
if [ ! -f "Cargo.toml" ]; then
  echo "ERROR: Jalankan dari root repo Pumpkin."
  exit 1
fi

mkdir -p .patches-backup

# ---- PATCH 1: Tambah profile release-android di Cargo.toml ----
echo "[1] Menambah profile release-android..."
if grep -q "\[profile\.release-android\]" Cargo.toml; then
  echo "    Sudah ada, skip."
else
  cp Cargo.toml .patches-backup/Cargo.toml.bak
  cat >> Cargo.toml << 'EOF'

[profile.release-android]
inherits = "release"
opt-level = 3
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true
EOF
  echo "    Ditambahkan."
fi

# ---- PATCH 2: Tambah libc sebagai target dependency di pumpkin/Cargo.toml ----
echo "[2] Memastikan libc tersedia untuk android target..."
if grep -q "target.*android.*dependencies" pumpkin/Cargo.toml 2>/dev/null; then
  echo "    Target android deps sudah ada, skip."
else
  cp pumpkin/Cargo.toml .patches-backup/pumpkin_Cargo.toml.bak
  cat >> pumpkin/Cargo.toml << 'EOF'

[target.'cfg(target_os = "android")'.dependencies]
libc = "0.2"
EOF
  echo "    Ditambahkan."
fi

# ---- PATCH 3: Buat android_compat.rs ----
echo "[3] Membuat pumpkin/src/android_compat.rs..."
COMPAT="pumpkin/src/android_compat.rs"

if [ -f "$COMPAT" ]; then
  echo "    Sudah ada, skip."
else
  cat > "$COMPAT" << 'EOF'
//! Modul kompatibilitas Android/Termux untuk Pumpkin.
//!
//! Cara pakai — tambahkan ke pumpkin/src/main.rs:
//!
//!   #[cfg(target_os = "android")]
//!   mod android_compat;
//!
//! Lalu panggil di awal main(), sebelum runtime Tokio dibuat:
//!
//!   #[cfg(target_os = "android")]
//!   android_compat::init();

#![allow(dead_code)]

use std::sync::atomic::{AtomicBool, Ordering};
static DONE: AtomicBool = AtomicBool::new(false);

/// Inisialisasi settings khusus Android.
/// Panggil sekali di awal main() sebelum Tokio runtime dibuat.
pub fn init() {
    if DONE.swap(true, Ordering::SeqCst) {
        return;
    }
    // Naikkan stack size default thread Tokio.
    // Android default 1 MB sering tidak cukup untuk world gen Pumpkin.
    if std::env::var("RUST_MIN_STACK").is_err() {
        // SAFETY: dipanggil sebelum thread lain dibuat
        unsafe { std::env::set_var("RUST_MIN_STACK", "8388608") }; // 8 MB
    }
    ignore_sigpipe();
}

#[cfg(target_os = "android")]
fn ignore_sigpipe() {
    // Mencegah proses mati karena SIGPIPE saat koneksi terputus.
    // Android Bionic tidak mengabaikan SIGPIPE secara default.
    // SAFETY: dipanggil single-threaded sebelum runtime dibuat.
    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = libc::SIG_IGN;
        libc::sigaction(libc::SIGPIPE, &sa, std::ptr::null_mut());
    }
}

#[cfg(not(target_os = "android"))]
fn ignore_sigpipe() {}

/// Temp dir yang benar untuk Termux.
/// Termux meng-set $TMPDIR; fallback ke $PREFIX/tmp jika tidak ada.
pub fn temp_dir() -> std::path::PathBuf {
    if let Ok(d) = std::env::var("TMPDIR") {
        return std::path::PathBuf::from(d);
    }
    if let Ok(prefix) = std::env::var("PREFIX") {
        return std::path::PathBuf::from(prefix).join("tmp");
    }
    std::env::temp_dir()
}
EOF
  echo "    Dibuat di $COMPAT"
  echo ""
  echo "    PENTING: Tambahkan ke pumpkin/src/main.rs :"
  echo "      #[cfg(target_os = \"android\")]"
  echo "      mod android_compat;"
  echo "      // di dalam fn main():"
  echo "      #[cfg(target_os = \"android\")]"
  echo "      android_compat::init();"
  echo ""
fi

# ---- PATCH 4: Warning wasmtime (tidak support Android) ----
echo "[4] Mengecek dependensi wasmtime..."
if grep -q "wasmtime" pumpkin/Cargo.toml 2>/dev/null; then
  echo ""
  echo "    PERINGATAN: wasmtime ditemukan di pumpkin/Cargo.toml."
  echo "    wasmtime TIDAK mendukung target Android — build akan gagal."
  echo "    Fix: pindahkan ke target dependency:"
  echo ""
  echo "      [target.'cfg(not(target_os = \"android\"))'.dependencies]"
  echo "      wasmtime = { workspace = true }"
  echo "      wasmtime-wasi = { workspace = true }"
  echo ""
  echo "    Lakukan perubahan ini secara manual di pumpkin/Cargo.toml."
  echo ""
else
  echo "    wasmtime tidak ditemukan, OK."
fi

# ---- PATCH 5: Verifikasi NDK tersedia ----
echo "[5] Verifikasi NDK..."
NDK="${NDK_PATH:-${ANDROID_NDK_HOME:-}}"
if [ -z "$NDK" ]; then
  echo "    PERINGATAN: NDK_PATH tidak di-set, skip verifikasi."
else
  CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
  if [ -f "$CLANG" ]; then
    echo "    NDK OK: $("$CLANG" --version | head -1)"
  else
    echo "    ERROR: Clang tidak ditemukan di: $CLANG"
    exit 1
  fi
fi

echo ""
echo "=== Patches selesai ==="
