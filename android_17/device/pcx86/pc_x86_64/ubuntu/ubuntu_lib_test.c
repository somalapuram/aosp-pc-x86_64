/*
 * Host tests for ubuntu_lib. Run with ./run_tests.sh (plain cc, seconds), or
 * as the Soong host test pc_ubuntu_launch_test. Every function in ubuntu_lib.h
 * has a test here.
 */

#include "ubuntu_lib.h"

#include <arpa/inet.h>
#include <linux/input-event-codes.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(cond) do { \
    if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } \
} while (0)

/* waitpid() status words, built the way the kernel encodes them. */
#define KILLED_BY(sig) (sig)
#define EXITED(code)   (((code) & 0xff) << 8)

static void test_exit_action(void)
{
    CHECK(ub_exit_action(KILLED_BY(SIGHUP)) == UB_RESTART);
    CHECK(ub_exit_action(KILLED_BY(SIGINT)) == UB_STOP);
    CHECK(ub_exit_action(EXITED(0)) == UB_STOP);
    CHECK(ub_exit_action(EXITED(1)) == UB_CRASH);
    CHECK(ub_exit_action(EXITED(255)) == UB_CRASH);
    CHECK(ub_exit_action(KILLED_BY(SIGSEGV)) == UB_CRASH);
    CHECK(ub_exit_action(KILLED_BY(SIGKILL)) == UB_CRASH);
    CHECK(ub_exit_action(KILLED_BY(SIGABRT) | 0x80) == UB_CRASH);   /* with core dump */
}

static void test_backoff(void)
{
    struct ub_backoff b = { 0 };

    CHECK(ub_backoff_next(&b, 1000) == 1);
    CHECK(ub_backoff_next(&b, 1010) == 5);
    CHECK(ub_backoff_next(&b, 1020) == 30);
    CHECK(ub_backoff_next(&b, 1100) == -1);       /* 4th inside 5 minutes */
    CHECK(ub_backoff_next(&b, 1100) == -1);       /* and it stays given up */

    /* Crashes age out of the window. */
    memset(&b, 0, sizeof(b));
    CHECK(ub_backoff_next(&b, 0) == 1);
    CHECK(ub_backoff_next(&b, 100) == 5);
    CHECK(ub_backoff_next(&b, 200) == 30);
    CHECK(ub_backoff_next(&b, 300) == 30);        /* t=0 has expired */
    CHECK(ub_backoff_next(&b, 10000) == 1);       /* all expired */
}

static void test_meminfo(void)
{
    CHECK(ub_meminfo_total_kb("MemTotal:       16273512 kB\nMemFree: 1 kB\n") == 16273512);
    CHECK(ub_meminfo_total_kb("MemFree: 1 kB\nMemTotal: 2048 kB\n") == 2048);
    CHECK(ub_meminfo_total_kb("MemFree: 1 kB\n") == -1);
    CHECK(ub_meminfo_total_kb("MemTotal: kB\n") == -1);
    CHECK(ub_meminfo_total_kb("") == -1);
}

static char tmpdir[64];

static void read_text(const char *path, char *buf, size_t size)
{
    int fd = open(path, O_RDONLY);
    ssize_t n = fd < 0 ? -1 : read(fd, buf, size - 1);

    buf[n > 0 ? n : 0] = '\0';
    if (fd >= 0)
        close(fd);
}

