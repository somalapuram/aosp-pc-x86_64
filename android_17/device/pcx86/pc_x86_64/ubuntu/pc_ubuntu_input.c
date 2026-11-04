/*
 * pc_ubuntu_input -- see pc_ubuntu_input.h.
 */

#define _GNU_SOURCE
#define LOG_TAG "pc_ubuntu_launch"

#include "pc_ubuntu_input.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <log/log.h>

#define MAX_INPUTS  6               /* vendor.ubuntu.input, each with its own copy */
#define MAX_SOURCES 16              /* real devices read, configured + hot-plugged */
#define MAX_COPIES  (MAX_INPUTS + 2)
#define LONGS(bits) (((bits) + 8 * sizeof(long) - 1) / (8 * sizeof(long)))
#define TEST(bit, arr) (((arr)[(bit) / (8 * sizeof(long))] >> ((bit) % (8 * sizeof(long)))) & 1)

/* A uinput device Ubuntu sees. Copies 0..MAX_INPUTS-1 mirror one configured
 * device each; GENERIC_POINTER and GENERIC_KEYBOARD take everything plugged
 * in later. All are named pc-ubuntu-input-<index>, which
 * /vendor/etc/excluded-input-devices.xml hides from Android. */
#define GENERIC_POINTER  MAX_INPUTS
#define GENERIC_KEYBOARD (MAX_INPUTS + 1)
struct copy {
    int fd;
    unsigned long down[LONGS(KEY_CNT)];   /* keys pressed on it */
};

/* A real device: read always (for the switch keys), grabbed while Ubuntu has
 * the screen, its events forwarded to `copy`, or routed (ub_route) between
 * the two generic copies when copy is -1. */
struct source {
    int real;
    int copy;
    char node[UB_INPUT_LEN];        /* "eventN" */
};

static struct copy g_copy[MAX_COPIES];
static struct source g_src[MAX_SOURCES];
static int g_nsrc;
static volatile pid_t *g_systemd;
static enum ub_switch g_screen = UB_SWITCH_ANDROID;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* --------------------------------------------------------------- copies ---- */

static int copy_bits(int real, int u, int ev, int max, unsigned long req)
{
    unsigned long bits[LONGS(KEY_CNT)] = { 0 };
    int code;

    if (ioctl(real, EVIOCGBIT(ev, max), bits) < 0)
        return -1;
    for (code = 0; code < max; code++)
        if (TEST(code, bits))
            ioctl(u, req, code);
    return 0;
}

/* The node the kernel made for a new uinput device: /dev/input/eventM, once
 * Android's ueventd has created it. */
static int copy_node(int u, char *out, size_t outlen)
{
    char sys[64] = "", dir[160];
    struct dirent *e;
    DIR *d;
    int i;

    if (ioctl(u, UI_GET_SYSNAME(sizeof(sys)), sys) < 0)
        return -1;
    snprintf(dir, sizeof(dir), "/sys/devices/virtual/input/%s", sys);
    for (i = 0; i < 60; i++) {          /* up to 3 s for the node */
        if ((d = opendir(dir))) {
            while ((e = readdir(d)))
                if (!strncmp(e->d_name, "event", 5)) {
                    char node[64];
                    snprintf(node, sizeof(node), "/dev/input/%s", e->d_name);
                    if (access(node, F_OK) == 0) {
                        snprintf(out, outlen, "input/%s", e->d_name);
                        closedir(d);
                        return 0;
                    }
                }
            closedir(d);
        }
        usleep(50 * 1000);
    }
    return -1;
}

