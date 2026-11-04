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

/*
 * Device pass-through: the vendor.ubuntu.devices property names Android
 * device nodes to recreate in Ubuntu's /dev, e.g. "dri/renderD128" (the
 * default: the GPU render node, which the kernel shares between any number of
 * users) or, for the display work, "dri/card0,input/event3". Entries are
 * separated by commas or spaces and must be a path under dri/, input/ or snd/
 * made of [A-Za-z0-9_-] components, no "." or ".." component, so a property
 * can never name a disk or escape /dev. Fills out[] with up to `max` valid
 * entries (each < UB_DEV_LEN) and returns how many; invalid ones are skipped
 * and counted in *rejected when it is not NULL.
 */
#define UB_DEV_LEN 48
#define UB_DEV_DEFAULT "dri/renderD128"
int ub_parse_devices(const char *spec, char out[][UB_DEV_LEN], int max, int *rejected);

/*
 * Screen switching (doc/10 step 3 M3). The launcher reads the real keyboard
 * in both states and feeds every event here. Ctrl+Alt+F2 asks for Ubuntu,
 * Ctrl+Alt+F1 for Android. The answer is given only once Ctrl and Alt have
 * both been released after the combo, so the side losing the keyboard has
 * seen every key go up again and is left with no stuck modifier.
 */
enum ub_switch { UB_SWITCH_NONE, UB_SWITCH_ANDROID, UB_SWITCH_UBUNTU };
struct ub_combo {
    unsigned lctrl : 1, rctrl : 1, lalt : 1, ralt : 1;
    enum ub_switch pending;
};
enum ub_switch ub_combo_feed(struct ub_combo *c, int type, int code, int value);

/*
 * vendor.ubuntu.input: the real input devices to share with Ubuntu, by event
 * node name, e.g. "event5,event13,event14". Only "event" plus 1-3 digits is
 * accepted. Same contract as ub_parse_devices().
 */
#define UB_INPUT_LEN 16
int ub_parse_inputs(const char *spec, char out[][UB_INPUT_LEN], int max, int *rejected);

/*
 * Sound bridge (doc/10 step 3 M4): PipeWire in Ubuntu keeps streaming while
 * Ubuntu is quiet, so pc_ubuntu_audio pauses its AAudio stream after a run of
 * pure silence and resumes on the first sample that is not. 1 if every one of
 * the `n` samples is exactly zero (PipeWire's silence is digital zero).
 */
#include <stdint.h>
int ub_pcm_silent(const int16_t *pcm, size_t n);

#endif
