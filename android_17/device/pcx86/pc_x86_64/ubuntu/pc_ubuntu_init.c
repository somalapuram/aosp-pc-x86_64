/*
 * pc_ubuntu_init -- the SELinux door into Ubuntu. Executes /sbin/init.
 *
 * pc_ubuntu_launch runs this with execveat() on a descriptor it opened before
 * pivot_root, so it runs inside the Ubuntu root although it lives on /vendor.
 * Its only job is to be the file the domain transition happens on:
 *
 *     domain_auto_trans(ubuntu_launch, ubuntu_exec, ubuntu)
 *
 * The transition cannot happen on systemd itself. Android only lets a vendor
 * domain be entered through a file that is exec_type AND vendor_file_type
 * (private/domain.te), and forbids any domain to write, create, unlink or
 * mount on files of those types. Ubuntu's files must be writable (dpkg) and
 * mountable (the launcher mounts /proc, /sys and /dev on them), so they get a
 * plain type, ubuntu_file, and the door is this binary instead.
 *
 * Freestanding: no libc at all, a raw execve(2) from _start. It runs inside
 * the Ubuntu root, which has no /system/bin/linker64 and no bionic, so it
 * cannot be dynamic, and this tree has no static vendor variant of libc.
 * x86_64 only, like the device.
 */

#define NR_execve 59
#define NR_exit   60

static long syscall3(long n, long a, long b, long c)
{
    long ret;

    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n), "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
    return ret;
}

/* sp points at argc, then argv[], NULL, envp[], NULL, as the kernel left it. */
__attribute__((noreturn, used)) static void door(long *sp)
{
    static const char init[] = "/sbin/init";
    long argc = sp[0];
    char **argv = (char **)(sp + 1);
    char **envp = argv + argc + 1;

    argv[0] = (char *)init;
    syscall3(NR_execve, (long)init, (long)argv, (long)envp);
    /* No logd and no stdio in here. Exit 127, as a shell would; the launcher
     * logs the status. */
    for (;;)
        syscall3(NR_exit, 127, 0, 0);
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile("mov %rsp, %rdi\n"
                     "and $-16, %rsp\n"
                     "call door\n"
                     "hlt\n");
}