static int make_copy(int real, int idx, char *node, size_t nodelen)
{
    unsigned long ev[LONGS(EV_CNT)] = { 0 }, props[LONGS(INPUT_PROP_CNT)] = { 0 };
    struct uinput_setup us;
    int u, code;

    if ((u = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC)) < 0)
        return -1;
    if (ioctl(real, EVIOCGBIT(0, EV_MAX), ev) < 0)
        goto fail;
    for (code = 1; code < EV_MAX; code++)
        if (TEST(code, ev))
            ioctl(u, UI_SET_EVBIT, code);
    if (TEST(EV_KEY, ev)) copy_bits(real, u, EV_KEY, KEY_MAX, UI_SET_KEYBIT);
    if (TEST(EV_REL, ev)) copy_bits(real, u, EV_REL, REL_MAX, UI_SET_RELBIT);
    if (TEST(EV_MSC, ev)) copy_bits(real, u, EV_MSC, MSC_MAX, UI_SET_MSCBIT);
    if (TEST(EV_LED, ev)) copy_bits(real, u, EV_LED, LED_MAX, UI_SET_LEDBIT);
    if (TEST(EV_SW, ev))  copy_bits(real, u, EV_SW, SW_MAX, UI_SET_SWBIT);
    if (TEST(EV_ABS, ev)) {
        unsigned long abs[LONGS(ABS_CNT)] = { 0 };
        ioctl(real, EVIOCGBIT(EV_ABS, ABS_MAX), abs);
        for (code = 0; code < ABS_MAX; code++) {
            struct uinput_abs_setup a = { .code = (unsigned short)code };
            if (!TEST(code, abs) || ioctl(real, EVIOCGABS(code), &a.absinfo) < 0)
                continue;
            ioctl(u, UI_SET_ABSBIT, code);
            ioctl(u, UI_ABS_SETUP, &a);
        }
    }
    if (ioctl(real, EVIOCGPROP(sizeof(props)), props) >= 0)
        for (code = 0; code < INPUT_PROP_MAX; code++)
            if (TEST(code, props))
                ioctl(u, UI_SET_PROPBIT, code);

    memset(&us, 0, sizeof(us));
    ioctl(real, EVIOCGID, &us.id);
    /* The name /vendor/etc/excluded-input-devices.xml hides from Android. */
    snprintf(us.name, sizeof(us.name), "pc-ubuntu-input-%d", idx);
    if (ioctl(u, UI_DEV_SETUP, &us) < 0 || ioctl(u, UI_DEV_CREATE) < 0)
        goto fail;
    if (copy_node(u, node, nodelen) < 0) {
        ioctl(u, UI_DEV_DESTROY);
        goto fail;
    }
    return u;
fail:
    close(u);
    return -1;
}

/* The two generic copies: a pointer with buttons and both wheels, and a
 * keyboard with every key. */
static int make_generic(int idx, char *node, size_t nodelen)
{
    struct uinput_setup us;
    int u, code;

    if ((u = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC)) < 0)
        return -1;
    ioctl(u, UI_SET_EVBIT, EV_KEY);
    if (idx == GENERIC_POINTER) {
        static const int rels[] = { REL_X, REL_Y, REL_WHEEL, REL_HWHEEL,
                                    REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES };
        size_t i;
        ioctl(u, UI_SET_EVBIT, EV_REL);
        for (code = BTN_LEFT; code <= BTN_TASK; code++)
            ioctl(u, UI_SET_KEYBIT, code);
        for (i = 0; i < sizeof(rels) / sizeof(rels[0]); i++)
            ioctl(u, UI_SET_RELBIT, rels[i]);
        ioctl(u, UI_SET_PROPBIT, INPUT_PROP_POINTER);
    } else {
        ioctl(u, UI_SET_EVBIT, EV_REP);
        for (code = 1; code < KEY_CNT; code++)
            if (code < BTN_MISC || code >= KEY_OK)
                ioctl(u, UI_SET_KEYBIT, code);
    }
    memset(&us, 0, sizeof(us));
    us.id.bustype = BUS_VIRTUAL;
    snprintf(us.name, sizeof(us.name), "pc-ubuntu-input-%d", idx);
    if (ioctl(u, UI_DEV_SETUP, &us) < 0 || ioctl(u, UI_DEV_CREATE) < 0 ||
        copy_node(u, node, nodelen) < 0) {
        close(u);
        return -1;
    }
    return u;
}

static int has_source(const char *node)
{
    int i;

    for (i = 0; i < g_nsrc; i++)
        if (!strcmp(g_src[i].node, node))
            return 1;
    return 0;
}

/* Consider /dev/input/<node> as a hot-plugged (or boot-time extra) device:
 * a mouse or keyboard that is not one of ours becomes a source routed to the
 * generic copies. Called with g_lock held. */
