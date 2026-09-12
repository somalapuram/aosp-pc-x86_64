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
 * Gain goes to maximum. Three quarters of range was tried first, on the
 * principle that an input pinned at full gain is its own kind of broken, and
 * the probe measured what that actually gave: peak 706 of 32767, RMS 64, about
 * -54 dBFS. The recording contained real audio and was inaudible. Nothing is
 * being protected from clipping 35 dB below where it should be, so the caution
 * was wrong here and the measurement replaces it.
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
#include <unistd.h>
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
__attribute__((unused)) static void probe_capture_ch(unsigned int card, unsigned int device, unsigned int channels) {
    struct pcm_config config;
    memset(&config, 0, sizeof(config));
    config.channels = channels;
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

    /* Per channel, because a stereo capture with one live channel and one dead
     * one is a real and common HDA wiring, and averaging the two hides it. The
     * camcorder profile records mono, so the framework downmixes; if the live
     * channel is the one being dropped or halved that matters. */
    int peak[8] = {0}, nonzero[8] = {0};
    long long sumsq[8] = {0};
    long count = 0;
    /* Discard the first couple of periods: a freshly started capture often
     * returns a block of zeros before the DMA is really running, which would
     * read as a dead microphone. */
    for (int period = 0; period < 8; period++) {
        if (pcm_read(pcm, buf, bytes) != 0) break;
        if (period < 2) continue;
        for (unsigned int i = 0; i < frames * config.channels; i++) {
            unsigned int c = i % config.channels;
            if (c >= 8) continue;
            int v = buf[i];
            if (v < 0) v = -v;
            if (v > peak[c]) peak[c] = v;
            if (v != 0) nonzero[c]++;
            sumsq[c] += (long long)buf[i] * buf[i];
        }
        count += frames;
    }
    free(buf);
    pcm_close(pcm);

    if (count == 0) {
        printf("  capture probe %u:%u ch%u -> no frames read\n", card, device, channels);
        return;
    }
    int loudest = 0;
    printf("  capture probe %u:%u ch%u ->", card, device, channels);
    for (unsigned int c = 0; c < channels && c < 8; c++) {
        long rms = (long)(sqrtl((long double)sumsq[c] / (long double)count));
        if (peak[c] > loudest) loudest = peak[c];
        printf("  [ch%u peak %d rms %ld nz %d/%ld]", c, peak[c], rms, nonzero[c], count);
    }
    printf("  => %s\n", loudest > 64 ? "SIGNAL" : "flat");
}

/*
 * Unmute the analog output path of one card: every "* Playback Switch" on,
 * every "* Playback Volume" to max, "Auto-Mute Mode" off, and capture unmuted
 * to max. Returns 1 if this card had a "Master Playback Switch" or "Speaker
 * Playback Switch" -- i.e. it is the analog codec we care about, not an HDMI
 * card. `verbose` dumps the full control list (only wanted once, on the first
 * pass, so the log records the cold-boot mixer without 200 repeats).
 */