static void test_cgroup(void)
{
    char path[256], buf[256];

    CHECK(ub_cgroup_setup(tmpdir, "ubuntu", 123456789LL, 8192) == 0);
    snprintf(path, sizeof(path), "%s/ubuntu/memory.max", tmpdir);
    read_text(path, buf, sizeof(buf));
    CHECK(strcmp(buf, "123456789") == 0);
    snprintf(path, sizeof(path), "%s/ubuntu/pids.max", tmpdir);
    read_text(path, buf, sizeof(buf));
    CHECK(strcmp(buf, "8192") == 0);
    /* Controllers are enabled one write at a time; the last one is what a
     * regular file keeps. */
    snprintf(path, sizeof(path), "%s/cgroup.subtree_control", tmpdir);
    read_text(path, buf, sizeof(buf));
    CHECK(strcmp(buf, "+pids") == 0);

    /* Made under init's umask (077), the cgroup must still be 0755. */
    {
        struct stat st;
        mode_t old = umask(077);
        CHECK(ub_cgroup_setup(tmpdir, "umasked", 0, 0) == 0);
        umask(old);
        snprintf(path, sizeof(path), "%s/umasked", tmpdir);
        CHECK(stat(path, &st) == 0 && (st.st_mode & 0777) == 0755);
    }

    /* Again: the directory already existing is fine. */
    CHECK(ub_cgroup_setup(tmpdir, "ubuntu", 0, 0) == 0);

    /* No limit asked for: the file is not touched. */
    CHECK(ub_cgroup_setup(tmpdir, "nolimit", 0, -1) == 0);
    snprintf(path, sizeof(path), "%s/nolimit/memory.max", tmpdir);
    CHECK(access(path, F_OK) < 0);

    /* A root that does not exist is an error, not a crash. */
    CHECK(ub_cgroup_setup("/nonexistent/cg", "ubuntu", 1, 1) == -ENOENT);

    /* Attach, then empty. */
    snprintf(path, sizeof(path), "%s/ubuntu/cgroup.procs", tmpdir);
    unlink(path);
    CHECK(ub_cgroup_empty(tmpdir, "ubuntu") == -ENOENT);
    CHECK(ub_cgroup_attach(tmpdir, "ubuntu", 4242) == 0);
    read_text(path, buf, sizeof(buf));
    CHECK(strcmp(buf, "4242") == 0);
    CHECK(ub_cgroup_empty(tmpdir, "ubuntu") == 0);
    CHECK(truncate(path, 0) == 0);
    CHECK(ub_cgroup_empty(tmpdir, "ubuntu") == 1);
    CHECK(ub_cgroup_attach(tmpdir, "missing", 1) == -ENOENT);
}

static void test_cgroup_reset(void)
{
    char path[256];

    /* What systemd leaves behind: nested cgroups. Interface files cannot be
     * modelled on a normal filesystem (cgroupfs removes them with the
     * directory), so this tree is directories only. */
    snprintf(path, sizeof(path), "%s/reset", tmpdir);
    CHECK(mkdir(path, 0755) == 0);
    snprintf(path, sizeof(path), "%s/reset/init.scope", tmpdir);
    CHECK(mkdir(path, 0755) == 0);
    snprintf(path, sizeof(path), "%s/reset/system.slice", tmpdir);
    CHECK(mkdir(path, 0755) == 0);
    snprintf(path, sizeof(path), "%s/reset/system.slice/ssh.service", tmpdir);
    CHECK(mkdir(path, 0755) == 0);

    CHECK(ub_cgroup_reset(tmpdir, "reset") == 0);
    snprintf(path, sizeof(path), "%s/reset", tmpdir);
    CHECK(access(path, F_OK) < 0 && errno == ENOENT);

    /* Nothing there yet: not an error. */
    CHECK(ub_cgroup_reset(tmpdir, "reset") == 0);

    /* A cgroup that cannot be removed (here: a regular file inside, standing
     * in for a cgroup that still has processes) is reported, not ignored. */
    snprintf(path, sizeof(path), "%s/busy", tmpdir);
    CHECK(mkdir(path, 0755) == 0);
    snprintf(path, sizeof(path), "%s/busy/cgroup.procs", tmpdir);
    close(open(path, O_WRONLY | O_CREAT, 0644));
    CHECK(ub_cgroup_reset(tmpdir, "busy") == -ENOTEMPTY);
}

/* Append one RTM_NEWROUTE to buf; gw may be NULL. Returns the new length. */
static size_t add_route(char *buf, size_t len, unsigned char family, unsigned char dst_len,
                        unsigned char type, unsigned table, const char *gw)
{
    struct nlmsghdr *nh = (struct nlmsghdr *)(buf + len);
    struct rtmsg *rt;
    struct rtattr *rta;

    memset(nh, 0, NLMSG_SPACE(sizeof(*rt) + 2 * RTA_SPACE(16)));
    nh->nlmsg_type = RTM_NEWROUTE;
    nh->nlmsg_len = NLMSG_LENGTH(sizeof(*rt));
    rt = NLMSG_DATA(nh);
    rt->rtm_family = family;
    rt->rtm_dst_len = dst_len;
    rt->rtm_type = type;
    rt->rtm_table = RT_TABLE_UNSPEC;

    rta = (struct rtattr *)((char *)nh + NLMSG_ALIGN(nh->nlmsg_len));
    rta->rta_type = RTA_TABLE;
    rta->rta_len = RTA_LENGTH(4);
    memcpy(RTA_DATA(rta), &table, 4);
    nh->nlmsg_len = NLMSG_ALIGN(nh->nlmsg_len) + RTA_ALIGN(rta->rta_len);

    if (gw) {
        rta = (struct rtattr *)((char *)nh + NLMSG_ALIGN(nh->nlmsg_len));
        rta->rta_type = RTA_GATEWAY;
        rta->rta_len = RTA_LENGTH(4);
        inet_pton(AF_INET, gw, RTA_DATA(rta));
        nh->nlmsg_len = NLMSG_ALIGN(nh->nlmsg_len) + RTA_ALIGN(rta->rta_len);
    }
    return len + NLMSG_ALIGN(nh->nlmsg_len);
}

