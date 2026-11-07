// FireTVRemoteMicrophone.driver — Core Audio AudioServerPlugIn exposing a virtual input device
// "Fire TV Remote Microphone" (48 kHz, mono, Float32). Audio comes from a shared-memory ring
// written by Fire TV Remote Studio; when nothing is written the device produces silence.
// Runs inside coreaudiod: no blocking, no allocation and no I/O on the IO thread.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>
#include "../Sources/CMicRing/include/micring.h"
#include <os/log.h>
#include <dispatch/dispatch.h>
#include <sys/types.h>
static os_log_t gLog;

#define kPlugIn_BundleID      "com.uaaa.firetv-remote-studio.mic"
#define kDevice_UID           "FireTVRemoteMicrophone_UID"
#define kDevice_ModelUID      "FireTVRemoteMicrophone_ModelUID"
#define kDevice_Name          "Fire TV Remote Microphone"
#define kManufacturer         "Fire TV Remote Studio"
#define kSampleRate           48000.0
#define kChannels             1
#define kZeroTSPeriod         4096u   /* frames between zero timestamps */
#define kLatencyFrames        0u
#define kSafetyOffset         96u
#define kTargetBacklog        2880u   /* 60 ms: how far behind the writer we read */
#define kMaxBacklog           9600u   /* 200 ms: resync if further behind */

enum { kObjectID_PlugIn = kAudioObjectPlugInObject, kObjectID_Device = 2, kObjectID_Stream_Input = 3 };

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0.0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Float64 gSampleRate = kSampleRate;
static UInt32 gRefCount = 0;

/* shared ring (reader) */
static micring_t *gRing = NULL;
static uint64_t gReadPos = 0;
static mach_timebase_info_data_t gTimebase;
static ino_t gRingInode = 0;
static _Atomic(micring_t *) gPendingRing = NULL;   /* mapped on the monitor thread, adopted on the IO thread */
static uint64_t gIOCycles = 0, gFramesCopied = 0, gStaleCycles = 0;

