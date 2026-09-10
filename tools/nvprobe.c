/*
 * nvprobe -- ask a nouveau render node what it actually is, and whether its
 * 3D engine came up.
 *
 * This exists because the obvious ways to answer that question are all closed
 * on this device:
 *
 *   dmesg            the default GRUB entry boots without
 *                    sysctl.kernel.dmesg_restrict=0, and /proc/sys/kernel/
 *                    dmesg_restrict is proc_security, which domain.te lets
 *                    only init and vendor_init even read. shell is an
 *                    appdomain and holds no capability, so no CAP_SYSLOG.
 *   debugfs          not readable by shell under enforcing policy.
 *   the PCI ids      /sys/.../device gives the PCI device id, and that is NOT
 *                    what indexes nouveau's chipset table -- 10de:25bb appears
 *                    nowhere in nvkm/engine/device/base.c. The chipset id is
 *                    read from boot0 at probe time and is 0x177 for that part.
 *
 * DRM_NOUVEAU_GETPARAM answers all of it from userspace, and works as plain
 * `shell` because render nodes are 0666.
 *
 * GRAPH_UNITS is the interesting one: it is served by the GR engine itself, so
 * it returns EINVAL on a chipset whose nvXXX_chipset has no .gr (every Ada
 * AD10x today) and a non-zero GPC/TPC word when the engine is up. That is the
 * difference between "nouveau bound" -- which says nothing about 3D -- and
 * "nouveau can render", which is what you actually want to know.
 *
 * Run it against the i915 render node as a control: DRM rejects the nouveau
 * ioctl number there with EACCES, which is how you know the answer above came
 * from nouveau and not from whichever node happened to be first.
 *
 * Build (NDK, static so it needs nothing on the device):
 *   $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android31-clang \
 *       -static -O1 -o nvprobe tools/nvprobe.c
 *   adb push nvprobe /data/local/tmp/ && adb shell /data/local/tmp/nvprobe
 */
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* From uapi/drm/nouveau_drm.h -- copied rather than included so this builds
 * against a bare NDK sysroot with no kernel headers alongside it. */
struct drm_nouveau_getparam { uint64_t param; uint64_t value; };
#define NOUVEAU_GETPARAM_PCI_VENDOR      3
#define NOUVEAU_GETPARAM_PCI_DEVICE      4
#define NOUVEAU_GETPARAM_CHIPSET_ID     11
#define NOUVEAU_GETPARAM_GRAPH_UNITS    13
#define DRM_NOUVEAU_GETPARAM 0x00
#define DRM_IOCTL_NOUVEAU_GETPARAM \
    _IOWR('d', 0x40 + DRM_NOUVEAU_GETPARAM, struct drm_nouveau_getparam)

static void q(int fd, const char *name, uint64_t p)
{
    struct drm_nouveau_getparam g;
    memset(&g, 0, sizeof g);
    g.param = p;

    if (ioctl(fd, DRM_IOCTL_NOUVEAU_GETPARAM, &g))
        printf("  %-12s FAILED  errno=%d (%s)\n", name, errno, strerror(errno));
    else
        printf("  %-12s 0x%llx (%llu)\n", name,
               (unsigned long long)g.value, (unsigned long long)g.value);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/dev/dri/renderD129";
    int fd = open(path, O_RDWR | O_CLOEXEC);

    if (fd < 0) {
        printf("  open(%s): %s\n", path, strerror(errno));
        return 1;
    }

    printf("  node: %s\n", path);
    q(fd, "PCI_VENDOR",  NOUVEAU_GETPARAM_PCI_VENDOR);
    q(fd, "PCI_DEVICE",  NOUVEAU_GETPARAM_PCI_DEVICE);
    q(fd, "CHIPSET_ID",  NOUVEAU_GETPARAM_CHIPSET_ID);
    /* Non-zero here means the GR engine initialised. EINVAL means this chipset
     * has no .gr and the card cannot do 3D under nouveau at all. */
    q(fd, "GRAPH_UNITS", NOUVEAU_GETPARAM_GRAPH_UNITS);

    close(fd);
    return 0;
}
