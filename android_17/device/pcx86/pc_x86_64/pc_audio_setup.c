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
 * Capture is now unmuted too. It was deliberately left alone at first, on the
 * grounds that the HAL knows "Capture Switch" and "Capture Volume" and that an
 * input forced to maximum gain is a worse failure than a quiet one. The mixer
 * dump settled that: the card comes up with "Capture Switch" off, "Capture
 * Volume" at 0 of 63 and "Dmic0 Capture Switch" off, and they stay that way, so
 * whatever the HAL drives it is not these. Recording produced a valid file
 * whose audio track was silence.
 *
 * The gain caveat still stands, so capture volumes go to about three quarters
 * of range rather than maximum. That is loud enough to hear and leaves room
 * before clipping, and it is a starting point to tune from rather than a
 * setting to trust.
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
#include <math.h>
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

/*
 * Record a short burst from one capture PCM and report how loud it is.
 *
 * This exists because unmuting the card is not enough to know where the
 * microphone is. The recorded video has no sound, and the mixer explains half
 * of it: capture came up muted, with "Capture Switch" off and "Capture Volume"
 * at 0 of 63, exactly as the playback side did before this tool unmuted it.
 *
 * The other half is routing, and it cannot be settled by reading controls. The
 * card exposes two capture devices, 0:0 and 0:6, and the kernel reports
 * "Digital mics found on Skylake+ platform" with two DMICs in the NHLT tables
 * while "Mic Jack" reads 0, so nothing is plugged into the analog input. On a
 * SOF HDA topology 0:0 is the codec's analog capture and 0:6 is the DMIC array,
 * which makes the built-in microphone very likely to be on 6. The audio HAL
 * cannot reach it: StreamPrimary hardcodes kAlsaCard 0 and kAlsaDevice 0, and
 * although getCardAndDeviceId() will parse a CARD_n_DEV_m address, an
 * IN_MICROPHONE port has its address overwritten with "bottom" unconditionally
 * in XsdcConversion.cpp before that code ever sees it.
 *
 * Rerouting the HAL is a real change, so it should not be made on a hunch.
 * Reading a few periods from each device and printing the signal level answers
 * it directly: the device carrying the microphone shows a varying, non zero
 * level, and a device with nothing attached reads flat. Same reasoning as the
 * YUYV chroma probe in pc_v4l2_info.c, and cheap for the same reason.
 *
 * Run after the unmute below, or every device reads flat whether or not it has
 * a microphone on it.
 */
static void probe_capture(unsigned int card, unsigned int device) {
    struct pcm_config config;
    memset(&config, 0, sizeof(config));
    config.channels = 2;              /* the card offers 2..2, per dump_pcm_caps */
    config.rate = 48000;              /* and exactly 48000                        */
    config.period_size = 1024;
    config.period_count = 4;
    config.format = PCM_FORMAT_S16_LE;

    struct pcm *pcm = pcm_open(card, device, PCM_IN, &config);
    if (!pcm || !pcm_is_ready(pcm)) {
        printf("  capture probe %u:%u -> cannot open (%s)\n", card, device,
               pcm ? pcm_get_error(pcm) : "no pcm");
        if (pcm) pcm_close(pcm);
        return;
    }

    const unsigned int frames = 1024;
    const size_t bytes = frames * config.channels * 2;
    short *buf = (short *)malloc(bytes);
    if (!buf) { pcm_close(pcm); return; }

    int peak = 0, nonzero = 0;
    long long sumsq = 0;
    long count = 0;
    /* Discard the first couple of periods: a freshly started capture often
     * returns a block of zeros before the DMA is really running, which would
     * read as a dead microphone. */
    for (int period = 0; period < 8; period++) {
        if (pcm_read(pcm, buf, bytes) != 0) break;
        if (period < 2) continue;
        for (unsigned int i = 0; i < frames * config.channels; i++) {
            int v = buf[i];
            if (v < 0) v = -v;
            if (v > peak) peak = v;
            if (v != 0) nonzero++;
            sumsq += (long long)buf[i] * buf[i];
            count++;
        }
    }
    free(buf);
    pcm_close(pcm);

    if (count == 0) {
        printf("  capture probe %u:%u -> no frames read\n", card, device);
        return;
    }
    /* RMS as a fraction of full scale, in tenths of a percent, to avoid
     * pulling in libm for a log. */
    long rms = (long)(sqrtl((long double)sumsq / (long double)count));
    printf("  capture probe %u:%u -> peak %d/32767  rms %ld  nonzero %d/%ld  => %s\n",
           card, device, peak, rms, nonzero, count,
           peak > 64 ? "SIGNAL, microphone is on this device"
                     : "flat, nothing on this device");
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
        } else if (t == MIXER_CTL_TYPE_BOOL && ends_with(name, "Capture Switch")) {
            /* Covers both paths without needing to know which one carries the
             * microphone: "Capture Switch" is the codec's analog capture and
             * "Dmic0 Capture Switch" the digital array. The probe below reports
             * which of them actually has a signal. */
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++) {
                if (mixer_ctl_set_value(ctl, v, 1) != 0) failed = 1;
            }
            action = failed ? " -> CAPTURE UNMUTE FAILED" : " -> capture unmuted";
        } else if (t == MIXER_CTL_TYPE_INT && ends_with(name, "Capture Volume")) {
            /* Three quarters of range, not maximum: enough to be clearly
             * audible while leaving headroom, since an input pinned at full
             * gain is its own kind of broken. */
            int max = mixer_ctl_get_range_max(ctl);
            int min = mixer_ctl_get_range_min(ctl);
            int target = min + (max - min) * 3 / 4;
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++) {
                if (mixer_ctl_set_value(ctl, v, target) != 0) failed = 1;
            }
            action = failed ? " -> CAPTURE GAIN FAILED" : " -> capture gain to 3/4";
        } else if (t == MIXER_CTL_TYPE_INT && strcmp(name, "Mic Boost Volume") == 0) {
            /* One step of boost. The range is only 0..3 and the internal mic is
             * usually quiet without any. */
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++) {
                if (mixer_ctl_set_value(ctl, v, 1) != 0) failed = 1;
            }
            action = failed ? " -> MIC BOOST FAILED" : " -> mic boost 1";
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

    /* After the unmute, not before: a muted device reads flat whether or not a
     * microphone is attached, which is the exact ambiguity this is here to
     * remove. Both capture devices the card reported are probed. */
    printf("pc_audio_setup: capture probe\n");
    probe_capture(card, 0);
    probe_capture(card, 6);

    printf("pc_audio_setup: done\n");
    return 0;
}
