/*
 * pc_ubuntu_launch -- start Ubuntu's systemd as PID 1 of its own namespaces,
 * and supervise it. Started by Android init as the vendor.ubuntu service.
 *
 * Design: doc/10-ubuntu-alongside-android.md, sections 3.3 to 3.6. In short:
 *
 *   launcher (Android's PID namespace, u:r:ubuntu_launch:s0)
 *     - private mount namespace, mounts /dev/block/by-name/ubuntu there only,
 *       so Android never sees the Ubuntu filesystem
 *     - creates /sys/fs/cgroup/ubuntu with memory and pids ceilings
 *     - clone(NEWPID | NEWNS | NEWUTS | NEWIPC); the child waits on a pipe
 *       until it has been moved into the ubuntu cgroup, then unshares the
 *       cgroup namespace, so systemd sees that cgroup as its root
 *     - child: /proc, read-only /sys, cgroup2, a minimal /dev, pivot_root,
 *       drops the capabilities that reach past the namespaces, and execs
 *       /vendor/bin/pc_ubuntu_init through a descriptor opened before
 *       pivot_root. SELinux moves it to u:r:ubuntu:s0 on that exec, and it
 *       execs systemd (see pc_ubuntu_init.c for why it is not systemd directly)
 *     - waits; reboot / poweroff / crash are told apart by how PID 1 died
 *
 * The network namespace is shared with Android in step 1 (section 3.6), so
 * CAP_NET_ADMIN is one of the capabilities dropped: Ubuntu must not be able to
 * change Android's interfaces, routes or firewall.
 *
 * Everything that decides something lives in ubuntu_lib.c and is tested on the
 * host; this file is the system calls around it.
 */

#define _GNU_SOURCE     /* clone(), unshare(), pipe2() */
#define LOG_TAG "pc_ubuntu_launch"

#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/system_properties.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <log/log.h>

#include "ubuntu_lib.h"

#define UBUNTU_DEV   "/dev/block/by-name/ubuntu"
#define UBUNTU_ROOT  "/mnt/vendor/ubuntu"
#define UBUNTU_CTX   "context=u:object_r:ubuntu_file:s0"
#define UBUNTU_INIT  "/vendor/bin/pc_ubuntu_init"
#define CGROUP_ROOT  "/sys/fs/cgroup"
#define CGROUP_NAME  "ubuntu"
#define STOP_TIMEOUT 20     /* seconds systemd gets to shut down, R8 */

/*
 * systemd's container "halt" signal is SIGRTMIN+3 *as glibc numbers it*:
 * glibc's SIGRTMIN is 34, so 37. Bionic reserves more real-time signals for
 * itself (SIGRTMIN = __SIGRTMIN + __SIGRT_RESERVED), so SIGRTMIN+3 compiled
 * here is a different signal that systemd ignores. Found on the HP laptop:
 * the halt was sent and systemd sat out the whole 20 s until SIGKILL.
 */
#define SYSTEMD_SIGHALT (__SIGRTMIN + 2 + 3)

#define DNS_RECHECK  10     /* seconds between gateway lookups until one is found */

static volatile sig_atomic_t g_term, g_alarm;
static int g_dns_final;     /* resolv.conf has its real servers, stop looking */

static void on_term(int sig) { (void)sig; g_term = 1; }
static void on_alarm(int sig) { (void)sig; g_alarm = 1; }

static void set_state(const char *state)
{
    __system_property_set("vendor.ubuntu.state", state);
    ALOGI("state %s", state);
}

static long prop_long(const char *name, long def)
{
    char value[PROP_VALUE_MAX] = "";
    char *end;
    long v;

    if (__system_property_get(name, value) <= 0)
        return def;
    v = strtol(value, &end, 10);
    return *end ? def : v;
}

/* --------------------------------------------------------------- child ---- */

/* Capabilities that act outside the namespaces, removed from the bounding set
 * so nothing in Ubuntu, including setuid binaries, can hold them. */
static const int dropped_caps[] = {
    CAP_SYS_MODULE,      /* loading kernel modules */
    CAP_SYS_TIME,        /* Android owns the clock */
    CAP_SYS_RAWIO,       /* iopl, /dev/mem, raw SCSI */
    CAP_MKNOD,           /* a block node for Android's own disk */
    CAP_DAC_READ_SEARCH, /* open_by_handle_at() walks out of a mount namespace;
                            FHANDLE=y makes that reachable */
    CAP_NET_ADMIN,       /* the network namespace is Android's (step 1) */
    CAP_MAC_ADMIN,
    CAP_MAC_OVERRIDE,
    CAP_SYSLOG,
    CAP_WAKE_ALARM,
    CAP_BLOCK_SUSPEND,
    CAP_AUDIT_CONTROL,
    CAP_SYS_PACCT,
};