static size_t add_done(char *buf, size_t len)
{
    struct nlmsghdr *nh = (struct nlmsghdr *)(buf + len);

    memset(nh, 0, NLMSG_SPACE(4));
    nh->nlmsg_type = NLMSG_DONE;
    nh->nlmsg_len = NLMSG_LENGTH(4);
    return len + NLMSG_ALIGN(nh->nlmsg_len);
}

static void test_default_gateway(void)
{
    static char buf[4096] __attribute__((aligned(8)));
    char out[INET_ADDRSTRLEN];
    size_t len = 0;

    /* What Android looks like: a connected route, a local route, and the
     * default route in the per-network table 1003, not in main. */
    len = add_route(buf, len, AF_INET, 24, RTN_UNICAST, 1003, NULL);
    len = add_route(buf, len, AF_INET, 32, RTN_LOCAL, 255, NULL);
    len = add_route(buf, len, AF_INET6, 0, RTN_UNICAST, 1003, NULL);
    len = add_route(buf, len, AF_INET, 0, RTN_UNREACHABLE, 1003, NULL);
    len = add_route(buf, len, AF_INET, 0, RTN_UNICAST, 1003, "192.168.0.1");
    len = add_route(buf, len, AF_INET, 0, RTN_UNICAST, 1004, "10.0.0.1");
    len = add_done(buf, len);
    CHECK(ub_default_gateway(buf, len, out, sizeof(out)) == 0);
    CHECK(strcmp(out, "192.168.0.1") == 0);

    /* Default route with no gateway (point-to-point): keep looking. */
    len = 0;
    len = add_route(buf, len, AF_INET, 0, RTN_UNICAST, 1003, NULL);
    len = add_route(buf, len, AF_INET, 0, RTN_UNICAST, 1005, "10.0.2.2");
    CHECK(ub_default_gateway(buf, len, out, sizeof(out)) == 0);
    CHECK(strcmp(out, "10.0.2.2") == 0);

    /* Nothing after NLMSG_DONE counts. */
    len = 0;
    len = add_done(buf, len);
    len = add_route(buf, len, AF_INET, 0, RTN_UNICAST, 1003, "192.168.0.1");
    CHECK(ub_default_gateway(buf, len, out, sizeof(out)) == -1);

    /* No network at all, and a truncated buffer. */
    CHECK(ub_default_gateway(buf, 0, out, sizeof(out)) == -1);
    len = add_route(buf, 0, AF_INET, 0, RTN_UNICAST, 1003, "192.168.0.1");
    CHECK(ub_default_gateway(buf, len - 4, out, sizeof(out)) == -1);
}

static void test_dns_next(void)
{
    /* Boot: no network yet. Write the fallback once, then wait -- and keep
     * waiting, however many passes come back empty. */
    CHECK(ub_dns_next("", "", 0) == UB_DNS_FALLBACK);
    CHECK(ub_dns_next("", "", 1) == UB_DNS_WAIT);
    CHECK(ub_dns_next(NULL, NULL, 1) == UB_DNS_WAIT);
    CHECK(ub_dns_next(NULL, "", 1) == UB_DNS_WAIT);

    /* WiFi comes up: the gateway is final, before or after the fallback. */
    CHECK(ub_dns_next("", "192.168.0.1", 1) == UB_DNS_FINAL);
    CHECK(ub_dns_next("", "192.168.0.1", 0) == UB_DNS_FINAL);

    /* The property is final on its own, with or without a gateway. */
    CHECK(ub_dns_next("9.9.9.9", "", 0) == UB_DNS_FINAL);
    CHECK(ub_dns_next("9.9.9.9", NULL, 1) == UB_DNS_FINAL);
}