static void try_add_source(const char *node)
{
    unsigned long ev[LONGS(EV_CNT)] = { 0 }, key[LONGS(KEY_CNT)] = { 0 }, rel[LONGS(REL_CNT)] = { 0 };
    char path[48], name[80] = "";
    enum ub_class cls;
    int fd;

    if (g_nsrc >= MAX_SOURCES || has_source(node) || strncmp(node, "event", 5))
        return;
    snprintf(path, sizeof(path), "/dev/input/%s", node);
    if ((fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0)
        return;
    ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
    if (!strncmp(name, "pc-ubuntu-input-", 16)) {       /* one of our copies */
        close(fd);
        return;
    }
    ioctl(fd, EVIOCGBIT(0, EV_MAX), ev);
    ioctl(fd, EVIOCGBIT(EV_KEY, KEY_MAX), key);
    ioctl(fd, EVIOCGBIT(EV_REL, REL_MAX), rel);
    cls = ub_classify(ev, key, rel);
    if (cls == UB_CLASS_NONE ||
        g_copy[cls == UB_CLASS_POINTER ? GENERIC_POINTER : GENERIC_KEYBOARD].fd < 0) {
        close(fd);
        return;
    }
    if (g_screen == UB_SWITCH_UBUNTU && ioctl(fd, EVIOCGRAB, 1) < 0)
        ALOGW("grab %s: %s", node, strerror(errno));
    g_src[g_nsrc++] = (struct source){ .real = fd, .copy = -1 };
    snprintf(g_src[g_nsrc - 1].node, UB_INPUT_LEN, "%s", node);
    ALOGI("input %s (%s) plugged in: shared as a %s", node, name,
          cls == UB_CLASS_POINTER ? "pointer" : "keyboard");
}

static void drop_source(int i)
{
    ALOGI("input %s unplugged", g_src[i].node);
    close(g_src[i].real);
    g_src[i] = g_src[--g_nsrc];
}

int ui_setup(char out[][UB_DEV_LEN], int max)
{
    char value[PROP_VALUE_MAX] = "", names[MAX_INPUTS][UB_INPUT_LEN], path[48];
    int n, i, rejected = 0, added = 0;
    DIR *d;
    struct dirent *e;

    for (i = 0; i < MAX_COPIES; i++)
        g_copy[i].fd = -1;
    if (__system_property_get("vendor.ubuntu.input", value) <= 0)
        return 0;
    n = ub_parse_inputs(value, names, MAX_INPUTS, &rejected);
    if (rejected)
        ALOGW("vendor.ubuntu.input: %d entries rejected in \"%s\"", rejected, value);
    for (i = 0; i < n && added < max; i++) {
        struct source *s = &g_src[g_nsrc];
        snprintf(path, sizeof(path), "/dev/input/%s", names[i]);
        s->real = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (s->real < 0) {
            ALOGW("input %s: %s", path, strerror(errno));
            continue;
        }
        g_copy[i].fd = make_copy(s->real, i, out[added], UB_DEV_LEN);
        if (g_copy[i].fd < 0) {
            ALOGE("input %s: cannot make a uinput copy: %s", path, strerror(errno));
            close(s->real);
            continue;
        }
        s->copy = i;
        snprintf(s->node, sizeof(s->node), "%s", names[i]);
        ALOGI("input %s shared as pc-ubuntu-input-%d (%s)", path, i, out[added]);
        g_nsrc++;
        added++;
    }

    /* The generic copies, for whatever is plugged in later. GNOME cannot see
     * a device that appears after it started (no udev in the container), so
     * these exist from the start and hot-plugged devices feed into them. */
    for (i = GENERIC_POINTER; i <= GENERIC_KEYBOARD && added < max; i++) {
        g_copy[i].fd = make_generic(i, out[added], UB_DEV_LEN);
        if (g_copy[i].fd < 0) {
            ALOGW("generic %s copy: %s", i == GENERIC_POINTER ? "pointer" : "keyboard",
                  strerror(errno));
            continue;
        }
        ALOGI("generic %s for hot-plugged devices: pc-ubuntu-input-%d (%s)",
              i == GENERIC_POINTER ? "pointer" : "keyboard", i, out[added]);
        added++;
    }
    /* Extra mice and keyboards already plugged in at boot. */
    if ((d = opendir("/dev/input"))) {
        while ((e = readdir(d)))
            try_add_source(e->d_name);
        closedir(d);
    }
    return added;
}

/* ------------------------------------------------------------ switching ---- */

/* Run /usr/local/sbin/pc-seat <arg> inside Ubuntu: its PID and mount
 * namespaces and its root. The PID namespace matters: loginctl talks to
 * Ubuntu's D-Bus and logind, which identify their caller by PID, and a process
 * left in Android's namespace has none they can see -- it failed in ~50 ms
 * with nothing logged, while the same script run from an ssh shell inside
 * Ubuntu worked. setns(CLONE_NEWPID) applies to children only, hence the
 * second fork. The script's output and exit status go to the log. */
static int run_seat(const char *arg)
{
    char path[64], out[512];
    pid_t sd = g_systemd ? *g_systemd : 0, pid;
    int status = -1, i, mnt, pidns, root, pfd[2];
    ssize_t n, len = 0;

    if (sd <= 0)
        return -1;
    snprintf(path, sizeof(path), "/proc/%d/ns/mnt", (int)sd);
    mnt = open(path, O_RDONLY | O_CLOEXEC);
    snprintf(path, sizeof(path), "/proc/%d/ns/pid", (int)sd);
    pidns = open(path, O_RDONLY | O_CLOEXEC);
    snprintf(path, sizeof(path), "/proc/%d/root", (int)sd);
    root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (mnt < 0 || pidns < 0 || root < 0 || pipe2(pfd, O_CLOEXEC) < 0) {
        ALOGE("pc-seat %s: cannot open Ubuntu's namespaces: %s", arg, strerror(errno));
        if (mnt >= 0) close(mnt);
        if (pidns >= 0) close(pidns);
        if (root >= 0) close(root);
        return -1;
    }
    pid = fork();
    if (pid == 0) {
        static char *const env[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL };
        char *const argv[] = { "pc-seat", (char *)arg, NULL };
        pid_t inner;
        int st;

        dup2(pfd[1], 1);
        dup2(pfd[1], 2);
        if (setns(pidns, CLONE_NEWPID) < 0 || setns(mnt, CLONE_NEWNS) < 0 ||
            fchdir(root) < 0 || chroot(".") < 0 || chdir("/") < 0) {
            dprintf(2, "enter Ubuntu: %s\n", strerror(errno));
            _exit(126);
        }
        inner = fork();         /* the first process in Ubuntu's PID namespace */
        if (inner == 0) {
            execve("/usr/local/sbin/pc-seat", argv, env);
            dprintf(2, "exec pc-seat: %s\n", strerror(errno));
            _exit(127);
        }
        if (inner < 0 || waitpid(inner, &st, 0) != inner)
            _exit(125);
        _exit(WIFEXITED(st) ? WEXITSTATUS(st) : 124);
    }
    close(pfd[1]);
    close(mnt);
    close(pidns);
    close(root);
    if (pid < 0) {
        close(pfd[0]);
        return -1;
    }
    fcntl(pfd[0], F_SETFL, O_NONBLOCK);
    for (i = 0; i < 300; i++) {         /* GNOME's first start takes a few s */
        while (len < (ssize_t)sizeof(out) - 1 &&
               (n = read(pfd[0], out + len, sizeof(out) - 1 - (size_t)len)) > 0)
            len += n;
        if (waitpid(pid, &status, WNOHANG) == pid)
            break;
        usleep(50 * 1000);
        status = -1;
    }
    if (status == -1) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        ALOGE("pc-seat %s: timed out", arg);
        close(pfd[0]);
        return -1;
    }
    while (len < (ssize_t)sizeof(out) - 1 &&
           (n = read(pfd[0], out + len, sizeof(out) - 1 - (size_t)len)) > 0)
        len += n;
    close(pfd[0]);
    out[len] = '\0';
    status = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (status != 0)
        ALOGE("pc-seat %s: exit %d: %s", arg, status, len ? out : "(no output)");
    else
        ALOGI("pc-seat %s: done", arg);
    return status;
}