static int must(int ret, const char *what)
{
    if (ret < 0)
        ALOGE("%s: %s", what, strerror(errno));
    return ret;
}

static int mount_at(const char *root, const char *rel, const char *src, const char *type,
                    unsigned long flags, const char *data)
{
    char path[256];

    snprintf(path, sizeof(path), "%s%s", root, rel);
    mkdir(path, 0755);
    if (mount(src, path, type, flags, data) < 0) {
        ALOGE("mount %s on %s: %s", type ? type : src, path, strerror(errno));
        return -1;
    }
    return 0;
}

/* Bind `rel` onto itself and make it read-only. */
static int readonly_at(const char *root, const char *rel)
{
    char path[256];

    snprintf(path, sizeof(path), "%s%s", root, rel);
    if (mount(path, path, NULL, MS_BIND, NULL) < 0 ||
        mount(NULL, path, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC,
              NULL) < 0) {
        ALOGE("read-only %s: %s", path, strerror(errno));
        return -1;
    }
    return 0;
}

static int make_dev(const char *root)
{
    static const struct { const char *name; unsigned maj, min; mode_t mode; } nodes[] = {
        { "null", 1, 3, 0666 }, { "zero", 1, 5, 0666 }, { "full", 1, 7, 0666 },
        { "random", 1, 8, 0666 }, { "urandom", 1, 9, 0666 }, { "tty", 5, 0, 0666 },
        /* No real console: systemd's status output goes nowhere, its
         * journal keeps everything. */
        { "console", 1, 3, 0600 },
    };
    static const struct { const char *name, *target; } links[] = {
        { "fd", "/proc/self/fd" }, { "stdin", "/proc/self/fd/0" },
        { "stdout", "/proc/self/fd/1" }, { "stderr", "/proc/self/fd/2" },
        { "ptmx", "pts/ptmx" },
    };
    char path[256];
    size_t i;

    if (mount_at(root, "/dev", "tmpfs", "tmpfs", MS_NOSUID | MS_NOEXEC, "mode=0755,size=4m") < 0)
        return -1;
    for (i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) {
        snprintf(path, sizeof(path), "%s/dev/%s", root, nodes[i].name);
        if (mknod(path, S_IFCHR | nodes[i].mode, makedev(nodes[i].maj, nodes[i].min)) < 0 ||
            chmod(path, nodes[i].mode) < 0) {
            ALOGE("mknod %s: %s", path, strerror(errno));
            return -1;
        }
    }
    for (i = 0; i < sizeof(links) / sizeof(links[0]); i++) {
        snprintf(path, sizeof(path), "%s/dev/%s", root, links[i].name);
        if (must(symlink(links[i].target, path), path) < 0)
            return -1;
    }
    /* gid 5 is "tty" in Ubuntu's /etc/group. */
    if (mount_at(root, "/dev/pts", "devpts", "devpts", MS_NOSUID | MS_NOEXEC,
                 "newinstance,ptmxmode=0666,mode=0620,gid=5") < 0 ||
        mount_at(root, "/dev/shm", "tmpfs", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") < 0)
        return -1;
    return 0;
}

struct child_args {
    int sync_fd;        /* read end; one byte once the parent has attached us */
    int init_fd;        /* O_PATH of UBUNTU_INIT, still valid after pivot_root */
};

static int child_main(void *arg)
{
    const struct child_args *a = arg;
    static char *const argv[] = { "pc_ubuntu_init", NULL };
    static char *const envp[] = {
        "container=pc-android",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
    };
    const char *r = UBUNTU_ROOT;
    ssize_t n;
    char c;
    size_t i;

    /* If the launcher dies, by SIGKILL from init or otherwise, take the whole
     * namespace with it rather than leave an unsupervised Ubuntu running. */
    prctl(PR_SET_PDEATHSIG, SIGKILL);

    /* Wait until the parent has written us into the ubuntu cgroup, so the
     * cgroup namespace below is rooted there. The parent sends one byte; EOF
     * instead means it died before PDEATHSIG was armed (getppid() cannot
     * tell: across a PID namespace it is always 0). */
    while ((n = read(a->sync_fd, &c, 1)) < 0 && errno == EINTR)
        ;
    close(a->sync_fd);
    if (n != 1)
        _exit(1);

    if (must(unshare(CLONE_NEWCGROUP), "unshare cgroup") < 0 ||
        must(mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL), "rprivate") < 0 ||
        must(mount(r, r, NULL, MS_BIND | MS_REC, NULL), "bind root") < 0)
        _exit(1);

    if (mount_at(r, "/proc", "proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0 ||
        readonly_at(r, "/proc/sys") < 0 ||
        readonly_at(r, "/proc/sysrq-trigger") < 0 ||
        /* Read-only /sys is also what tells systemd it has no udev to run. */
        mount_at(r, "/sys", "sysfs", "sysfs", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0 ||
        mount_at(r, "/sys/fs/cgroup", "cgroup2", "cgroup2", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0 ||
        make_dev(r) < 0)
        _exit(1);

    if (must(sethostname("ubuntu", 6), "sethostname") < 0 ||
        must(chdir(r), "chdir root") < 0 ||
        must((int)syscall(SYS_pivot_root, ".", "."), "pivot_root") < 0 ||
        must(umount2(".", MNT_DETACH), "detach old root") < 0 ||
        must(chdir("/"), "chdir /") < 0)
        _exit(1);

    for (i = 0; i < sizeof(dropped_caps) / sizeof(dropped_caps[0]); i++)
        if (prctl(PR_CAPBSET_DROP, dropped_caps[i], 0, 0, 0) < 0 && errno != EINVAL)
            ALOGW("cannot drop capability %d: %s", dropped_caps[i], strerror(errno));

    syscall(SYS_execveat, a->init_fd, "", argv, envp, AT_EMPTY_PATH);
    ALOGE("exec %s: %s", UBUNTU_INIT, strerror(errno));
    _exit(127);
}

/* -------------------------------------------------------------- parent ---- */

/* Read every routing table and pick the default gateway, for resolv.conf. */
static int find_gateway(char *out, size_t outlen)
{
    struct {
        struct nlmsghdr nh;
        struct rtmsg rt;
    } req = {
        .nh = { .nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg)), .nlmsg_type = RTM_GETROUTE,
                .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 1 },
        .rt = { .rtm_family = AF_INET, .rtm_table = RT_TABLE_UNSPEC },
    };
    static char buf[32768] __attribute__((aligned(8)));
    int fd, found = -1;
    ssize_t n;

    fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0)
        return -1;
    if (send(fd, &req, req.nh.nlmsg_len, 0) < 0) {
        close(fd);
        return -1;
    }
    /* A dump arrives as several datagrams and ends with NLMSG_DONE. */
    while (found < 0 && (n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        const struct nlmsghdr *nh;
        size_t len = (size_t)n;
        int last = 0;

        found = ub_default_gateway(buf, len, out, outlen);
        for (nh = (const struct nlmsghdr *)buf; NLMSG_OK(nh, len); nh = NLMSG_NEXT(nh, len))
            if (nh->nlmsg_type == NLMSG_DONE || nh->nlmsg_type == NLMSG_ERROR)
                last = 1;
        if (last)
            break;
    }
    close(fd);
    return found;
}

static int mount_ubuntu(void)
{
    if (must(unshare(CLONE_NEWNS), "unshare mount") < 0 ||
        must(mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL), "rprivate") < 0)
        return -1;
    mkdir(UBUNTU_ROOT, 0700);
    if (mount(UBUNTU_DEV, UBUNTU_ROOT, "ext4", MS_NODEV | MS_NOATIME, UBUNTU_CTX) < 0) {
        ALOGE("mount %s: %s", UBUNTU_DEV, strerror(errno));
        return -1;
    }
    return 0;
}

static void setup_cgroup(void)
{
    char text[4096] = "";
    long total_kb = -1, percent = prop_long("vendor.ubuntu.mem_percent", 75);
    long pids_max = prop_long("vendor.ubuntu.pids_max", 8192);
    int fd = open("/proc/meminfo", O_RDONLY | O_CLOEXEC);
    ssize_t n;
    int err;

    if (fd >= 0) {
        n = read(fd, text, sizeof(text) - 1);
        text[n > 0 ? n : 0] = '\0';
        close(fd);
        total_kb = ub_meminfo_total_kb(text);
    }
    if (percent <= 0 || percent > 100)
        percent = 75;
    err = ub_cgroup_setup(CGROUP_ROOT, CGROUP_NAME,
                          total_kb > 0 ? total_kb * 1024LL * percent / 100 : 0, pids_max);
    if (err < 0)
        ALOGW("cgroup %s/%s: %s (running without limits)", CGROUP_ROOT, CGROUP_NAME,
              strerror(-err));
}

/*
 * Write resolv.conf. The launcher starts at post-fs-data, usually before WiFi
 * has a network, so the first pass often finds no gateway and writes only the
 * fallback -- which on the bring-up network does not answer at all. The
 * supervisor loop therefore calls this again every DNS_RECHECK seconds until
 * a gateway (or vendor.ubuntu.dns) has been written. Returns 1 once final.
 */
static int setup_dns(void)
{
    char servers[PROP_VALUE_MAX] = "", gw[64] = "";
    int err;

    __system_property_get("vendor.ubuntu.dns", servers);
    if (!*servers && find_gateway(gw, sizeof(gw)) < 0)
        gw[0] = '\0';
    if (!*servers && !*gw && g_dns_final >= 0) {
        /* Nothing better than the fallback yet; write it once. */
        if (g_dns_final == 0) {
            if ((err = ub_write_resolv(UBUNTU_ROOT "/etc/resolv.conf", NULL, NULL)) < 0)
                ALOGW("resolv.conf: %s", strerror(-err));
            ALOGI("dns: %s for now, no network yet", UB_FALLBACK_DNS);
            g_dns_final = -1;
        }
        return 0;
    }
    err = ub_write_resolv(UBUNTU_ROOT "/etc/resolv.conf", servers, gw);
    if (err < 0) {
        ALOGW("resolv.conf: %s", strerror(-err));
        return 0;
    }
    ALOGI("dns: %s", *servers ? servers : gw);
    g_dns_final = 1;
    return 1;
}

/* Start one Ubuntu. Returns systemd's PID in our namespace, or -1. */
static pid_t start_ubuntu(int init_fd)
{
    static char stack[64 * 1024] __attribute__((aligned(16)));
    struct child_args args;
    char num[16];
    int pfd[2];
    pid_t pid;
    int err;

    /* A fresh cgroup every time; see ub_cgroup_reset() for why. */
    if ((err = ub_cgroup_reset(CGROUP_ROOT, CGROUP_NAME)) < 0)
        ALOGW("reset %s/%s: %s", CGROUP_ROOT, CGROUP_NAME, strerror(-err));
    setup_cgroup();

    if (pipe2(pfd, O_CLOEXEC) < 0)
        return -1;
    args.sync_fd = pfd[0];
    args.init_fd = init_fd;
    pid = clone(child_main, stack + sizeof(stack),
                CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUTS | CLONE_NEWIPC | SIGCHLD, &args);
    close(pfd[0]);
    if (pid < 0) {
        ALOGE("clone: %s", strerror(errno));
        close(pfd[1]);
        return -1;
    }
    err = ub_cgroup_attach(CGROUP_ROOT, CGROUP_NAME, pid);
    if (err < 0)
        ALOGW("attach %d to %s: %s", pid, CGROUP_NAME, strerror(-err));
    if (write(pfd[1], "g", 1) != 1)    /* releases the child */
        ALOGE("release child: %s", strerror(errno));
    close(pfd[1]);
    ALOGI("systemd started, pid %d", pid);
    snprintf(num, sizeof(num), "%d", (int)getpid());
    __system_property_set("vendor.ubuntu.pid", num);
    return pid;
}

/* Wait for systemd. On SIGTERM from init, ask it to halt (SIGRTMIN+3 is the
 * container halt signal, see systemd's CONTAINER_INTERFACE), then kill it. */
static int wait_ubuntu(pid_t pid)
{
    int status, asked = 0;

    if (!g_dns_final || g_dns_final < 0)
        alarm(DNS_RECHECK);
    for (;;) {
        if (g_alarm && !asked) {
            g_alarm = 0;
            if (setup_dns() == 0)
                alarm(DNS_RECHECK);
        }
        if (g_term && !asked) {
            ALOGI("stopping: asking systemd to halt");
            kill(pid, SYSTEMD_SIGHALT);
            alarm(STOP_TIMEOUT);
            asked = 1;
        } else if (g_alarm) {
            ALOGW("systemd did not halt within %d s, killing the namespace", STOP_TIMEOUT);
            kill(pid, SIGKILL);   /* PID 1 of a namespace takes it all down */
            g_alarm = 0;
        }
        if (waitpid(pid, &status, 0) == pid)
            return status;
        if (errno != EINTR)
            return 0;
    }
}

/* PID 1 is gone, so the kernel is killing the rest; give it a moment. */
static void wait_cgroup_empty(void)
{
    int i;

    for (i = 0; i < 50 && ub_cgroup_empty(CGROUP_ROOT, CGROUP_NAME) == 0; i++)
        usleep(100 * 1000);
}

/* Sleep `seconds`, returning early on SIGTERM. */
static void pause_for(int seconds)
{
    struct timespec ts = { .tv_sec = seconds };

    while (!g_term && nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

/*
 * --halt: stop Ubuntu gracefully, which `stop vendor.ubuntu` cannot do --
 * init's stop is SIGKILL (or SIGTERM for 200 ms with gentle_kill), with no
 * time for systemd to shut down. This sends the running launcher the SIGTERM
 * it treats as "halt systemd", then waits for it to report stopped. Run by the
 * vendor.ubuntu-halt service on `setprop vendor.ubuntu.request halt`.
 */
static int halt_running(void)
{
    char value[PROP_VALUE_MAX] = "", path[64], comm[32] = "";
    int fd, i;
    pid_t pid;
    ssize_t n;

    if (__system_property_get("vendor.ubuntu.state", value) <= 0 || strcmp(value, "running"))
        return 0;
    __system_property_get("vendor.ubuntu.pid", value);
    pid = (pid_t)atoi(value);
    snprintf(path, sizeof(path), "/proc/%d/comm", (int)pid);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    n = fd < 0 ? -1 : read(fd, comm, sizeof(comm) - 1);
    if (fd >= 0)
        close(fd);
    if (pid <= 1 || n <= 0 || strncmp(comm, "pc_ubuntu_launc", 15)) {
        ALOGE("halt: vendor.ubuntu.pid=%s is not the launcher", value);
        return 1;
    }
    ALOGI("halt: asking launcher %d to stop Ubuntu", pid);
    kill(pid, SIGTERM);
    for (i = 0; i < (STOP_TIMEOUT + 5) * 5; i++) {
        if (__system_property_get("vendor.ubuntu.state", value) > 0 && !strcmp(value, "stopped"))
            return 0;
        usleep(200 * 1000);
    }
    ALOGE("halt: Ubuntu did not stop within %d s", STOP_TIMEOUT + 5);
    return 1;
}

int main(int argc, char **argv)
{
    struct sigaction sa = { 0 };
    struct ub_backoff backoff = { 0 };
    int init_fd;

    sa.sa_handler = on_term;     /* no SA_RESTART: waitpid must return EINTR */
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, NULL);

    if (argc > 1 && !strcmp(argv[1], "--halt"))
        return halt_running();

    set_state("starting");
    if (mount_ubuntu() < 0) {
        set_state("failed");
        return 1;
    }
    setup_dns();
    init_fd = open(UBUNTU_INIT, O_PATH | O_CLOEXEC);
    if (init_fd < 0) {
        ALOGE("open %s: %s", UBUNTU_INIT, strerror(errno));
        set_state("failed");
        return 1;
    }

    while (!g_term) {
        pid_t pid = start_ubuntu(init_fd);
        int status, delay;

        if (pid < 0) {
            set_state("failed");
            return 1;
        }
        set_state("running");
        status = wait_ubuntu(pid);
        wait_cgroup_empty();
        if (g_term)
            break;

        switch (ub_exit_action(status)) {
        case UB_RESTART:
            ALOGI("reboot requested inside Ubuntu");
            set_state("starting");
            continue;
        case UB_STOP:
            ALOGI("poweroff requested inside Ubuntu");
            set_state("stopped");
            return 0;
        case UB_CRASH:
            delay = ub_backoff_next(&backoff, time(NULL));
            ALOGE("systemd died (status 0x%x)%s", status, delay < 0 ? ", giving up" : "");
            if (delay < 0) {
                set_state("failed");
                return 1;
            }
            set_state("starting");
            pause_for(delay);
            break;
        }
    }
    set_state("stopped");
    return 0;
}