/* Runs on a background queue (never on the IO thread): (re)map the ring when the file appears or is replaced. */
static void MonitorRingFile(void) {
    struct stat st;
    if (stat(MICRING_PATH, &st) != 0) { return; }
    if ((size_t)st.st_size < MICRING_FILE_SIZE) return;
    if (gRing && st.st_ino == gRingInode) return;          /* same file, mapping still valid */
    int fd = open(MICRING_PATH, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { os_log_error(gLog, "ring open failed errno=%d", errno); return; }
    void *p = mmap(NULL, MICRING_FILE_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { os_log_error(gLog, "ring mmap failed errno=%d", errno); return; }
    micring_t *r = (micring_t *)p;
    if (r->magic != MICRING_MAGIC || r->version != MICRING_VERSION || r->capacity != MICRING_CAPACITY) { munmap(p, MICRING_FILE_SIZE); os_log_error(gLog, "ring header mismatch"); return; }
    gRingInode = st.st_ino;
    atomic_store(&gPendingRing, r);
    os_log(gLog, "ring mapped inode=%llu writePos=%llu", (unsigned long long)st.st_ino, (unsigned long long)atomic_load(&r->writePos));
}
static void StartRingMonitor(void) {
    dispatch_queue_t q = dispatch_queue_create("com.uaaa.firetv.mic.ringmonitor", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(t, ^{
        MonitorRingFile();
        static int n = 0;
        if (++n % 5 == 0) {   /* every ~10 s */
            micring_t *r = gRing;
            os_log(gLog, "stats io=%llu copied=%llu stale=%llu readPos=%llu writePos=%llu ioCount=%u",
                   (unsigned long long)gIOCycles, (unsigned long long)gFramesCopied, (unsigned long long)gStaleCycles,
                   (unsigned long long)gReadPos, (unsigned long long)(r ? atomic_load(&r->writePos) : 0), gIOCount);
        }
    });
    dispatch_resume(t);
}
static void TryOpenRing(void) {
    micring_t *pending = atomic_exchange(&gPendingRing, NULL);
    if (pending) {
        if (gRing && gRing != pending) { /* old mapping is leaked on purpose: unmapping on the IO thread is not allowed */ }
        gRing = pending;
        gReadPos = atomic_load(&pending->writePos);
    }
}

/* Fill `frames` float frames from the ring; zeros where no data. Never blocks. */
static void ReadInput(float *out, UInt32 frames) {
    memset(out, 0, frames * kChannels * sizeof(float));
    gIOCycles++;
    TryOpenRing();
    micring_t *r = gRing;
    if (!r) return;
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_acquire);
    /* Writer gone quiet (app closed / mic released): stale heartbeat -> silence and resync later. */
    uint64_t hb = atomic_load_explicit(&r->writerHeartbeat, memory_order_relaxed);
    uint64_t now = mach_absolute_time();
    uint64_t staleNs = (now > hb) ? (now - hb) * gTimebase.numer / gTimebase.denom : 0;
    if (hb == 0 || staleNs > 500000000ull) { gReadPos = w; gStaleCycles++; return; }
    if (w < gReadPos || w - gReadPos > kMaxBacklog) {           /* writer reset or we fell too far behind */
        gReadPos = (w > kTargetBacklog) ? w - kTargetBacklog : 0;
    }
    uint64_t avail = w - gReadPos;
    if (avail == 0) return;
    UInt32 n = (UInt32)(avail < frames ? avail : frames);
    uint32_t cap = r->capacity;
    uint32_t idx = (uint32_t)(gReadPos % cap);
    uint32_t first = (idx + n <= cap) ? n : cap - idx;
    memcpy(out, &r->samples[idx * kChannels], first * kChannels * sizeof(float));
    if (first < n) memcpy(out + first * kChannels, &r->samples[0], (n - first) * kChannels * sizeof(float));
    gReadPos += n;
    gFramesCopied += n;
}

/* ------------------------------------------------------------------------- COM boilerplate */
static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean  HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable, GetPropertyDataSize,
    GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

__attribute__((visibility("default"))) void *FireTVMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    (void)inDriver;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT r = E_NOINTERFACE;
    if (uuid && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID))) {
        pthread_mutex_lock(&gStateMutex); ++gRefCount; pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef; r = S_OK;
    }
    if (uuid) CFRelease(uuid);
    return r;
}
static ULONG AddRef(void *d) { (void)d; pthread_mutex_lock(&gStateMutex); ULONG c = ++gRefCount; pthread_mutex_unlock(&gStateMutex); return c; }
static ULONG Release(void *d) { (void)d; pthread_mutex_lock(&gStateMutex); ULONG c = gRefCount > 0 ? --gRefCount : 0; pthread_mutex_unlock(&gStateMutex); return c; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d;
    gHost = host;
    gLog = os_log_create("com.uaaa.firetv-remote-studio", "mic");
    mach_timebase_info(&gTimebase);
    StartRingMonitor();
    os_log(gLog, "FireTVRemoteMicrophone initialized");
    gHostTicksPerFrame = ((Float64)gTimebase.denom / (Float64)gTimebase.numer) * 1000000000.0 / gSampleRate;
    return 0;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { (void)d;(void)desc;(void)c;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d;(void)o;(void)c; return 0; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d;(void)o;(void)c; return 0; }
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d;(void)o;(void)a;(void)i; return 0; }
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d;(void)o;(void)a;(void)i; return 0; }