static void grab(int on)
{
    int i;

    for (i = 0; i < g_nsrc; i++)
        if (ioctl(g_src[i].real, EVIOCGRAB, on) < 0)
            ALOGW("%sgrab %s: %s", on ? "" : "un", g_src[i].node, strerror(errno));
}

/* Lift every key still down on the copies, so GNOME does not come back to a
 * held Ctrl+Alt from the combo that took the screen away. */
static void release_copies(void)
{
    struct input_event up = { .type = EV_KEY }, syn = { .type = EV_SYN, .code = SYN_REPORT };
    int i, code;

    for (i = 0; i < MAX_COPIES; i++) {
        if (g_copy[i].fd < 0)
            continue;
        for (code = 0; code < KEY_CNT; code++)
            if (TEST(code, g_copy[i].down)) {
                up.code = (unsigned short)code;
                if (write(g_copy[i].fd, &up, sizeof(up)) < 0)
                    break;
            }
        memset(g_copy[i].down, 0, sizeof(g_copy[i].down));
        if (write(g_copy[i].fd, &syn, sizeof(syn)) < 0)
            continue;
    }
}

static void to_ubuntu(void)
{
    if (g_screen == UB_SWITCH_UBUNTU || !g_systemd || *g_systemd <= 0)
        return;
    ALOGI("screen: switching to Ubuntu");
    grab(1);                                   /* Android stops getting input */
    __system_property_set("vendor.hwc.master", "ubuntu");   /* and the screen */
    usleep(100 * 1000);
    if (run_seat("ubuntu") != 0) {
        ALOGE("screen: GNOME did not take the screen; giving it back to Android");
        __system_property_set("vendor.hwc.master", "android");
        grab(0);
        return;
    }
    g_screen = UB_SWITCH_UBUNTU;
    __system_property_set("vendor.ubuntu.screen", "ubuntu");
}

