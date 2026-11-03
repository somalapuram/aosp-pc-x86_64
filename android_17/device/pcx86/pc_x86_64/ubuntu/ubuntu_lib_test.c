/*
 * Host tests for ubuntu_lib. Run with ./run_tests.sh (plain cc, seconds), or
 * as the Soong host test pc_ubuntu_launch_test. Every function in ubuntu_lib.h
 * has a test here.
 */

#include "ubuntu_lib.h"

#include <arpa/inet.h>
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

static void test_write_resolv(void)
{
    char path[256], buf[1024];

    snprintf(path, sizeof(path), "%s/resolv.conf", tmpdir);

    CHECK(ub_write_resolv(path, "", "192.168.0.1") == 0);
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
    test_default_gateway();
    test_write_resolv();

    if (failures) {
        fprintf(stderr, "%d check(s) failed; scratch left in %s\n", failures, tmpdir);
        return 1;
    }
    printf("ubuntu_lib: all tests passed\n");
    return 0;
}