/* ------------------------------------------------------------------------- properties */
static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle: return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType: case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList: case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyStreams: return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout: return a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeGlobal;
        }
        return false;
    case kObjectID_Stream_Input:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner: case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: return true;
        }
        return false;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    (void)d; (void)pid;
    if (!HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;   /* only 48k offered */
    if (obj == kObjectID_Stream_Input && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return 0;
}

static void FillFormat(AudioStreamBasicDescription *f) {
    memset(f, 0, sizeof(*f));
    f->mSampleRate = gSampleRate; f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = 4 * kChannels; f->mFramesPerPacket = 1; f->mBytesPerFrame = 4 * kChannels; f->mChannelsPerFrame = kChannels; f->mBitsPerChannel = 32;
}

#define RET_CF(x)   do { *outSize = sizeof(CFStringRef); if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; *(CFStringRef *)outData = CFSTR(x); return 0; } while (0)
#define RET_U32(x)  do { *outSize = sizeof(UInt32); if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError; *(UInt32 *)outData = (x); return 0; } while (0)
#define RET_F64(x)  do { *outSize = sizeof(Float64); if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError; *(Float64 *)outData = (x); return 0; } while (0)
#define RET_OBJ(x)  do { *outSize = sizeof(AudioObjectID); if (inSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError; *(AudioObjectID *)outData = (x); return 0; } while (0)

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *outSize) {
    /* Size is derived by calling GetPropertyData with a scratch buffer. */
    UInt8 scratch[512]; UInt32 sz = 0;
    OSStatus r = GetPropertyData(d, obj, pid, a, qs, q, sizeof scratch, &sz, scratch);
    if (r == 0) *outSize = sz;
    /* Strings in scratch were CFSTR constants: no release needed. */
    return r;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    (void)d; (void)pid; (void)qs;
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET_U32(kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RET_OBJ(kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET_CF(kManufacturer);
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            if (inSize < sizeof(AudioObjectID)) { *outSize = 0; return 0; }
            ((AudioObjectID *)outData)[0] = kObjectID_Device; *outSize = sizeof(AudioObjectID); return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if (qs < sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            *outSize = sizeof(AudioObjectID);
            *(AudioObjectID *)outData = CFStringCompare(*(CFStringRef *)q, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo ? kObjectID_Device : kAudioObjectUnknown;
            return 0;
        case kAudioPlugInPropertyResourceBundle: RET_CF("");
        }
        break;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET_U32(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RET_OBJ(kObjectID_PlugIn);
        case kAudioObjectPropertyName: RET_CF(kDevice_Name);
        case kAudioObjectPropertyManufacturer: RET_CF(kManufacturer);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            if (a->mScope == kAudioObjectPropertyScopeOutput || inSize < sizeof(AudioObjectID)) { *outSize = 0; return 0; }
            ((AudioObjectID *)outData)[0] = kObjectID_Stream_Input; *outSize = sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyDeviceUID: RET_CF(kDevice_UID);
        case kAudioDevicePropertyModelUID: RET_CF(kDevice_ModelUID);
        case kAudioDevicePropertyTransportType: RET_U32(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices:
            if (inSize < sizeof(AudioObjectID)) { *outSize = 0; return 0; }
            ((AudioObjectID *)outData)[0] = kObjectID_Device; *outSize = sizeof(AudioObjectID); return 0;
        case kAudioDevicePropertyClockDomain: RET_U32(0);
        case kAudioDevicePropertyDeviceIsAlive: RET_U32(1);
        case kAudioDevicePropertyDeviceIsRunning: { pthread_mutex_lock(&gStateMutex); UInt32 v = gIOCount > 0; pthread_mutex_unlock(&gStateMutex); RET_U32(v); }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RET_U32(1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RET_U32(0);
        case kAudioDevicePropertyLatency: RET_U32(kLatencyFrames);
        case kAudioObjectPropertyControlList: *outSize = 0; return 0;
        case kAudioDevicePropertySafetyOffset: RET_U32(kSafetyOffset);
        case kAudioDevicePropertyNominalSampleRate: RET_F64(gSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates:
            if (inSize < sizeof(AudioValueRange)) { *outSize = 0; return 0; }
            ((AudioValueRange *)outData)[0].mMinimum = kSampleRate; ((AudioValueRange *)outData)[0].mMaximum = kSampleRate;
            *outSize = sizeof(AudioValueRange); return 0;
        case kAudioDevicePropertyIsHidden: RET_U32(0);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 1; *outSize = 2 * sizeof(UInt32); return 0;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 need = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inSize < need) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *l = (AudioChannelLayout *)outData; memset(l, 0, need);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions; l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            *outSize = need; return 0; }
        case kAudioDevicePropertyZeroTimeStampPeriod: RET_U32(kZeroTSPeriod);
        case kAudioDevicePropertyIcon: { 
            if (inSize < sizeof(CFURLRef)) return kAudioHardwareBadPropertySizeError;
            CFBundleRef b = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
            CFURLRef u = b ? CFBundleCopyResourceURL(b, CFSTR("DeviceIcon"), CFSTR("icns"), NULL) : NULL;
            if (!u) return kAudioHardwareUnknownPropertyError;
            *(CFURLRef *)outData = u; *outSize = sizeof(CFURLRef); return 0; }
        }
        break;
    case kObjectID_Stream_Input:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RET_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: RET_U32(kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RET_OBJ(kObjectID_Device);
        case kAudioObjectPropertyName: RET_CF("Fire TV Remote Mic Input");
        case kAudioStreamPropertyIsActive: RET_U32(1);
        case kAudioStreamPropertyDirection: RET_U32(1);           /* 1 = input */
        case kAudioStreamPropertyTerminalType: RET_U32(kAudioStreamTerminalTypeMicrophone);
        case kAudioStreamPropertyStartingChannel: RET_U32(1);
        case kAudioStreamPropertyLatency: RET_U32(0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            FillFormat((AudioStreamBasicDescription *)outData); *outSize = sizeof(AudioStreamBasicDescription); return 0;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            if (inSize < sizeof(AudioStreamRangedDescription)) { *outSize = 0; return 0; }
            AudioStreamRangedDescription *r = (AudioStreamRangedDescription *)outData;
            FillFormat(&r->mFormat); r->mSampleRateRange.mMinimum = kSampleRate; r->mSampleRateRange.mMaximum = kSampleRate;
            *outSize = sizeof(AudioStreamRangedDescription); return 0; }
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 inSize, const void *inData) {
    (void)d; (void)pid; (void)qs; (void)q; (void)inSize; (void)inData;
    /* Only one rate / format exists; accept writes of the same value, reject others. */
    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) return (*(const Float64 *)inData == kSampleRate) ? 0 : kAudioHardwareIllegalOperationError;
    if (obj == kObjectID_Stream_Input && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) return 0;
    return kAudioHardwareUnknownPropertyError;
}

/* ------------------------------------------------------------------------- IO */
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client) {
    (void)d; (void)client;
    if (obj != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) { gNumberTimeStamps = 0; gAnchorHostTime = mach_absolute_time(); gReadPos = gRing ? atomic_load(&gRing->writePos) : 0; }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client) {
    (void)d; (void)client;
    if (obj != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex); if (gIOCount > 0) --gIOCount; pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)d; (void)client;
    if (obj != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 periodTicks = gHostTicksPerFrame * kZeroTSPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)(gNumberTimeStamps * periodTicks);
    /* advance to the latest period boundary not in the future */
    while (now >= next + (UInt64)periodTicks) { ++gNumberTimeStamps; next = gAnchorHostTime + (UInt64)(gNumberTimeStamps * periodTicks); }
    *outSampleTime = (Float64)(gNumberTimeStamps * kZeroTSPeriod);
    *outHostTime = next;
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 client, UInt32 op, Boolean *willDo, Boolean *inPlace) {
    (void)d; (void)client;
    if (obj != kObjectID_Device) return kAudioHardwareBadObjectError;
    *willDo = (op == kAudioServerPlugInIOOperationReadInput); *inPlace = true;
    return 0;
}
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d;(void)obj;(void)c;(void)op;(void)n;(void)i; return 0; }
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *mainBuf, void *secBuf) {
    (void)d; (void)client; (void)info; (void)secBuf;
    if (obj != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_Stream_Input) ReadInput((float *)mainBuf, frames);
    return 0;
}
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID obj, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d;(void)obj;(void)c;(void)op;(void)n;(void)i; return 0; }