static void to_android(int ask_ubuntu)
{
    if (g_screen == UB_SWITCH_ANDROID)
        return;
    ALOGI("screen: switching to Android");
    release_copies();
    if (ask_ubuntu && run_seat("android") != 0)
        ALOGW("screen: Ubuntu did not let go cleanly; taking the screen anyway");
    __system_property_set("vendor.hwc.master", "android");
    grab(0);
    g_screen = UB_SWITCH_ANDROID;
    __system_property_set("vendor.ubuntu.screen", "android");
}

void ui_reset_to_android(void)
{
    pthread_mutex_lock(&g_lock);
    to_android(0);
    pthread_mutex_unlock(&g_lock);
}

/* --------------------------------------------------------------- thread ---- */

static void emit(int c, const struct input_event *ev)
{
    struct copy *cp;

    if (c < 0 || c >= MAX_COPIES || (cp = &g_copy[c])->fd < 0)
        return;
    if (ev->type == EV_KEY && ev->code < KEY_CNT) {
        unsigned long bit = 1UL << (ev->code % (8 * sizeof(long)));
        if (ev->value)
            cp->down[ev->code / (8 * sizeof(long))] |= bit;
        else
            cp->down[ev->code / (8 * sizeof(long))] &= ~bit;
    }
    if (write(cp->fd, ev, sizeof(*ev)) < 0 && errno != EAGAIN)
        ALOGW("forward to pc-ubuntu-input-%d: %s", c, strerror(errno));
}

static void forward(const struct source *s, const struct input_event *ev)
{
    if (s->copy >= 0) {
        emit(s->copy, ev);
        return;
    }
    switch (ub_route(ev->type, ev->code)) {
    case UB_ROUTE_POINTER:  emit(GENERIC_POINTER, ev); break;
    case UB_ROUTE_KEYBOARD: emit(GENERIC_KEYBOARD, ev); break;
    case UB_ROUTE_BOTH:     emit(GENERIC_POINTER, ev); emit(GENERIC_KEYBOARD, ev); break;
    case UB_ROUTE_DROP:     break;
    }
}

/* New nodes in /dev/input. ueventd creates the node and then sets its
 * owner and mode, so IN_ATTRIB is the moment it can be opened. */
