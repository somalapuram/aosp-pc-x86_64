/*
 * ubuntu_lib -- the parts of pc_ubuntu_launch that decide things, kept free of
 * Android libraries and of anything that needs root, so ubuntu_lib_test.c can
 * check every one of them on the build host. See doc/10-ubuntu-alongside-android.md.
 */
#ifndef PC_UBUNTU_LIB_H
#define PC_UBUNTU_LIB_H

#include <stddef.h>
#include <sys/types.h>
#include <time.h>

/* What to do after systemd, PID 1 of the Ubuntu namespace, has gone. */
enum ub_action {
    UB_RESTART,     /* "reboot" inside Ubuntu: start it again at once */
    UB_STOP,        /* "poweroff" or "halt" inside Ubuntu: stay off */
    UB_CRASH,       /* anything else: restart with backoff, or give up */
};

/*
 * Map a waitpid() status to an action. Inside a PID namespace, reboot(2) does
 * not reboot: the kernel kills the namespace's init with SIGHUP for a restart
 * and SIGINT for power-off or halt (kernel/pid_namespace.c, reboot_pid_ns).
 * A clean exit(0) is systemd's "exit" verb, and is treated as a stop.
 */
enum ub_action ub_exit_action(int wstatus);

/*
 * Crash backoff: 1, 5 and 30 seconds for the first three crashes inside a
 * five-minute window, then give up. ub_backoff_next() records a crash at `now`
 * and returns the delay before the next start, or -1 to give up.
 */
#define UB_BACKOFF_WINDOW 300
#define UB_BACKOFF_MAX    3
struct ub_backoff {
    int n;
    time_t t[UB_BACKOFF_MAX + 1];
};
int ub_backoff_next(struct ub_backoff *b, time_t now);

/* MemTotal from the text of /proc/meminfo, in kB, or -1 if absent. */
long ub_meminfo_total_kb(const char *text);

/*
 * Create <cgroot>/<name> on the cgroup v2 hierarchy and set its ceilings.
 * Enables the memory and pids controllers for the root's children first,
 * one at a time, because a controller already claimed by a v1 mount (Android
 * mounts cpu and cpuset as v1) makes a combined write fail as a whole.
 * mem_max and pids_max of 0 or less leave that limit at "max".
 * Returns 0, or -errno for a failure that leaves the cgroup unusable.
 */
int ub_cgroup_setup(const char *cgroot, const char *name, long long mem_max, long pids_max);

/*
 * Remove <cgroot>/<name> and every cgroup below it, deepest first, so the next
 * start gets a fresh one. Needed because systemd enables controllers in its
 * root cgroup's subtree_control and leaves init.scope, system.slice and so on
 * behind; cgroup v2's no-internal-process rule then refuses to put the next
 * systemd into <name> at all (EBUSY). Only directories are removed: on
 * cgroupfs, rmdir removes a cgroup together with its interface files.
 * Returns 0 (also when <name> did not exist), or -errno.
 */
int ub_cgroup_reset(const char *cgroot, const char *name);

/* Move `pid` into <cgroot>/<name>. Returns 0 or -errno. */
int ub_cgroup_attach(const char *cgroot, const char *name, pid_t pid);

/* 1 if <cgroot>/<name>/cgroup.procs lists no process, 0 if it does, -errno. */
int ub_cgroup_empty(const char *cgroot, const char *name);

/*
 * Find the first IPv4 default route with a gateway in an RTM_GETROUTE dump,
 * across every routing table. Android puts its default route in a per-network
 * table, not in main, so /proc/net/route cannot be used. `buf` holds the
 * netlink messages exactly as recv() returned them. Writes the gateway as a
 * dotted quad and returns 0, or returns -1 if there is none.
 */
int ub_default_gateway(const void *buf, size_t len, char *out, size_t outlen);

/*
 * Write a resolv.conf. `servers` is the vendor.ubuntu.dns property: a list of
 * addresses separated by spaces or commas, used alone when it is not empty.
 * Otherwise the gateway (may be NULL) is tried first and 1.1.1.1 after it.
 * A symlink at `path`, which is what a stock Ubuntu ships, is replaced by a
 * regular file. Returns 0 or -errno.
 */
#define UB_FALLBACK_DNS "1.1.1.1"

/*
 * What one DNS pass should do, given the vendor.ubuntu.dns property, the
 * gateway found (either may be empty or NULL) and whether the fallback-only
 * file has already been written:
 *   UB_DNS_FINAL     write servers/gateway, stop looking
 *   UB_DNS_FALLBACK  write the fallback-only file once, keep looking
 *   UB_DNS_WAIT      nothing new to write, keep looking
 * Kept here, not in the launcher, because the launcher's first version got
 * it wrong: its second pass with no network treated "nothing found" as
 * final, and a whole boot on the HP laptop had only 1.1.1.1, which does
 * not answer there.
 */
enum ub_dns { UB_DNS_FINAL, UB_DNS_FALLBACK, UB_DNS_WAIT };
enum ub_dns ub_dns_next(const char *servers, const char *gateway, int fallback_written);
int ub_write_resolv(const char *path, const char *servers, const char *gateway);

#endif
