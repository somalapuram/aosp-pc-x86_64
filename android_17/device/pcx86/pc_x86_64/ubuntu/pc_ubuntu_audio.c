/*
 * pc_ubuntu_audio -- play Ubuntu's sound through Android (doc/10 step 3 M4).
 *
 * Android's audio HAL owns the sound card, and keeps it: two mixers on one
 * card fight, and the HAL holds the PCM exclusively. So Ubuntu does not get
 * the card. Its PipeWire plays into a virtual sink, "Android speakers", and
 * PipeWire's protocol-simple module serves that sink's mix as raw PCM on
 * 127.0.0.1:4711 (tools/ubuntu-rootfs/etc/pipewire/pipewire.conf.d/). Ubuntu
 * shares Android's network namespace, so that is a plain localhost socket
 * here, reachable from nothing outside the machine.
 *
 * This connects to it and writes the stream into an AAudio stream, which
 * Android mixes with its own sound: both are heard, and Android's volume keys,
 * mute and Bluetooth output apply to Ubuntu too.
 *
 * PipeWire keeps sending while Ubuntu is quiet. After SILENCE_PAUSE_MS of
 * digital silence the stream is paused, so Android's output can go to
 * standby; the first non-zero sample starts it again.
 *
 * The microphone goes the other way, and only on demand: Android owns the
 * mic, and recording it while nothing in Ubuntu listens would keep Android's
 * mic-in-use indicator lit for nothing. Ubuntu's pc-mic-gate says "1" or "0"
 * on 127.0.0.1:4713 as recorders come and go; while it says 1, a second thread
 * records with AAudio and sends mono 48 kHz into 127.0.0.1:4712, which
 * PipeWire plays into the "Android microphone" source.
 *
 * A system_ext binary, not vendor: libaaudio is a framework library.
 */

#define LOG_TAG "pc_ubuntu_audio"

#include <aaudio/AAudio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <log/log.h>

#include "ubuntu_lib.h"

#define PORT             4711
#define MIC_PORT         4712
#define GATE_PORT        4713
#define RATE             48000
#define CHANNELS         2
#define FRAMES           480                 /* 10 ms per write */
#define SILENCE_PAUSE_MS 2000

static AAudioStream *open_stream(void)
{
    AAudioStreamBuilder *b = NULL;
    AAudioStream *s = NULL;
    aaudio_result_t r;

    if ((r = AAudio_createStreamBuilder(&b)) != AAUDIO_OK) {
        ALOGE("AAudio builder: %s", AAudio_convertResultToText(r));
        return NULL;
    }
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, CHANNELS);
    AAudioStreamBuilder_setSampleRate(b, RATE);
    AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MUSIC);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) {
        ALOGE("AAudio open: %s", AAudio_convertResultToText(r));
        return NULL;
    }
    ALOGI("AAudio stream open: %d Hz, %d ch, burst %d frames", AAudioStream_getSampleRate(s),
          AAudioStream_getChannelCount(s), AAudioStream_getFramesPerBurst(s));
    return s;
}

static int connect_port(int port)
{
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;

    if (fd < 0)
        return -1;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(fd);
        return -1;
    }
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

