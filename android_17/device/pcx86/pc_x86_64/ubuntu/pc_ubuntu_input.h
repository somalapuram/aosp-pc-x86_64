/*
 * pc_ubuntu_input -- screen and input switching between Android and Ubuntu's
 * GNOME (doc/10-ubuntu-alongside-android.md, step 3 M3).
 *
 * Android's InputFlinger reads every real input device, so handing GNOME the
 * same nodes means every key reaches both systems. Instead, for each real
 * device in vendor.ubuntu.input this makes a uinput copy, named
 * "pc-ubuntu-input-N", which /vendor/etc/excluded-input-devices.xml hides
 * from Android, and Ubuntu is given only the copies. While Ubuntu has the
 * screen the real devices are grabbed (EVIOCGRAB: Android receives nothing)
 * and their events are forwarded to the copies; while Android has it, the
 * grab is released and nothing is forwarded.
 *
 * The forwarding thread reads the real keyboard in both states, which is how
 * it sees the switch keys (ub_combo_feed): Ctrl+Alt+F2 to Ubuntu, Ctrl+Alt+F1
 * back. `setprop vendor.ubuntu.screen ubuntu|android` does the same.
 */
#ifndef PC_UBUNTU_INPUT_H
#define PC_UBUNTU_INPUT_H

#include <sys/types.h>

#include "ubuntu_lib.h"

/* Make the copies for vendor.ubuntu.input. Their event nodes are appended to
 * out[] (as "input/eventN", for pass_devices). Returns how many were added. */
int ui_setup(char out[][UB_DEV_LEN], int max);

/* Start the forwarding/switching thread. `systemd` is read on every switch
 * (it changes when Ubuntu restarts); 0 means Ubuntu is not running. */
void ui_start(volatile pid_t *systemd);

/* Ubuntu went away: give everything back to Android, without asking Ubuntu. */
void ui_reset_to_android(void);

#endif