static void hotplug(int ino)
{
    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t n;
    char *p;

    while ((n = read(ino, buf, sizeof(buf))) > 0)
        for (p = buf; p < buf + n; p += sizeof(struct inotify_event) + ((struct inotify_event *)p)->len) {
            struct inotify_event *e = (struct inotify_event *)p;
            if (e->len) {
                pthread_mutex_lock(&g_lock);
                try_add_source(e->name);
                pthread_mutex_unlock(&g_lock);
            }
        }
}

static void *thread_main(void *unused)
{
    struct pollfd pfd[MAX_SOURCES + 1];
    struct ub_combo combo = { 0 };
    char want[PROP_VALUE_MAX], seen[PROP_VALUE_MAX] = "";
    int i, nsrc, ino;

    (void)unused;
    ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (ino >= 0 && inotify_add_watch(ino, "/dev/input", IN_CREATE | IN_ATTRIB) < 0) {
        ALOGW("no input hot-plug: %s", strerror(errno));
        close(ino);
        ino = -1;
    }

    for (;;) {
        enum ub_switch sw = UB_SWITCH_NONE;

        pthread_mutex_lock(&g_lock);
        nsrc = g_nsrc;
        for (i = 0; i < nsrc; i++)
            pfd[i] = (struct pollfd){ .fd = g_src[i].real, .events = POLLIN };
        pthread_mutex_unlock(&g_lock);
        pfd[nsrc] = (struct pollfd){ .fd = ino, .events = POLLIN };

        poll(pfd, (nfds_t)nsrc + 1, 250);
        if (ino >= 0 && (pfd[nsrc].revents & POLLIN))
            hotplug(ino);

        pthread_mutex_lock(&g_lock);
        for (i = nsrc - 1; i >= 0; i--) {
            struct input_event ev[64];
            ssize_t n, k;
            if (!pfd[i].revents || i >= g_nsrc || g_src[i].real != pfd[i].fd)
                continue;
            while ((n = read(g_src[i].real, ev, sizeof(ev))) > 0)
                for (k = 0; k < n / (ssize_t)sizeof(ev[0]); k++) {
                    enum ub_switch c = ub_combo_feed(&combo, ev[k].type, ev[k].code, ev[k].value);
                    if (c != UB_SWITCH_NONE)
                        sw = c;
                    if (g_screen == UB_SWITCH_UBUNTU)
                        forward(&g_src[i], &ev[k]);
                }
            if ((n < 0 && errno == ENODEV) || (pfd[i].revents & (POLLHUP | POLLERR)))
                drop_source(i);         /* unplugged */
        }
        pthread_mutex_unlock(&g_lock);

        /* The property: tests, and a pclauncher tile later. */
        if (__system_property_get("vendor.ubuntu.screen", want) > 0 && strcmp(want, seen)) {
            snprintf(seen, sizeof(seen), "%s", want);
            if (!strcmp(want, "ubuntu"))
                sw = UB_SWITCH_UBUNTU;
            else if (!strcmp(want, "android"))
                sw = UB_SWITCH_ANDROID;
        }
        if (sw != UB_SWITCH_NONE) {
            pthread_mutex_lock(&g_lock);
            if (sw == UB_SWITCH_UBUNTU)
                to_ubuntu();
            else
                to_android(1);
            pthread_mutex_unlock(&g_lock);
            __system_property_get("vendor.ubuntu.screen", seen);
        }
    }
    return NULL;
}

void ui_start(volatile pid_t *systemd)
{
    pthread_t t;

    sigset_t block, old;

    g_systemd = systemd;
    __system_property_set("vendor.ubuntu.screen", "android");
    /* The main thread's stop logic relies on SIGTERM and SIGALRM interrupting
     * its waitpid(). A thread that could also take them would steal them, so
     * this one is created with them blocked. */
    sigemptyset(&block);
    sigaddset(&block, SIGTERM);
    sigaddset(&block, SIGINT);
    sigaddset(&block, SIGALRM);
    pthread_sigmask(SIG_BLOCK, &block, &old);
    if (pthread_create(&t, NULL, thread_main, NULL) == 0)
        pthread_detach(t);
    else
        ALOGE("screen switching disabled: cannot start its thread");
    pthread_sigmask(SIG_SETMASK, &old, NULL);
}
