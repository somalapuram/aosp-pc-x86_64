/*
 * pc_audio_setup -- dump the ALSA mixer, then unmute it.
 *
 * Background. The SOF/HDA card comes up with its analog outputs muted, which
 * is normal for HDA: on a Linux desktop alsactl or UCM unmutes them at boot,
 * and on a phone the vendor audio HAL does it from a mixer_paths.xml. This
 * device has neither. AOSP's default AIDL audio HAL does drive a few controls,
 * but only by these exact names (hardware/interfaces/audio/aidl/default/
 * alsa/Mixer.cpp):
 *
 *     "Master Playback Switch"   "Master Playback Volume"
 *     "Headphone Playback Volume" "Headset Playback Volume"
 *     "PCM Playback Volume"      "Capture Switch"  "Capture Volume"
 *
 * A SOF topology plus a Realtek codec exposes a different and longer set --
 * "Speaker Playback Switch", "Auto-Mute Mode" and so on -- so anything the HAL
 * does not know by name stays exactly as the driver left it, muted. The stream
 * opens, frames are written, and nothing comes out; there is no error anywhere
 * because nothing failed.
 *
 * Rather than guess those names from here, this walks every control the card
 * actually has and acts on what it finds:
 *
 *   - prints every control (name, type, values, range) so the log records the
 *     real mixer for this machine;
 *   - sets any BOOL "* Playback Switch" to on;
 *   - sets any INT "* Playback Volume" to its maximum;
 *   - turns "Auto-Mute Mode" off, since with no jack plugged it otherwise
 *     mutes the speaker again immediately after the switch above is set.
 *
 * Capture controls are deliberately left alone: the HAL does know
 * "Capture Switch"/"Capture Volume", and an input silently forced to maximum
 * gain is a worse failure than a quiet one.
 *
 * Why a binary and not tinymix from a shell script: /dev/snd is audio_device,
 * and system/sepolicy/private/app.te carries
 *     neverallow appdomain { audio_device ... }:chr_file { read write };
 * so the shell domain the other bring-up helpers use can never touch the
 * mixer. This has to run in vendor_shell, and tinymix installs to /system/bin,
 * which would mean letting a vendor domain execute system binaries. libtinyalsa
 * is vendor_available, so a small vendor binary avoids that entirely.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tinyalsa/asoundlib.h>

static int ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lsuf = strlen(suffix);
    return ls >= lsuf && strcmp(s + ls - lsuf, suffix) == 0;
}

/*
 * Output goes to a file, not stdout. init redirects a service's stdout to
 * /dev/null, so the first version of this printed a complete mixer dump
 * straight into the void -- the tool ran, exited 0, and left no trace in the
 * log at all, which reads exactly like the service never having started.
 */
static void redirect_output(const char *path) {
    /* If this fails the dump is lost, but the unmuting below still runs --
     * which is the part that matters. */
    if (!freopen(path, "w", stdout)) return;
    setvbuf(stdout, NULL, _IOLBF, 0);
}

/*
 * What the PCM devices will actually accept.
 *
 * This matters because the AIDL HAL never asks. For a built-in device
 * openProxyForAttachedDevice() calls profile_fill_builtin_device_info(), which
 * fills the profile from primary_audio_policy_configuration.xml instead of
 * querying the card -- so the rate and format in that XML are demanded of the
 * driver verbatim, and if the card does not offer them the open fails with
 *     proxy_open() pcm_is_ready() failed: cannot set hw params: Invalid argument
 * the stream drops to ERROR, and every subsequent write is refused. Nothing
 * downstream logs a fault; the symptom is silence.
 *
 * The policy config was asking for 44100 and the SOF pipeline runs at 48000,
 * which is the fix that accompanies this. Printing the real capabilities means
 * that if 48000 is somehow also wrong, the next boot names the rates the card
 * does support rather than costing another guess.
 */
