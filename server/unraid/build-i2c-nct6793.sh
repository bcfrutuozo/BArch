#!/bin/bash
# Build i2c-nct6793 (the Nuvoton Super I/O SMBus, where the on-board ASUS Aura of the Z270
# Maximus IX Code lives) as a Slackware package for the NAS's Unraid kernel. OpenRGB needs it;
# the driver is out of tree and the package is per kernel, so redo this after every Unraid update.
#
# On the NAS, inside ich777's "Unraid-Kernel" container (ghcr.io/ich777/unraid_kernel:gcc_14.2.0,
# template in https://github.com/ich777/unraid_kernel/tree/master/template, data path
# /mnt/cache/appdata/unraid-kernel mounted at /usr/src), once its log says "Container ready!":
#   bash /usr/src/build-i2c-nct6793.sh
# Output: /usr/src/<kernel>/i2c-nct6793-<kernel>-1.txz. Then, on Unraid itself:
#   cp /mnt/cache/appdata/unraid-kernel/<kernel>/i2c-nct6793-<kernel>-1.txz /boot/extra/   # installed at every boot
#   installpkg /boot/extra/i2c-nct6793-<kernel>-1.txz && depmod -a
#   depmod -a && modprobe -a i2c-dev i2c-i801 i2c-nct6793
# and that same last line in /boot/config/go: Unraid installs /boot/extra at boot without running
# depmod, so without it modprobe -a silently skips i2c-nct6793 (2026-11-02: no NCT6793 bus after a
# reboot). It came up as i2c-12, after the i915 and NVIDIA buses; the number can move if the driver
# order changes, so give the OpenRGB container every /dev/i2c-* (or --privileged), not one of them.
# and pass the new /dev/i2c-N ("SMBus NCT6793D adapter" in /sys/bus/i2c/devices/i2c-*/name) to
# the OpenRGB container.
set -euo pipefail

UNAME=$(uname -r)                       # same as the host: 6.18.58-Unraid
DATA_DIR=/usr/src
KDIR=${DATA_DIR}/linux-${UNAME}         # pre-compiled tree extracted by the container
PKG=i2c-nct6793
SRC=${DATA_DIR}/${PKG}-src
STAGE=/tmp/${PKG}-stage
OUT=${DATA_DIR}/${UNAME}
MODDIR=lib/modules/${UNAME}/kernel/drivers/i2c/busses

[ -f "${KDIR}/.config" ] || { echo "kernel tree not found at ${KDIR}"; exit 1; }
mkdir -p "${OUT}"
rm -rf "${SRC}" "${STAGE}"

# git in the container is broken (libnghttp3 mismatch): fetch the tarball with wget instead
mkdir -p "${SRC}"
wget -qO "${SRC}/src.tar.gz" https://gitlab.com/CalcProgrammer1/i2c-nct6793-dkms/-/archive/master/i2c-nct6793-dkms-master.tar.gz
tar -xzf "${SRC}/src.tar.gz" -C "${SRC}" --strip-components=1
cd "${SRC}/src"
make -C "${KDIR}" M="${PWD}" modules -j"$(nproc --all)"
modinfo ./${PKG}.ko | grep -E '^(vermagic|description)'

mkdir -p "${STAGE}/${MODDIR}" "${STAGE}/install"
cp "${PKG}.ko" "${STAGE}/${MODDIR}/"
# Unraid ships its modules as .ko.xz; match whatever the installed tree uses
if ls /lib/modules/"${UNAME}"/kernel/drivers/i2c/busses/*.ko.xz >/dev/null 2>&1; then
    xz --check=crc32 --lzma2 "${STAGE}/${MODDIR}/${PKG}.ko"
fi

cat > "${STAGE}/install/slack-desc" <<DESC
${PKG}: ${PKG} (Nuvoton NCT679x SMBus driver for Unraid ${UNAME%%-*})
${PKG}:
${PKG}: SMBus master of the Nuvoton Super I/O, used by OpenRGB for the on-board
${PKG}: ASUS Aura controller of Z270/Z370 boards. Source:
${PKG}: https://gitlab.com/CalcProgrammer1/i2c-nct6793-dkms
${PKG}:
DESC

cd "${STAGE}"
makepkg -l n -c n "${OUT}/${PKG}-${UNAME}-1.txz"
md5sum "${OUT}/${PKG}-${UNAME}-1.txz" | awk '{print $1}' > "${OUT}/${PKG}-${UNAME}-1.txz.md5"
rm -rf "${STAGE}" "${SRC}"
echo "done: ${OUT}/${PKG}-${UNAME}-1.txz"