static void test_parse_devices(void)
{
    char out[4][UB_DEV_LEN];
    int bad;

    CHECK(ub_parse_devices(UB_DEV_DEFAULT, out, 4, &bad) == 1 && bad == 0);
    CHECK(strcmp(out[0], "dri/renderD128") == 0);

    CHECK(ub_parse_devices("dri/card0, input/event3 snd/pcmC0D0p", out, 4, &bad) == 3 && bad == 0);
    CHECK(strcmp(out[1], "input/event3") == 0 && strcmp(out[2], "snd/pcmC0D0p") == 0);

    /* Never a disk, never out of /dev, never an empty component. */
    CHECK(ub_parse_devices("block/sda", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("nvme0n1", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("dri/../block/sda6", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("dri/./card0", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("/dev/dri/card0", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("dri/", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("dri//card0", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("dri/card0;rm", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_devices("drix/card0", out, 4, &bad) == 0 && bad == 1);

    /* Good entries survive bad neighbours; the cap is respected. */
    CHECK(ub_parse_devices("block/sda,dri/card0", out, 4, &bad) == 1 && bad == 1);
    CHECK(strcmp(out[0], "dri/card0") == 0);
    CHECK(ub_parse_devices("input/event0 input/event1 input/event2", out, 2, &bad) == 2 && bad == 1);

    /* Empty or missing: nothing, no error. */
    CHECK(ub_parse_devices("", out, 4, &bad) == 0 && bad == 0);
    CHECK(ub_parse_devices(NULL, out, 4, NULL) == 0);
}

#define K(code, value) ub_combo_feed(&c, EV_KEY, (code), (value))

static void test_combo(void)
{
    struct ub_combo c = { 0 };

    /* Ctrl+Alt+F2, then letting go: Ubuntu, on the LAST modifier release. */
    CHECK(K(KEY_LEFTCTRL, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTALT, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTALT, 0) == UB_SWITCH_NONE);    /* Ctrl still down */
    CHECK(K(KEY_LEFTCTRL, 0) == UB_SWITCH_UBUNTU);
    CHECK(c.pending == UB_SWITCH_NONE);

    /* Right-hand modifiers, F1, released in the other order: Android. */
    CHECK(K(KEY_RIGHTALT, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_RIGHTCTRL, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F1, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_RIGHTCTRL, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_F1, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_RIGHTALT, 0) == UB_SWITCH_ANDROID);

    /* Not a combo: F2 alone, Ctrl+F2, Alt+F2, and an autorepeat of F2. */
    CHECK(K(KEY_F2, 1) == UB_SWITCH_NONE && c.pending == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTCTRL, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 1) == UB_SWITCH_NONE && c.pending == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTCTRL, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTALT, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 1) == UB_SWITCH_NONE && c.pending == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTCTRL, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 2) == UB_SWITCH_NONE && c.pending == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTCTRL, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTALT, 0) == UB_SWITCH_NONE);

    /* Mixed hands count: left Ctrl + right Alt. Last combo pressed wins. */
    CHECK(K(KEY_LEFTCTRL, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_RIGHTALT, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F2, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_F1, 1) == UB_SWITCH_NONE);
    CHECK(K(KEY_RIGHTALT, 0) == UB_SWITCH_NONE);
    CHECK(K(KEY_LEFTCTRL, 0) == UB_SWITCH_ANDROID);

    /* Other event types and keys are ignored entirely. */
    CHECK(ub_combo_feed(&c, EV_REL, 0, 5) == UB_SWITCH_NONE);
    CHECK(K(KEY_A, 1) == UB_SWITCH_NONE && K(KEY_A, 0) == UB_SWITCH_NONE);
}

static void test_parse_inputs(void)
{
    char out[4][UB_INPUT_LEN];
    int bad;

    CHECK(ub_parse_inputs("event5,event13 event14", out, 4, &bad) == 3 && bad == 0);
    CHECK(strcmp(out[2], "event14") == 0);
    CHECK(ub_parse_inputs("event", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_inputs("event1234", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_inputs("event5x", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_inputs("../event5", out, 4, &bad) == 0 && bad == 1);
    CHECK(ub_parse_inputs("mouse0,event1", out, 4, &bad) == 1 && bad == 1);
    CHECK(ub_parse_inputs("event1 event2 event3", out, 2, &bad) == 2 && bad == 1);
    CHECK(ub_parse_inputs(NULL, out, 4, NULL) == 0);
}

static void test_pcm_silent(void)
{
    int16_t pcm[960] = { 0 };

    CHECK(ub_pcm_silent(pcm, 960) == 1);
    CHECK(ub_pcm_silent(pcm, 0) == 1);           /* nothing is silence */
    pcm[959] = 1;                                /* the very last sample */
    CHECK(ub_pcm_silent(pcm, 960) == 0);
    CHECK(ub_pcm_silent(pcm, 959) == 1);         /* ...outside the range */
    pcm[0] = -1;
    CHECK(ub_pcm_silent(pcm, 1) == 0);
}

static void test_write_resolv(void)
{
    char path[256], buf[1024];

    snprintf(path, sizeof(path), "%s/resolv.conf", tmpdir);

    CHECK(ub_write_resolv(path, "", "192.168.0.1") == 0);
    {
        struct stat st;
        mode_t old = umask(077);    /* what init gives a service */
        CHECK(ub_write_resolv(path, "", "192.168.0.1") == 0);
        umask(old);
        CHECK(stat(path, &st) == 0 && (st.st_mode & 0777) == 0644);
    }
    read_text(path, buf, sizeof(buf));
    CHECK(strstr(buf, "nameserver 192.168.0.1\nnameserver 1.1.1.1\n") != NULL);
    CHECK(strstr(buf, "options timeout:2 attempts:2\n") != NULL);

    CHECK(ub_write_resolv(path, NULL, NULL) == 0);
    read_text(path, buf, sizeof(buf));
    CHECK(strstr(buf, "nameserver 1.1.1.1\n") != NULL);
    CHECK(strstr(buf, "192.168") == NULL);

    /* The property wins outright, in either separator. */
    CHECK(ub_write_resolv(path, "9.9.9.9, 8.8.8.8 1.0.0.1", "192.168.0.1") == 0);
    read_text(path, buf, sizeof(buf));
    CHECK(strstr(buf, "nameserver 9.9.9.9\nnameserver 8.8.8.8\nnameserver 1.0.0.1\noptions") != NULL);
    CHECK(strstr(buf, "192.168") == NULL && strstr(buf, "1.1.1.1") == NULL);

    /* Ubuntu ships resolv.conf as a symlink into /run: it must become a file,
     * and the symlink's target must not be written. */
    snprintf(buf, sizeof(buf), "%s/stub", tmpdir);
    unlink(path);
    CHECK(symlink(buf, path) == 0);
    CHECK(ub_write_resolv(path, "", NULL) == 0);
    {
        struct stat st;
        CHECK(lstat(path, &st) == 0 && S_ISREG(st.st_mode));
        CHECK(access(buf, F_OK) < 0);
    }

    /* A server list too long for the buffer is cut, not overrun. */
    {
        char many[256];
        size_t i;
        for (i = 0; i + 8 < sizeof(many); i += 8)
            memcpy(many + i, "1.2.3.4 ", 8);
        many[i] = '\0';
        CHECK(ub_write_resolv(path, many, NULL) == 0);
    }

    CHECK(ub_write_resolv("/nonexistent/dir/resolv.conf", "", NULL) < 0);
}

int main(void)
{
    snprintf(tmpdir, sizeof(tmpdir), "/tmp/ubuntu_lib_test.XXXXXX");
    if (getenv("TMPDIR"))
        snprintf(tmpdir, sizeof(tmpdir), "%s/ubuntu_lib_test.XXXXXX", getenv("TMPDIR"));
    if (!mkdtemp(tmpdir)) {
        perror("mkdtemp");
        return 2;
    }

    test_exit_action();
    test_backoff();
    test_meminfo();
    test_cgroup();
    test_cgroup_reset();
    test_default_gateway();
    test_dns_next();
    test_parse_devices();
    test_combo();
    test_pcm_silent();
    test_parse_inputs();
    test_write_resolv();

    if (failures) {
        fprintf(stderr, "%d check(s) failed; scratch left in %s\n", failures, tmpdir);
        return 1;
    }
    printf("ubuntu_lib: all tests passed\n");
    return 0;
}
