#include "micring.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <mach/mach_time.h>

micring_t *micring_open_writer(void) {
    /* Refuse to follow a pre-planted symlink in the shared (world-writable) dir. */
    struct stat dirst;
    if (lstat(MICRING_DIR, &dirst) == 0 && S_ISLNK(dirst.st_mode)) { unlink(MICRING_DIR); }
    mkdir(MICRING_DIR, 0777);
    chmod(MICRING_DIR, 01777);
    /* O_NOFOLLOW: never open through a symlink an attacker may have planted. */
    int fd = open(MICRING_PATH, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return NULL;
    if (ftruncate(fd, (off_t)MICRING_FILE_SIZE) != 0) { close(fd); return NULL; }
    fchmod(fd, 0644);
    void *p = mmap(NULL, MICRING_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    micring_t *r = (micring_t *)p;
    if (r->magic != MICRING_MAGIC || r->version != MICRING_VERSION || r->capacity != MICRING_CAPACITY) {
        memset(r, 0, sizeof(micring_t));
        r->sampleRate = MICRING_RATE; r->channels = MICRING_CHANNELS; r->capacity = MICRING_CAPACITY;
        r->version = MICRING_VERSION;
        atomic_store(&r->writePos, 0);
        __sync_synchronize();
        r->magic = MICRING_MAGIC;   /* published last */
    }
    atomic_store(&r->active, 0);
    atomic_store(&r->writerHeartbeat, mach_absolute_time());
    return r;
}

void micring_close(micring_t *r) {
    if (!r) return;
    atomic_store(&r->active, 0);
    atomic_store(&r->writerHeartbeat, 0);
    munmap(r, MICRING_FILE_SIZE);
}

void micring_write(micring_t *r, const float *frames, uint32_t n) {
    if (!r || !frames || n == 0) return;
    uint64_t pos = atomic_load_explicit(&r->writePos, memory_order_relaxed);
    uint32_t cap = r->capacity;
    uint32_t idx = (uint32_t)(pos % cap);
    uint32_t first = (idx + n <= cap) ? n : cap - idx;
    memcpy(&r->samples[idx * r->channels], frames, first * r->channels * sizeof(float));
    if (first < n) memcpy(&r->samples[0], frames + first * r->channels, (n - first) * r->channels * sizeof(float));
    atomic_store_explicit(&r->writePos, pos + n, memory_order_release);
    atomic_store_explicit(&r->writerHeartbeat, mach_absolute_time(), memory_order_relaxed);
}

void micring_set_active(micring_t *r, int active) {
    if (!r) return;
    atomic_store(&r->active, active ? 1u : 0u);
    atomic_store_explicit(&r->writerHeartbeat, mach_absolute_time(), memory_order_relaxed);
}

const char *MICRING_PATH_C(void) { return MICRING_PATH; }