static int unmute_card(unsigned int card, int verbose) {
    struct mixer *mixer = mixer_open(card);
    if (!mixer)
        return 0;
    int is_analog = 0;
    unsigned int n = mixer_get_num_ctls(mixer);
    if (verbose)
        printf("pc_audio_setup: card %u, %u controls\n", card, n);
    for (unsigned int i = 0; i < n; i++) {
        struct mixer_ctl *ctl = mixer_get_ctl(mixer, i);
        if (!ctl)
            continue;
        const char *name = mixer_ctl_get_name(ctl);
        const char *type = mixer_ctl_get_type_string(ctl);
        enum mixer_ctl_type t = mixer_ctl_get_type(ctl);
        unsigned int nv = mixer_ctl_get_num_values(ctl);
        if (!name)
            continue;
        if (verbose) {
            printf("  [%u] %-40s %-8s values=%u", i, name, type ? type : "?", nv);
            if (t == MIXER_CTL_TYPE_INT)
                printf(" range=%d..%d cur=", mixer_ctl_get_range_min(ctl),
                       mixer_ctl_get_range_max(ctl));
            else
                printf(" cur=");
            for (unsigned int v = 0; v < nv && v < 8; v++)
                printf("%d ", mixer_ctl_get_value(ctl, v));
        }
        const char *action = "";
        if (t == MIXER_CTL_TYPE_BOOL && ends_with(name, "Playback Switch")) {
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++)
                if (mixer_ctl_set_value(ctl, v, 1) != 0) failed = 1;
            action = failed ? " -> UNMUTE FAILED" : " -> unmuted";
            if (ends_with(name, "Master Playback Switch") ||
                ends_with(name, "Speaker Playback Switch"))
                is_analog = 1;
        } else if (t == MIXER_CTL_TYPE_INT && ends_with(name, "Playback Volume")) {
            int max = mixer_ctl_get_range_max(ctl);
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++)
                if (mixer_ctl_set_value(ctl, v, max) != 0) failed = 1;
            action = failed ? " -> SET MAX FAILED" : " -> set to max";
        } else if (t == MIXER_CTL_TYPE_BOOL && ends_with(name, "Capture Switch")) {
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++)
                if (mixer_ctl_set_value(ctl, v, 1) != 0) failed = 1;
            action = failed ? " -> CAPTURE UNMUTE FAILED" : " -> capture unmuted";
        } else if (t == MIXER_CTL_TYPE_INT && ends_with(name, "Capture Volume")) {
            int max = mixer_ctl_get_range_max(ctl);
            int failed = 0;
            for (unsigned int v = 0; v < nv; v++)
                if (mixer_ctl_set_value(ctl, v, max) != 0) failed = 1;
            action = failed ? " -> CAPTURE MAX FAILED" : " -> capture set to max";
        } else if (t == MIXER_CTL_TYPE_ENUM && ends_with(name, "Auto-Mute Mode")) {
            /* With no jack plugged, Auto-Mute re-mutes the speaker the instant
             * the switch above is set. Enum item 0 is "Disabled" on the Realtek
             * codecs. */
            if (mixer_ctl_set_value(ctl, 0, 0) == 0)
                action = " -> auto-mute disabled";
        }
        if (verbose)
            printf("%s\n", action);
    }
    mixer_close(mixer);
    return is_analog;
}

int main(void) {
    redirect_output("/data/vendor/pc/audio_mixer.txt");

    /* One card is not enough. The GPU's HDMI audio comes up as card 0 and the
     * analog codec (Realtek ALC245 driving the CS35L41 speaker amps) as card 1,
     * so unmuting only card 0 -- what this did before -- left the speakers muted
     * with the log showing a clean "unmuted" for the wrong card.
     *
     * Worse, the CS35L41 amps load a DSP firmware over I2C that takes ~180s per
     * amp, and the ALC245's speaker route settles only once that finishes. A
     * single early pass is undone by the time the amps are up. So walk every
     * card and re-apply, in passes, across a window long enough to cover the
     * firmware load, stopping early once the analog codec has been seen and
     * unmuted on a pass after it settled.
     *
     * This is a background oneshot (init does not wait for it), so the long
     * window does not delay the desktop; the speakers simply come alive once
     * the amps are ready. */
    const unsigned int MAX_CARDS = 8;
    const int PASSES = 20;          /* 20 * 15s = 300s, covers two ~180s amps */
    int analog_unmuted_late = 0;
    for (int pass = 0; pass < PASSES; pass++) {
        int saw_analog = 0;
        for (unsigned int c = 0; c < MAX_CARDS; c++)
            if (unmute_card(c, pass == 0))
                saw_analog = 1;
        printf("pc_audio_setup: pass %d, analog codec %s\n",
               pass, saw_analog ? "unmuted" : "not present yet");
        /* Require the analog codec to still be present two passes running before
         * declaring victory, so we do not stop in the gap between the ALC245
         * appearing and the CS35L41 firmware finishing. */
        if (saw_analog && pass >= 1) {
            if (analog_unmuted_late++) break;
        } else {
            analog_unmuted_late = 0;
        }
        if (pass == 0)
            dump_pcm_caps(1);
        sleep(15);
    }
    printf("pc_audio_setup: done\n");
    return 0;
}
