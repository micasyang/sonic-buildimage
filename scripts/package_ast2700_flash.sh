#!/bin/bash
#
# Package a SONiC build into an AST2700-compatible flash image that reuses
# OpenBMC-produced U-Boot binaries.
#
# This script is intended to be invoked from the SONiC build root:
#     scripts/package_ast2700_flash.sh --platform centec-arm64 \
#         --uboot-dir /path/to/openbmc/images/obmc-wb \
#         --output target/ast2700/flash-<platform>.bin
#
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: package_ast2700_flash.sh [options]

Options:
  --platform <name>        SONiC platform (defaults to contents of .platform)
  --uboot-dir <path>       Path containing OpenBMC U-Boot artifacts
                           (defaults to OPENBMC_UBOOT_DIR)
  --dtb <path>             Explicit device-tree blob to embed in FIT
  --output <path>          Output flash image (defaults to target/ast2700/flash-<platform>.bin)
  --flash-size <bytes>     Total flash size (default: AST2700_FLASH_SIZE or 134217728)
  --fit-offset-kb <value>  Offset (in KiB) at which to place FIT image (default: AST2700_FIT_OFFSET_KB or 2048)
  --rootfs-offset-mb <val> Offset (in MiB) for rootfs image (default: AST2700_ROOTFS_OFFSET_MB or 32)
  --kernel-load-addr <hex> Kernel load address (default: AST2700_KERNEL_LOAD_ADDR or 0x80080000)
  --kernel-entry-addr <hex>Kernel entry address (default: same as load addr)
  --ramdisk-load-addr <hex>Ramdisk load/entry address (default: AST2700_RAMDISK_LOAD_ADDR or 0x83000000)
  --ramdisk-compression <none|gzip>  Override initrd compression (auto-detected otherwise)
  -h, --help               Show this help
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# Default inputs from environment or repo metadata
PLATFORM="${CONFIGURED_PLATFORM:-}"
[[ -z "${PLATFORM}" && -f .platform ]] && PLATFORM="$(< .platform)"
PROJECT_ROOT="$(pwd)"

UBOOT_DIR="${OPENBMC_UBOOT_DIR:-}"
DTB_PATH="${OPENBMC_AST2700_DTB:-}"
OUTPUT=""
FLASH_SIZE="${AST2700_FLASH_SIZE:-671088640}"
FIT_OFFSET_KB="${AST2700_FIT_OFFSET_KB:-2048}"
ROOTFS_OFFSET_MB="${AST2700_ROOTFS_OFFSET_MB:-32}"
KLOAD="${AST2700_KERNEL_LOAD_ADDR:-0x80080000}"
KENTRY="${AST2700_KERNEL_ENTRY_ADDR:-}"
RLOAD="${AST2700_RAMDISK_LOAD_ADDR:-0x83000000}"
RAMDISK_COMPRESSION_OVERRIDE="${AST2700_RAMDISK_COMPRESSION:-}"
FLASH_PADDING_MB="${AST2700_FLASH_PADDING_MB:-64}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2;;
        --uboot-dir) UBOOT_DIR="$2"; shift 2;;
        --dtb) DTB_PATH="$2"; shift 2;;
        --output) OUTPUT="$2"; shift 2;;
        --flash-size) FLASH_SIZE="$2"; shift 2;;
        --fit-offset-kb) FIT_OFFSET_KB="$2"; shift 2;;
        --rootfs-offset-mb) ROOTFS_OFFSET_MB="$2"; shift 2;;
        --kernel-load-addr) KLOAD="$2"; shift 2;;
        --kernel-entry-addr) KENTRY="$2"; shift 2;;
        --ramdisk-load-addr) RLOAD="$2"; shift 2;;
        --ramdisk-compression) RAMDISK_COMPRESSION_OVERRIDE="$2"; shift 2;;
        --flash-padding-mb) FLASH_PADDING_MB="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        --) shift; break;;
        *) die "Unknown option: $1";;
    esac
done