static void dump_pcm_caps(unsigned int card) {
    for (unsigned int dev = 0; dev < 8; dev++) {
        struct pcm_params *p = pcm_params_get(card, dev, PCM_OUT);
        if (!p) continue;
        printf("  pcm %u:%u OUT  rate %u..%u  channels %u..%u  "
               "period %u..%u frames  periods %u..%u\n",
               card, dev,
               pcm_params_get_min(p, PCM_PARAM_RATE), pcm_params_get_max(p, PCM_PARAM_RATE),
               pcm_params_get_min(p, PCM_PARAM_CHANNELS), pcm_params_get_max(p, PCM_PARAM_CHANNELS),
               pcm_params_get_min(p, PCM_PARAM_PERIOD_SIZE), pcm_params_get_max(p, PCM_PARAM_PERIOD_SIZE),
               pcm_params_get_min(p, PCM_PARAM_PERIODS), pcm_params_get_max(p, PCM_PARAM_PERIODS));
        struct pcm_mask *m = pcm_params_get_mask(p, PCM_PARAM_FORMAT);
        if (m) {
            printf("      formats mask:");
            for (unsigned int i = 0; i < 2; i++) printf(" %08x", m->bits[i]);
            printf("   (bit 0=S8 2=S16_LE 6=S24_LE 10=S32_LE)\n");
        }
        pcm_params_free(p);
    }
    for (unsigned int dev = 0; dev < 8; dev++) {
        struct pcm_params *p = pcm_params_get(card, dev, PCM_IN);
        if (!p) continue;
        printf("  pcm %u:%u IN   rate %u..%u  channels %u..%u\n", card, dev,
               pcm_params_get_min(p, PCM_PARAM_RATE), pcm_params_get_max(p, PCM_PARAM_RATE),
               pcm_params_get_min(p, PCM_PARAM_CHANNELS), pcm_params_get_max(p, PCM_PARAM_CHANNELS));
        pcm_params_free(p);
    }
}

int main(int argc, char **argv) {
    redirect_output("/data/vendor/pc/audio_mixer.txt");
    unsigned int card = 0;
    if (argc > 1) {
        card = (unsigned int)atoi(argv[1]);
    }

    struct mixer *mixer = mixer_open(card);
    if (!mixer) {
        printf("pc_audio_setup: cannot open mixer for card %u\n", card);
        return 1;
    }

    printf("pc_audio_setup: PCM capabilities\n");
    dump_pcm_caps(card);

    unsigned int n = mixer_get_num_ctls(mixer);
    printf("pc_audio_setup: card %u, %u controls\n", card, n);

    for (unsigned int i = 0; i < n; i++) {
        struct mixer_ctl *ctl = mixer_get_ctl(mixer, i);
        if (!ctl) continue;

        const char *name = mixer_ctl_get_name(ctl);
        const char *type = mixer_ctl_get_type_string(ctl);
        enum mixer_ctl_type t = mixer_ctl_get_type(ctl);
        unsigned int nv = mixer_ctl_get_num_values(ctl);
        if (!name) continue;

        /* Record the control and its current state before touching anything,
         * so the log shows what the card looked like on a cold boot. */
        printf("  [%u] %-40s %-8s values=%u", i, name, type ? type : "?", nv);
        if (t == MIXER_CTL_TYPE_INT) {
            printf(" range=%d..%d cur=", mixer_ctl_get_range_min(ctl),
                   mixer_ctl_get_range_max(ctl));
        } else {
            printf(" cur=");
        }
        for (unsigned int v = 0; v < nv && v < 8; v++) {
            printf("%d ", mixer_ctl_get_value(ctl, v));
        }

        const char *action = "";

        if (t == MIXER_CTL_TYPE_BOOL && ends_with(name, "Playback Switch")) {
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++) {
                if (mixer_ctl_set_value(ctl, v, 1) != 0) failed = 1;
            }
            action = failed ? " -> UNMUTE FAILED" : " -> unmuted";
        } else if (t == MIXER_CTL_TYPE_INT && ends_with(name, "Playback Volume")) {
            int max = mixer_ctl_get_range_max(ctl);
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++) {
                if (mixer_ctl_set_value(ctl, v, max) != 0) failed = 1;
            }
            action = failed ? " -> SET MAX FAILED" : " -> set to max";
        } else if (t == MIXER_CTL_TYPE_ENUM && strcmp(name, "Auto-Mute Mode") == 0) {
            /* Enum 0 is "Disabled" on Realtek codecs. Left on, jack detection
             * re-mutes the speaker the instant the switch above is set, which
             * looks exactly like the unmute not having worked. */
            action = (mixer_ctl_set_value(ctl, 0, 0) == 0) ? " -> auto-mute off"
                                                           : " -> AUTO-MUTE OFF FAILED";
        }

        printf("%s\n", action);
    }

    mixer_close(mixer);
    printf("pc_audio_setup: done\n");
    return 0;
}
