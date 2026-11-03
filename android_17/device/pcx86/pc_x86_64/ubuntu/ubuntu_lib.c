/*
 * ubuntu_lib -- see ubuntu_lib.h. No Android dependencies, no root needed.
 */

#include "ubuntu_lib.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

enum ub_action ub_exit_action(int wstatus)
{
    if (WIFSIGNALED(wstatus)) {
        if (WTERMSIG(wstatus) == SIGHUP)
            return UB_RESTART;
        if (WTERMSIG(wstatus) == SIGINT)
            return UB_STOP;
        return UB_CRASH;
    }
    if (WIFEXITED(wstatus) && WEXITSTATUS(wstatus) == 0)
        return UB_STOP;
    return UB_CRASH;
}

int ub_backoff_next(struct ub_backoff *b, time_t now)
{
    static const int delay[UB_BACKOFF_MAX] = { 1, 5, 30 };
    int i, kept = 0;

    /* Forget crashes that fell out of the window. */
    for (i = 0; i < b->n; i++)
        if (now - b->t[i] < UB_BACKOFF_WINDOW)
            b->t[kept++] = b->t[i];
    b->n = kept;

    if (b->n >= UB_BACKOFF_MAX)
        return -1;
    b->t[b->n++] = now;
    return delay[b->n - 1];
}

long ub_meminfo_total_kb(const char *text)
{
    const char *p = strstr(text, "MemTotal:");
    char *end;
    long kb;

    if (!p)
        return -1;
    kb = strtol(p + strlen("MemTotal:"), &end, 10);
    if (end == p + strlen("MemTotal:") || kb <= 0)
        return -1;
    return kb;
}

static int write_file(const char *path, const char *text)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    ssize_t len = (ssize_t)strlen(text), n;

    if (fd < 0)
        return -errno;
    n = write(fd, text, len);
    if (n != len) {
        int err = n < 0 ? -errno : -EIO;
        close(fd);
        return err;
    }
    return close(fd) < 0 ? -errno : 0;
}

int ub_cgroup_setup(const char *cgroot, const char *name, long long mem_max, long pids_max)
{
    static const char *const controllers[] = { "+memory", "+pids" };
    char path[512], num[32];
    size_t i;
    int err;

    /* A controller that is unavailable only costs its limit, not the cgroup. */
    snprintf(path, sizeof(path), "%s/cgroup.subtree_control", cgroot);
    for (i = 0; i < sizeof(controllers) / sizeof(controllers[0]); i++)
        write_file(path, controllers[i]);

    snprintf(path, sizeof(path), "%s/%s", cgroot, name);
    if (mkdir(path, 0755) < 0 && errno != EEXIST)
        return -errno;

    if (mem_max > 0) {
        snprintf(path, sizeof(path), "%s/%s/memory.max", cgroot, name);
        snprintf(num, sizeof(num), "%lld", mem_max);
        if ((err = write_file(path, num)) < 0 && err != -ENOENT)
            return err;
    }
    if (pids_max > 0) {
        snprintf(path, sizeof(path), "%s/%s/pids.max", cgroot, name);
        snprintf(num, sizeof(num), "%ld", pids_max);
        if ((err = write_file(path, num)) < 0 && err != -ENOENT)
            return err;
    }
    return 0;
}

static int rmdir_tree(const char *path)
{
    DIR *d = opendir(path);
    struct dirent *e;
    char sub[512];
    int err = 0;

    if (!d)
        return errno == ENOENT ? 0 : -errno;
    while ((e = readdir(d))) {
        if (e->d_type != DT_DIR || !strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
        if ((err = rmdir_tree(sub)) < 0)
            break;
    }
    closedir(d);
    if (err < 0)
        return err;
    return rmdir(path) < 0 && errno != ENOENT ? -errno : 0;
}

int ub_cgroup_reset(const char *cgroot, const char *name)
{
    char path[512];

    snprintf(path, sizeof(path), "%s/%s", cgroot, name);
    return rmdir_tree(path);
}

int ub_cgroup_attach(const char *cgroot, const char *name, pid_t pid)
{
    char path[512], num[32];

    snprintf(path, sizeof(path), "%s/%s/cgroup.procs", cgroot, name);
    snprintf(num, sizeof(num), "%d", (int)pid);
    return write_file(path, num);
}

int ub_cgroup_empty(const char *cgroot, const char *name)
{
    char path[512], c;
    int fd;
    ssize_t n;

    snprintf(path, sizeof(path), "%s/%s/cgroup.procs", cgroot, name);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -errno;
    n = read(fd, &c, 1);
    close(fd);
    if (n < 0)
        return -errno;
    return n == 0;
}

int ub_default_gateway(const void *buf, size_t len, char *out, size_t outlen)
{
    const struct nlmsghdr *nh;

    for (nh = buf; NLMSG_OK(nh, len); nh = NLMSG_NEXT(nh, len)) {
        const struct rtmsg *rt;
        const struct rtattr *rta;
        int attrlen;

        if (nh->nlmsg_type == NLMSG_DONE)
            break;
        if (nh->nlmsg_type != RTM_NEWROUTE)
            continue;
        rt = NLMSG_DATA(nh);
        if (rt->rtm_family != AF_INET || rt->rtm_dst_len != 0 || rt->rtm_type != RTN_UNICAST)
            continue;

        attrlen = (int)RTM_PAYLOAD(nh);
        for (rta = RTM_RTA(rt); RTA_OK(rta, attrlen); rta = RTA_NEXT(rta, attrlen)) {
            if (rta->rta_type == RTA_GATEWAY && RTA_PAYLOAD(rta) == 4)
                return inet_ntop(AF_INET, RTA_DATA(rta), out, outlen) ? 0 : -1;
        }
    }
    return -1;
}

/* snprintf at text+*used, never past the end even when an earlier call was cut short. */
static void append(char *text, size_t size, size_t *used, const char *fmt, const char *arg)
{
    int n;

    if (*used >= size - 1)
        return;
    n = snprintf(text + *used, size - *used, fmt, arg);
    if (n > 0)
        *used += (size_t)n < size - *used ? (size_t)n : size - 1 - *used;
}

int ub_write_resolv(const char *path, const char *servers, const char *gateway)
{
    char text[1024], copy[256], *tok, *save = NULL;
    size_t used = 0;
    int err;

    append(text, sizeof(text), &used, "%s",
           "# Written by pc_ubuntu_launch at every start; edits are lost.\n"
           "# Set vendor.ubuntu.dns on Android to choose the servers.\n");

    if (servers && *servers) {
        snprintf(copy, sizeof(copy), "%s", servers);
        for (tok = strtok_r(copy, " ,", &save); tok; tok = strtok_r(NULL, " ,", &save))
            append(text, sizeof(text), &used, "nameserver %s\n", tok);
    } else {
        if (gateway && *gateway)
            append(text, sizeof(text), &used, "nameserver %s\n", gateway);
        append(text, sizeof(text), &used, "nameserver %s\n", UB_FALLBACK_DNS);
    }
    append(text, sizeof(text), &used, "%s", "options timeout:2 attempts:2\n");

    if (unlink(path) < 0 && errno != ENOENT)
        return -errno;
    if ((err = write_file(path, text)) < 0)
        return err;
    /* Every Ubuntu user resolves names, apt's _apt among them; init's umask
     * would otherwise leave this 0600 and DNS working for root only. */
    return chmod(path, 0644) < 0 ? -errno : 0;
}
