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
 * A system_ext binary, not vendor: libaaudio is a framework library.
 */

#define LOG_TAG "pc_ubuntu_audio"

#include <aaudio/AAudio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <log/log.h>

#include "ubuntu_lib.h"

#define PORT             4711
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

static int connect_ubuntu(void)
{
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT) };
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

int main(void)
{
    int fd, waited = 0;

    ALOGI("waiting for Ubuntu's sound on 127.0.0.1:%d", PORT);
    for (;;) {
        if ((fd = connect_ubuntu()) < 0) {
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