[[ -n "${CONFIGURED_PLATFORM:-}" && -z "${PLATFORM}" ]] && PLATFORM="${CONFIGURED_PLATFORM}"
[[ -z "${PLATFORM}" ]] && die "Platform not specified (use --platform or ensure .platform exists)"

if [[ -z "${UBOOT_DIR}" ]]; then
    UBOOT_DIR="files/ast2700/uboot"
fi

if [[ "${UBOOT_DIR}" != /* ]]; then
    UBOOT_DIR="${PROJECT_ROOT}/${UBOOT_DIR}"
fi

if [[ ! -d "${UBOOT_DIR}" ]]; then
    ALT_DIR="${PROJECT_ROOT}/files/ast2700/uboot"
    if [[ -d "${ALT_DIR}" ]]; then
        echo "Warning: U-Boot directory '${UBOOT_DIR}' not accessible; falling back to '${ALT_DIR}'" >&2
        UBOOT_DIR="${ALT_DIR}"
    else
        die "U-Boot directory '${UBOOT_DIR}' not found. Copy u-boot-spl.bin/u-boot.bin (and optional DTB) into '${ALT_DIR}' or pass --uboot-dir to an accessible path inside the Sonic workspace."
    fi
fi

if [[ -z "${OUTPUT}" ]]; then
    OUTPUT="target/ast2700/flash-${PLATFORM}.bin"
fi

if [[ -z "${KENTRY}" ]]; then
    KENTRY="${KLOAD}"
fi

mkdir -p "$(dirname "${OUTPUT}")"
LOG_PATH="${OUTPUT}.log"
: > "${LOG_PATH}"
exec > >(tee -a "${LOG_PATH}") 2>&1
echo "Build start time: $(date -u)"

# Verify required tools
command -v mkimage > /dev/null || die "mkimage not found (install u-boot-tools)"
command -v j2 > /dev/null || die "j2 command not found"
if [[ -z "${DTB_PATH}" ]]; then
    command -v dumpimage > /dev/null || die "dumpimage not found (needed to extract DTB)"
fi

# Locate SONiC build artifacts
ROOTFS_SQFS="target/sonic-${PLATFORM}.bin__${PLATFORM}__rfs.squashfs"
[[ -f "${ROOTFS_SQFS}" ]] || die "Rootfs squashfs '${ROOTFS_SQFS}' not found. Build target/sonic-${PLATFORM}.bin first."

WORKDIR="$(mktemp -d -t sonic-ast2700-XXXXXX)"
cleanup() {
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

FSROOT_DIR="fsroot-${PLATFORM}"
FSROOT_FROM_SQUASHFS=0

if [[ ! -d "${FSROOT_DIR}" ]]; then
    echo "Info: ${FSROOT_DIR} not present; extracting from ${ROOTFS_SQFS}" >&2
    command -v unsquashfs > /dev/null || die "unsquashfs not found (install squashfs-tools)"
    FSROOT_DIR="${WORKDIR}/fsroot-${PLATFORM}"
    unsquashfs -d "${FSROOT_DIR}" "${ROOTFS_SQFS}" > /dev/null
    FSROOT_FROM_SQUASHFS=1
fi

find_kernel_initrd() {
    local root="$1"
    shopt -s nullglob
    local kernels=("${root}/boot"/vmlinuz-*)
    if [[ ${#kernels[@]} -eq 0 ]]; then
        kernels=("${root}/boot"/Image-*)
    fi
    local initrds=("${root}/boot"/initrd.img-*)
    shopt -u nullglob
    KERNEL_IMG=""
    INITRD_IMG=""
    if [[ ${#kernels[@]} -gt 0 ]]; then
        KERNEL_IMG="${kernels[0]}"
    fi
    if [[ ${#initrds[@]} -gt 0 ]]; then
        INITRD_IMG="${initrds[0]}"
    fi
}

find_kernel_initrd "${FSROOT_DIR}"

ensure_accessible() {
    local path="$1"
    [[ -n "${path}" ]] || return 1
    ( test -r "${path}" && test -f "${path}" ) && return 0
    sudo test -r "${path}" 2>/dev/null && sudo test -f "${path}" 2>/dev/null
}

if ! ensure_accessible "${KERNEL_IMG}" || ! ensure_accessible "${INITRD_IMG}"; then
    if [[ "${FSROOT_FROM_SQUASHFS}" -eq 1 ]]; then
        die "Kernel/initrd not accessible even after extracting ${ROOTFS_SQFS}"
    fi
    echo "Info: falling back to squashfs extraction for kernel/initrd" >&2
    FSROOT_DIR="${WORKDIR}/fsroot-${PLATFORM}"
    unsquashfs -d "${FSROOT_DIR}" "${ROOTFS_SQFS}" > /dev/null
    FSROOT_FROM_SQUASHFS=1
    find_kernel_initrd "${FSROOT_DIR}"
    ensure_accessible "${KERNEL_IMG}" || die "Kernel image '${KERNEL_IMG}' not accessible"
    ensure_accessible "${INITRD_IMG}" || die "Initrd image '${INITRD_IMG}' not accessible"
fi

# Identify U-Boot binaries
UBOOT_SPL="${UBOOT_DIR}/u-boot-spl.bin"
UBOOT_BIN="${UBOOT_DIR}/u-boot.bin"
[[ -f "${UBOOT_SPL}" ]] || die "Missing ${UBOOT_SPL}"
[[ -f "${UBOOT_BIN}" ]] || die "Missing ${UBOOT_BIN}"

if sudo test -r "${KERNEL_IMG}"; then
    sudo cp "${KERNEL_IMG}" "${WORKDIR}/kernel.bin"
else
    cp "${KERNEL_IMG}" "${WORKDIR}/kernel.bin"
fi
if sudo test -r "${INITRD_IMG}"; then
    sudo cp "${INITRD_IMG}" "${WORKDIR}/initrd.raw"
else
    cp "${INITRD_IMG}" "${WORKDIR}/initrd.raw"
fi
sudo chown "$USER":"$USER" "${WORKDIR}/kernel.bin" "${WORKDIR}/initrd.raw" > /dev/null 2>&1 || true

# Normalise initrd compression
INITRD_FILE="${WORKDIR}/initrd.img"
if [[ -n "${RAMDISK_COMPRESSION_OVERRIDE}" ]]; then
    case "${RAMDISK_COMPRESSION_OVERRIDE}" in
        none) cp "${WORKDIR}/initrd.raw" "${INITRD_FILE}"; RAMDISK_COMPRESSION="${RAMDISK_COMPRESSION_OVERRIDE}";;
        gzip)
            gzip -c "${WORKDIR}/initrd.raw" > "${INITRD_FILE}"
            RAMDISK_COMPRESSION="gzip"
            ;;
        *) die "Unsupported ramdisk compression override '${RAMDISK_COMPRESSION_OVERRIDE}'";;
    esac
else
    if file "${WORKDIR}/initrd.raw" | grep -qi 'gzip compressed'; then
        cp "${WORKDIR}/initrd.raw" "${INITRD_FILE}"
        RAMDISK_COMPRESSION="gzip"
    else
        cp "${WORKDIR}/initrd.raw" "${INITRD_FILE}"
        RAMDISK_COMPRESSION="none"
    fi
fi

# Resolve DTB
if [[ -n "${DTB_PATH}" ]]; then
    [[ -f "${DTB_PATH}" ]] || die "Specified DTB '${DTB_PATH}' not found"
    cp "${DTB_PATH}" "${WORKDIR}/platform.dtb"
else
    # Try to extract from fitImage or find a standalone dtb
    FIT_CANDIDATE="${UBOOT_DIR}/fitImage-obmc-wb"
    if [[ -f "${FIT_CANDIDATE}" ]]; then
        dumpimage -T flat_dt -p 0 "${FIT_CANDIDATE}" "${WORKDIR}/platform.dtb" \
            || die "Failed to extract DTB from ${FIT_CANDIDATE}"
    else
        DTB_CANDIDATE="$(ls "${UBOOT_DIR}"/*.dtb 2>/dev/null | head -n1 || true)"
        [[ -n "${DTB_CANDIDATE}" ]] || die "No DTB found in ${UBOOT_DIR}; supply one via --dtb"
        cp "${DTB_CANDIDATE}" "${WORKDIR}/platform.dtb"
    fi
fi

# Render ITS template and build FIT image
ITS_FILE="${WORKDIR}/ast2700_fit_image.its"
KERNEL_LOAD_ADDR="${KLOAD}" \
KERNEL_ENTRY_ADDR="${KENTRY}" \
RAMDISK_LOAD_ADDR="${RLOAD}" \
RAMDISK_COMPRESSION="${RAMDISK_COMPRESSION}" \
j2 files/build_templates/ast2700_fit_image.its.j2 > "${ITS_FILE}"

mkimage -f "${ITS_FILE}" "${WORKDIR}/fitImage-sonic" > /dev/null

# Prepare flash image
FLASH_SIZE_BYTES="${FLASH_SIZE}"
[[ "${FLASH_SIZE_BYTES}" =~ ^[0-9]+$ ]] || die "Invalid flash size '${FLASH_SIZE_BYTES}'"

FIT_OFFSET_BYTES=$((FIT_OFFSET_KB * 1024))
ROOTFS_OFFSET_BYTES=$((ROOTFS_OFFSET_MB * 1024 * 1024))

ROOTFS_SIZE_BYTES=$(stat -c %s "${ROOTFS_SQFS}")
FIT_SIZE_BYTES=$(stat -c %s "${WORKDIR}/fitImage-sonic")
UBOOT_SPL_SIZE=$(stat -c %s "${UBOOT_SPL}")
UBOOT_BIN_SIZE=$(stat -c %s "${UBOOT_BIN}")

(( FIT_OFFSET_BYTES > (UBOOT_SPL_SIZE + UBOOT_BIN_SIZE) )) || die "FIT offset overlaps U-Boot region"
PADDING_BYTES=$((FLASH_PADDING_MB * 1024 * 1024))
REQUIRED_FLASH_BYTES=$((ROOTFS_OFFSET_BYTES + ROOTFS_SIZE_BYTES + PADDING_BYTES))
if (( FLASH_SIZE_BYTES < REQUIRED_FLASH_BYTES )); then
    ADJUSTED=$(((REQUIRED_FLASH_BYTES + 1048575) / 1048576 * 1048576))
    echo "Info: expanding flash size from ${FLASH_SIZE_BYTES} to ${ADJUSTED} bytes to accommodate rootfs" >&2
    FLASH_SIZE_BYTES=${ADJUSTED}
fi

truncate -s "${FLASH_SIZE_BYTES}" "${OUTPUT}"

dd if="${UBOOT_SPL}" of="${OUTPUT}" bs=1k seek=0 conv=notrunc status=none
dd if="${UBOOT_BIN}" of="${OUTPUT}" bs=1k seek=256 conv=notrunc status=none
dd if="${WORKDIR}/fitImage-sonic" of="${OUTPUT}" bs=1 seek="${FIT_OFFSET_BYTES}" conv=notrunc status=none
dd if="${ROOTFS_SQFS}" of="${OUTPUT}" bs=1 seek="${ROOTFS_OFFSET_BYTES}" conv=notrunc status=none

echo "AST2700 flash image created at ${OUTPUT}"
echo "  Flash size : ${FLASH_SIZE_BYTES} bytes"
echo "  FIT offset : ${FIT_OFFSET_BYTES} bytes"
echo "  Rootfs size: ${ROOTFS_SIZE_BYTES} bytes (offset ${ROOTFS_OFFSET_BYTES})"

echo "AST2700 flash image created at ${OUTPUT}"
echo "  U-Boot SPL : ${UBOOT_SPL}"
echo "  U-Boot BIN : ${UBOOT_BIN}"
echo "  FIT image  : offset ${FIT_OFFSET_BYTES} bytes"
echo "  Rootfs     : offset ${ROOTFS_OFFSET_BYTES} bytes, size ${ROOTFS_SIZE_BYTES} bytes"
