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
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <log/log.h>

#define MAX_INPUTS 8
#define LONGS(bits) (((bits) + 8 * sizeof(long) - 1) / (8 * sizeof(long)))
#define TEST(bit, arr) (((arr)[(bit) / (8 * sizeof(long))] >> ((bit) % (8 * sizeof(long)))) & 1)

struct shared_input {
    int real;                       /* Android's node, read always, grabbed for Ubuntu */
    int copy;                       /* uinput fd; its node is what Ubuntu sees */
    unsigned long down[LONGS(KEY_CNT)];   /* keys pressed on the copy */
    char name[UB_INPUT_LEN];
};

static struct shared_input g_in[MAX_INPUTS];
static int g_n;
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

int ui_setup(char out[][UB_DEV_LEN], int max)
{
    char value[PROP_VALUE_MAX] = "", names[MAX_INPUTS][UB_INPUT_LEN], path[48];
    int n, i, rejected = 0, added = 0;

    if (__system_property_get("vendor.ubuntu.input", value) <= 0)
        return 0;
    n = ub_parse_inputs(value, names, MAX_INPUTS, &rejected);
    if (rejected)
        ALOGW("vendor.ubuntu.input: %d entries rejected in \"%s\"", rejected, value);
    for (i = 0; i < n && added < max; i++) {
        struct shared_input *s = &g_in[g_n];
        snprintf(path, sizeof(path), "/dev/input/%s", names[i]);
        s->real = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (s->real < 0) {
            ALOGW("input %s: %s", path, strerror(errno));
            continue;
        }
        s->copy = make_copy(s->real, g_n, out[added], UB_DEV_LEN);
        if (s->copy < 0) {
            ALOGE("input %s: cannot make a uinput copy: %s", path, strerror(errno));
            close(s->real);
            continue;
        }
        snprintf(s->name, sizeof(s->name), "%s", names[i]);
        ALOGI("input %s shared as pc-ubuntu-input-%d (%s)", path, g_n, out[added]);
        g_n++;
        added++;
    }
    return added;
}

/* ------------------------------------------------------------ switching ---- */

/* Run /usr/local/sbin/pc-seat <arg> inside Ubuntu: its mount namespace and
 * root, so loginctl talks to Ubuntu's logind over Ubuntu's D-Bus socket. */
static int run_seat(const char *arg)
{
    char path[64];
    pid_t sd = g_systemd ? *g_systemd : 0, pid;
    int status, i, mnt, root;

    if (sd <= 0)
        return -1;
    snprintf(path, sizeof(path), "/proc/%d/ns/mnt", (int)sd);
    if ((mnt = open(path, O_RDONLY | O_CLOEXEC)) < 0)
        return -1;
    snprintf(path, sizeof(path), "/proc/%d/root", (int)sd);
    if ((root = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) < 0) {
        close(mnt);
        return -1;
    }
    pid = fork();
    if (pid == 0) {
        static char *const env[] = { "PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL };
        char *const argv[] = { "pc-seat", (char *)arg, NULL };
        if (setns(mnt, CLONE_NEWNS) < 0 || fchdir(root) < 0 || chroot(".") < 0 || chdir("/") < 0)
            _exit(126);
        execve("/usr/local/sbin/pc-seat", argv, env);
        _exit(127);
    }
    close(mnt);
    close(root);
    if (pid < 0)
        return -1;
    for (i = 0; i < 300; i++) {         /* GNOME's first start takes a few s */
        if (waitpid(pid, &status, WNOHANG) == pid)
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        usleep(50 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    ALOGE("pc-seat %s: timed out", arg);
    return -1;
}

static void grab(int on)
{
    int i;

    for (i = 0; i < g_n; i++)
        if (ioctl(g_in[i].real, EVIOCGRAB, on) < 0)
            ALOGW("%sgrab %s: %s", on ? "" : "un", g_in[i].name, strerror(errno));
}

/* Lift every key still down on the copies, so GNOME does not come back to a
 * held Ctrl+Alt from the combo that took the screen away. */
static void release_copies(void)
{
    struct input_event up = { .type = EV_KEY }, syn = { .type = EV_SYN, .code = SYN_REPORT };
    int i, code;

    for (i = 0; i < g_n; i++) {
        for (code = 0; code < KEY_CNT; code++)
            if (TEST(code, g_in[i].down)) {
                up.code = (unsigned short)code;
                if (write(g_in[i].copy, &up, sizeof(up)) < 0)
                    break;
            }
        memset(g_in[i].down, 0, sizeof(g_in[i].down));
        if (write(g_in[i].copy, &syn, sizeof(syn)) < 0)
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

static void forward(struct shared_input *s, const struct input_event *ev)
{
    if (ev->type == EV_KEY && ev->code < KEY_CNT) {
        unsigned long bit = 1UL << (ev->code % (8 * sizeof(long)));
        if (ev->value)
            s->down[ev->code / (8 * sizeof(long))] |= bit;
        else
            s->down[ev->code / (8 * sizeof(long))] &= ~bit;
    }
    if (write(s->copy, ev, sizeof(*ev)) < 0 && errno != EAGAIN)
        ALOGW("forward to %s: %s", s->name, strerror(errno));
}

static void *thread_main(void *unused)
{
    struct pollfd pfd[MAX_INPUTS];
    struct ub_combo combo = { 0 };
    char want[PROP_VALUE_MAX], seen[PROP_VALUE_MAX] = "";
    int i;

    (void)unused;
    for (i = 0; i < g_n; i++)
        pfd[i] = (struct pollfd){ .fd = g_in[i].real, .events = POLLIN };

    for (;;) {
        enum ub_switch sw = UB_SWITCH_NONE;

        poll(pfd, (nfds_t)g_n, 250);
        for (i = 0; i < g_n; i++) {
            struct input_event ev[64];
            ssize_t n, k;
            if (!(pfd[i].revents & POLLIN))
                continue;
            while ((n = read(g_in[i].real, ev, sizeof(ev))) > 0)
                for (k = 0; k < n / (ssize_t)sizeof(ev[0]); k++) {
                    enum ub_switch c = ub_combo_feed(&combo, ev[k].type, ev[k].code, ev[k].value);
                    if (c != UB_SWITCH_NONE)
                        sw = c;
                    if (g_screen == UB_SWITCH_UBUNTU)
                        forward(&g_in[i], &ev[k]);
                }
        }
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