/* Play one connection until it closes. */
static void play(int fd)
{
    int16_t pcm[FRAMES * CHANNELS];
    size_t have = 0;
    int silent_ms = 0, running = 0;
    AAudioStream *s = open_stream();
    ssize_t n;

    if (!s)
        return;
    for (;;) {
        n = read(fd, (char *)pcm + have, sizeof(pcm) - have);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            break;
        }
        have += (size_t)n;
        if (have < sizeof(pcm))
            continue;               /* whole 10 ms blocks only */
        have = 0;

        if (ub_pcm_silent(pcm, FRAMES * CHANNELS)) {
            silent_ms += 1000 * FRAMES / RATE;
            if (running && silent_ms >= SILENCE_PAUSE_MS) {
                AAudioStream_requestPause(s);
                AAudioStream_requestFlush(s);
                running = 0;
                ALOGI("Ubuntu is quiet: paused");
            }
            if (!running)
                continue;
        } else {
            silent_ms = 0;
            if (!running) {
                AAudioStream_requestStart(s);
                running = 1;
                ALOGI("Ubuntu is playing");
            }
        }
        /* Blocking write: AAudio paces us at the device's rate. */
        if (AAudioStream_write(s, pcm, FRAMES, 200 * 1000 * 1000LL) < 0) {
            ALOGW("AAudio write failed; reopening");
            AAudioStream_close(s);
            if (!(s = open_stream()))
                break;
            running = 0;
        }
    }
    AAudioStream_close(s);
}

/* ------------------------------------------------------------ microphone - */

static AAudioStream *open_mic(void)
{
    AAudioStreamBuilder *b = NULL;
    AAudioStream *s = NULL;
    aaudio_result_t r;

    if ((r = AAudio_createStreamBuilder(&b)) != AAUDIO_OK)
        return NULL;
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_INPUT);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, 1);
    AAudioStreamBuilder_setSampleRate(b, RATE);
    AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_GENERIC);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) {
        ALOGE("AAudio mic open: %s", AAudio_convertResultToText(r));
        return NULL;
    }
    if ((r = AAudioStream_requestStart(s)) != AAUDIO_OK) {
        ALOGE("AAudio mic start: %s", AAudio_convertResultToText(r));
        AAudioStream_close(s);
        return NULL;
    }
    ALOGI("microphone open for Ubuntu: %d Hz, %d ch", AAudioStream_getSampleRate(s),
          AAudioStream_getChannelCount(s));
    return s;
}

/* Record into Ubuntu until the gate says 0 (or a socket goes away). */
static void record(int gate)
{
    int16_t pcm[FRAMES];
    char c;
    int out = connect_port(MIC_PORT);
    AAudioStream *s = out >= 0 ? open_mic() : NULL;

    while (s) {
        aaudio_result_t n = AAudioStream_read(s, pcm, FRAMES, 200 * 1000 * 1000LL);
        if (n < 0)
            break;
        if (n > 0 && write(out, pcm, (size_t)n * sizeof(pcm[0])) < 0)
            break;
        /* Gate changes arrive as single lines; a non-blocking peek. */
        if (recv(gate, &c, 1, MSG_DONTWAIT) == 1) {
            if (c == '0')
                break;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            break;
        }
    }
    if (s) {
        AAudioStream_requestStop(s);
        AAudioStream_close(s);
        ALOGI("microphone closed: nothing in Ubuntu is recording");
    }
    if (out >= 0)
        close(out);
}

static void *mic_main(void *unused)
{
    char c;
    int gate;

    (void)unused;
    for (;;) {
        if ((gate = connect_port(GATE_PORT)) < 0) {
            sleep(2);
            continue;
        }
        ALOGI("following Ubuntu's mic gate");
        while (read(gate, &c, 1) == 1)
            if (c == '1')
                record(gate);
        close(gate);
        sleep(1);
    }
    return NULL;
}

int main(void)
{
    int fd, waited = 0;
    pthread_t mic;

    if (pthread_create(&mic, NULL, mic_main, NULL) == 0)
        pthread_detach(mic);

    ALOGI("waiting for Ubuntu's sound on 127.0.0.1:%d", PORT);
    for (;;) {
        if ((fd = connect_port(PORT)) < 0) {
            if (waited++ == 30)
                ALOGW("still no sound server on 127.0.0.1:%d (is Ubuntu's PipeWire up?)", PORT);
            sleep(2);
            continue;
        }
        waited = 0;
        ALOGI("connected to Ubuntu's PipeWire");
        play(fd);
        close(fd);
        ALOGI("Ubuntu's sound stream closed");
        sleep(1);
    }
}
