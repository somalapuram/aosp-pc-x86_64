/*
 * pc_v4l2_info -- report what each /dev/video* node really is, and whether the
 * sensor behind it is producing colour.
 *
 * Why this exists. The camera preview comes out black and white and the log
 * cannot say why. What the log does establish is that the external camera HAL
 * only ever streams MJPEG (ExternalCameraDeviceSession.cpp rejects any other
 * fourcc outright) and that it DROPS frames whose conversion fails rather than
 * emitting grey ones -- so the occasional "Convert V4L2 frame to YU12 failed"
 * is not the cause. That leaves two candidates, and nothing in the default log
 * distinguishes them:
 *
 *   1. the colour sensor is being streamed but is delivering a monochrome
 *      image, or
 *   2. the IR node was registered in place of the colour one.
 *
 * The obvious way to look -- verbose logging in the HAL, where the format list
 * IS printed (ExternalCameraDevice.cpp:890 and :911) -- does not work: those
 * are ALOGV, which is compiled out of release builds by LOG_NDEBUG=1, so
 * setting log.tag.ExtCamDev=V has no effect. That was a wasted boot; hence
 * asking the device directly.
 *
 * For each node this prints the driver/card/bus, the capture capability, and
 * every pixel format with its frame sizes -- which identifies the IR node
 * (it offers GREY/Y8 and no MJPEG, which is exactly why the HAL fails to
 * initialise it) versus the colour one.
 *
 * Then, where the node offers an uncompressed YUYV mode, it grabs a single
 * frame and reports the spread of the U and V samples. That is the actual
 * question answered directly: in YUYV the chroma bytes sit at a fixed offset
 * and need no decoding, and a sensor genuinely producing colour gives chroma
 * that varies across the frame, while a monochrome source pins every U and V
 * at or very near 128. No JPEG decoder needed.
 *
 * Runs in vendor_shell for the same reason as pc_audio_setup: /dev/video* is
 * camera_device, and system/sepolicy/private/app.te neverallows any appdomain
 * -- including the shell domain the other helpers use -- read or write on it.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/videodev2.h>

static void fourcc_str(unsigned int f, char out[5]) {
    out[0] = (char)(f & 0xFF);
    out[1] = (char)((f >> 8) & 0xFF);
    out[2] = (char)((f >> 16) & 0xFF);
    out[3] = (char)((f >> 24) & 0xFF);
    out[4] = '\0';
}

static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

/* Grab one YUYV frame and report how much the chroma actually moves.
 * YUYV is [Y0 U Y1 V] per two pixels, so U and V are directly readable. */
static void probe_yuyv_chroma(const char *path, unsigned int w, unsigned int h) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return;

    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = w;
    fmt.fmt.pix.height = h;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_ANY;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        printf("      chroma probe: S_FMT failed (%s)\n", strerror(errno));
        close(fd); return;
    }
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        printf("      chroma probe: driver substituted another format\n");
        close(fd); return;
    }

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
        printf("      chroma probe: REQBUFS failed (%s)\n", strerror(errno));
        close(fd); return;
    }

    void *bufs[8]; size_t lens[8];
    unsigned int n = req.count > 8 ? 8 : req.count;
    for (unsigned int i = 0; i < n; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP; b.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) { close(fd); return; }
        lens[i] = b.length;
        bufs[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        if (bufs[i] == MAP_FAILED) { close(fd); return; }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) { close(fd); return; }
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        printf("      chroma probe: STREAMON failed (%s)\n", strerror(errno));
        close(fd); return;
    }

    /* Discard the first few frames: UVC sensors commonly need a moment for
     * exposure to settle, and an early frame can be legitimately flat. */
    struct v4l2_buffer b;
    int captured = 0;
    for (int attempt = 0; attempt < 12 && !captured; attempt++) {
        memset(&b, 0, sizeof(b));
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) break;
        if (attempt >= 8 && !(b.flags & V4L2_BUF_FLAG_ERROR)) {
            unsigned char *p = (unsigned char *)bufs[b.index];
            size_t len = b.bytesused ? b.bytesused : lens[b.index];
            int umin = 255, umax = 0, vmin = 255, vmax = 0;
            long usum = 0, vsum = 0, cnt = 0;
            for (size_t off = 0; off + 3 < len; off += 4) {
                int u = p[off + 1], v = p[off + 3];
                if (u < umin) umin = u; if (u > umax) umax = u;
                if (v < vmin) vmin = v; if (v > vmax) vmax = v;
                usum += u; vsum += v; cnt++;
            }
            if (cnt > 0) {
                printf("      chroma probe: U %d..%d avg %ld | V %d..%d avg %ld  => %s\n",
                       umin, umax, usum / cnt, vmin, vmax, vsum / cnt,
                       (umax - umin <= 4 && vmax - vmin <= 4)
                               ? "FLAT CHROMA -- source is monochrome"
                               : "chroma varies -- source is colour");
            }
            captured = 1;
        }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) break;
    }
    if (!captured) printf("      chroma probe: no usable frame\n");

    xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned int i = 0; i < n; i++) munmap(bufs[i], lens[i]);
    close(fd);
}

int main(void) {
    for (int i = 0; i < 10; i++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/video%d", i);
        int fd = open(path, O_RDWR);
        if (fd < 0) continue;

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) { close(fd); continue; }

        unsigned int caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps
                                                                     : cap.capabilities;
        printf("%s  driver=%s card=\"%s\" bus=%s\n", path, cap.driver, cap.card, cap.bus_info);
        printf("    capture=%s\n", (caps & V4L2_CAP_VIDEO_CAPTURE) ? "yes" : "NO");
        if (!(caps & V4L2_CAP_VIDEO_CAPTURE)) { close(fd); continue; }

        int has_yuyv = 0;
        unsigned int yw = 0, yh = 0;
        for (int fi = 0;; fi++) {
            struct v4l2_fmtdesc fd_;
            memset(&fd_, 0, sizeof(fd_));
            fd_.index = fi;
            fd_.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            if (xioctl(fd, VIDIOC_ENUM_FMT, &fd_) < 0) break;
            char fc[5]; fourcc_str(fd_.pixelformat, fc);
            printf("    format %-6s %s\n", fc, fd_.description);

            for (int si = 0;; si++) {
                struct v4l2_frmsizeenum fs;
                memset(&fs, 0, sizeof(fs));
                fs.index = si;
                fs.pixel_format = fd_.pixelformat;
                if (xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fs) < 0) break;
                if (fs.type != V4L2_FRMSIZE_TYPE_DISCRETE) break;
                printf("        %ux%u\n", fs.discrete.width, fs.discrete.height);
                if (fd_.pixelformat == V4L2_PIX_FMT_YUYV && si == 0) {
                    has_yuyv = 1; yw = fs.discrete.width; yh = fs.discrete.height;
                }
            }
        }
        close(fd);

        if (has_yuyv) probe_yuyv_chroma(path, yw, yh);
    }
    printf("pc_v4l2_info: done\n");
    return 0;
}
