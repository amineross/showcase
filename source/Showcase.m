/*
 * Showcase.m - Wireless CarPlay receiver application
 *
 * Self-contained orchestrator app with state machine, car management,
 * hotspot credential storage, receiver media, touch input, and lifecycle
 * recovery for jailbroken iPhones and iPads.
 *
 * Compile (on-device):
 *   clang -fobjc-arc -isysroot /tmp/iPhoneOS10.3.sdk \
 *         -o Showcase Showcase.m \
 *         -framework UIKit -framework AVFoundation -framework AudioToolbox \
 *         -framework CoreMedia -framework Foundation -framework Security \
 *         -Wl,-undefined,dynamic_lookup
 */

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <float.h>
#include <math.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach/mach_time.h>
#include <notify.h>
#include "baa_broker.h"

extern char **environ;

/* ═══════════════════════════════════════════════════════════════
 * Languages
 *
 * English strings are the keys; <language>.lproj/Localizable.strings in the
 * app bundle holds the others. Showcase follows the device's preferred
 * languages unless one is chosen in Settings. The app runs as root, whose
 * preferences do not carry the user's languages, so mobile's are read.
 * ═══════════════════════════════════════════════════════════════ */

#define LANGUAGE_KEY @"appLanguage"
#define MOBILE_GLOBAL_PREFERENCES @"/var/mobile/Library/Preferences/.GlobalPreferences.plist"

static NSArray<NSString *> *showcase_languages(void) {
    return @[@"en", @"fr", @"es", @"zh-Hans", @"ja", @"tr"];
}

/* The language's own name, as iOS lists it. */
static NSString *showcase_language_name(NSString *language) {
    NSDictionary *names = @{@"en": @"English", @"fr": @"Français", @"es": @"Español",
                            @"zh-Hans": @"简体中文", @"ja": @"日本語", @"tr": @"Türkçe"};
    return names[language] ?: language;
}

static NSString *showcase_device_language(void) {
    NSArray *preferred = [NSDictionary dictionaryWithContentsOfFile:MOBILE_GLOBAL_PREFERENCES][@"AppleLanguages"];
    if (![preferred isKindOfClass:[NSArray class]] || !preferred.count) preferred = [NSLocale preferredLanguages];
    for (NSString *tag in preferred) {
        if (![tag isKindOfClass:[NSString class]]) continue;
        NSString *lower = tag.lowercaseString;
        if ([lower hasPrefix:@"zh"]) return @"zh-Hans";
        for (NSString *language in showcase_languages())
            if ([lower isEqualToString:language] || [lower hasPrefix:[language stringByAppendingString:@"-"]])
                return language;
    }
    return @"en";
}

static NSBundle *g_language_bundle;
static BOOL g_language_loaded;

/* The chosen language, or nil to follow the device. */
static NSString *showcase_chosen_language(void) {
    NSString *chosen = [[NSUserDefaults standardUserDefaults] stringForKey:LANGUAGE_KEY];
    return [showcase_languages() containsObject:chosen] ? chosen : nil;
}

static NSString *showcase_language(void) {
    return showcase_chosen_language() ?: showcase_device_language();
}

static void showcase_set_language(NSString *language) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (language) [d setObject:language forKey:LANGUAGE_KEY];
    else [d removeObjectForKey:LANGUAGE_KEY];
    [d synchronize];
    g_language_loaded = NO;
}

static NSString *L(NSString *english) {
    if (!g_language_loaded) {
        NSString *language = showcase_language();
        NSString *path = [language isEqualToString:@"en"] ? nil
            : [[NSBundle mainBundle] pathForResource:language ofType:@"lproj"];
        g_language_bundle = path ? [NSBundle bundleWithPath:path] : nil;
        g_language_loaded = YES;
    }
    return g_language_bundle ? [g_language_bundle localizedStringForKey:english value:english table:nil] : english;
}

/* ═══════════════════════════════════════════════════════════════
 * Application logger
 * ═══════════════════════════════════════════════════════════════ */

#define LOG_DIR     "/var/mobile/Library/Showcase/logs"
#define APP_LOG     LOG_DIR "/app.log"
#define TCPDUMP_DIR  "/var/mobile/Library/Showcase/dumps"
#define TCPDUMP_LOG  TCPDUMP_DIR "/tcpdump.log"
#define TCPDUMP_MAX_SECONDS 300
#define DIAGNOSTICS_ENABLED_KEY @"diagnosticsEnabled"
#define RECEIVER_AUDIO_KEY      @"receiverAudioEnabled"
#define RIGHT_HAND_DRIVE_KEY    @"rightHandDriveDock"
#define SMOOTH_VIDEO_KEY        @"preferSmoothVideo"
#define QUALITY_VIDEO_KEY       @"prioritizeVideoQuality"
#define VIDEO_WIDTH_KEY         @"videoWidth"
#define VIDEO_HEIGHT_KEY        @"videoHeight"
#define VIDEO_FPS_KEY           @"videoFramesPerSecond"
#define AUTO_START_KEY          @"startCarPlayOnLaunch"
#define DEDICATED_RADIO_KEY     @"leaveOtherWiFiDuringCarPlay"
#define HELD_WIFI_NETWORK_KEY   @"heldWiFiNetworkSSID"
#define HOTSPOT_OWNED_KEY       @"hotspotStartedByShowcase"
/* Beta 6 turns Prioritize Quality on once; later choices are kept. */
#define QUALITY_DEFAULT_SET_KEY @"qualityDefaultApplied"
#define QUALITY_HSIC_RESTORED_KEY @"qualityHSICRestored"
#define USAGE_KEY               @"anonymousUsageEnabled"
#define USAGE_ID_KEY            @"anonymousUsageID"
#define USAGE_SENT_KEY          @"anonymousUsageSentPayload"
#define USAGE_SENT_DATE_KEY     @"anonymousUsageSentDate"
#define GITHUB_URL              @"https://github.com/amineross/showcase"
#define MIS_STATE_OFF           1022
#define MIS_STATE_ON            1023
#define SHOWCASE_BT_PROGRESS_NOTIFICATION "com.rostane.showcase.bt-progress"
#define BT_PROGRESS_CONNECTED   0x01ULL
#define BT_PROGRESS_AUTHORIZED  0x02ULL
#define BT_PROGRESS_IDENTIFIED  0x04ULL
#define BT_PROGRESS_WIFI_SENT   0x08ULL
static FILE *g_logfile = NULL;

static uint64_t monotonic_nanos_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

static void ip_log(const char *fmt, ...) {
    if (!g_logfile) return;
    char ts[32];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    uint64_t monotonicNanos = monotonic_nanos_now();
    fprintf(g_logfile, "[%s mono=%llu.%06llu] ", ts,
            (unsigned long long)(monotonicNanos / NSEC_PER_SEC),
            (unsigned long long)((monotonicNanos % NSEC_PER_SEC) / 1000ULL));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logfile, fmt, ap);
    va_end(ap);
    fprintf(g_logfile, "\n");
    fflush(g_logfile);
}

static void ip_log_open(void) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);
    g_logfile = fopen(APP_LOG, "a");
    if (g_logfile) {
        fprintf(g_logfile, "\n══════════════ Showcase launch ══════════════\n");
        fflush(g_logfile);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Configuration
 * ═══════════════════════════════════════════════════════════════ */

#define APP_NAME          "Showcase"
/* Release builds pass APP_VERSION from the VERSION file. */
#ifndef APP_VERSION
#define APP_VERSION       "development"
#endif
#ifndef PACKAGE_VERSION
#define PACKAGE_VERSION   "development"
#endif
#define APP_AUTHOR        "Amine Rostane"
#define SOCK_PATH         "/tmp/ipadplay.sock"   /* IPC socket — kept for compat with carplay_services */
#define BLUETOOTHD_PLIST  "/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
#define BT_READY_PATH     "/tmp/showcase_bt_ready"
#define BLUETOOL_PLIST    "/System/Library/LaunchDaemons/com.apple.BlueTool.plist"
#ifdef SHOWCASE_ROOTLESS
#define JB_PREFIX         "/var/jb"
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST JB_PATH("/Library/LaunchDaemons/ch.ringwald.BTstack.plist")
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#else
#define JB_PREFIX         ""
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST "/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#endif
#define JB_PATH(path)     JB_PREFIX path
#define BTSTACK_PLIST     SHOWCASE_BTSTACK_PLIST
#define BTSTACK_SOCKET    SHOWCASE_BTSTACK_SOCKET
#ifndef SHOWCASE_BTDAEMON_PATH
#define SHOWCASE_BTDAEMON_PATH JB_PATH("/usr/bin/BTdaemon")
#endif
#define BTDAEMON_PATH     SHOWCASE_BTDAEMON_PATH
#ifndef SHOWCASE_BTSTACK_DYLIB_PATH
#define SHOWCASE_BTSTACK_DYLIB_PATH JB_PATH("/usr/lib/libBTstack.dylib")
#endif
#define BTSTACK_DYLIB_PATH SHOWCASE_BTSTACK_DYLIB_PATH
#ifndef SHOWCASE_BTSTACK_LOG_PATH
#define SHOWCASE_BTSTACK_LOG_PATH "/var/log/BTstack.log"
#endif
#ifdef SHOWCASE_ROOTLESS
#define BT_HELPER_NAME    "CarDisplaySim"
#define SVC_HELPER_NAME   "CarPlay Simulator"
#else
#define BT_HELPER_NAME    "carplay_bt"
#define SVC_HELPER_NAME   "carplay_services"
#endif
#define AP_INTERFACE      "bridge100"
#define PHONE_CANVAS_W    1024.0
#define PHONE_CANVAS_H    768.0
#define BTSTACK_PREFS_DIR "/var/mobile/Library/Preferences"
#define BTSTACK_PREFS     BTSTACK_PREFS_DIR "/ch.ringwald.btstack.plist"

/* IPC message types */
#define MSG_VIDEO_CONFIG  0x01
#define MSG_VIDEO_FRAME   0x02
#define MSG_TOUCH         0x03
#define MSG_STATUS        0x04   /* services → app, 1 byte status code */
#define MSG_APP_VISIBILITY 0x05  /* app → services, 1 while foreground */
#define MSG_VIDEO_TIMING  0x06   /* services → app, uint32 latency in ms */
#define MSG_VIDEO_RESYNC  0x07   /* app → services, renderer needs keyframe */
#define MSG_AUDIO_CONFIG  0x08   /* services → app, negotiated audio stream */
#define MSG_AUDIO_PACKET  0x09   /* services → app, decrypted RTP payload */
#define MSG_BT_HANDOFF    0x0A   /* services → app, end Bluetooth transport */
#define MSG_AUDIO_RENDER  0x0B   /* app → services, hardware render clock */
#define MSG_AUDIO_CONTROL 0x0C   /* services → app, buffered playback control */
#define VIDEO_FRAME_METADATA_SIZE 56
#define VIDEO_STALE_RECOVERY_MIN_MS 250.0

#define AUDIO_CONTROL_PAUSE  0
#define AUDIO_CONTROL_RESUME 1
#define AUDIO_CONTROL_FLUSH  2
#define AUDIO_CONTROL_STOP   3

#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04
#define STATUS_PAIR_SETUP_STARTED   0x05
#define STATUS_AUTH_COMPLETE        0x06
#define STATUS_SESSION_SETUP        0x07

#define TOUCH_DOWN  0
#define TOUCH_MOVE  1
#define TOUCH_UP    2
#define TOUCH_CANCEL 3

typedef NS_ENUM(NSInteger, ShowcaseState) {
    StateIdle = 0,
    StateAwaitingAP,
    StatePreparingBT,
    StatePreparingNet,
    StateAwaitingPhone,
    StateActive,
    StateStopping,
};

static const char *launchctl_path(void) {
#ifdef SHOWCASE_ROOTLESS
    static const char *paths[] = {
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        "/bin/launchctl",
        "/usr/bin/launchctl",
        NULL
    };
#else
    static const char *paths[] = {
        "/bin/launchctl",
        "/usr/bin/launchctl",
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        NULL
    };
#endif
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

/*
 * Hand the controller back to Apple's stack: BlueTool first, because
 * bluetoothd asks it to initialise the chip, then bluetoothd.
 *
 * The rootful BTstack daemon unloads BlueTool when it powers the controller
 * on and only reloads it in a clean power-off path that launchctl unload
 * never reaches. Without BlueTool, bluetoothd retries forever: measured on an
 * iPad4,2, bluetoothd 52% plus powerd 43% CPU until reboot. While bluetoothd
 * itself is unloaded, launchd and mediaserverd keep looking it up and burn
 * 57% and 50%. Loading an already loaded job is harmless.
 */
static int run_blocking(const char *path, char *const argv[]);
#define BT_GUARD_DIR "/var/root/Library/ShowcaseBluetooth"
#define BT_GUARD_PLIST BT_GUARD_DIR "/recovery.plist"
#define BT_GUARD_READY BT_GUARD_DIR "/ready"
/* Exists while BTstack owns the controller; the Taurine package's BTQuiet
 * throttles Bluetooth clients' reconnects only then. /tmp is emptied at boot. */
#define BT_OWNED_FLAG "/tmp/showcase_bt_owned"
#ifdef SHOWCASE_TAURINE
/* Controller init takes about thirty seconds on an A10 iPad on iOS 14. */
#define BT_READY_SECONDS 45
#define BT_RETRY_READY_SECONDS 45
#else
#define BT_READY_SECONDS 12
#define BT_RETRY_READY_SECONDS 20
#endif

static void stop_bluetooth_guard(void) {
    const char *ctl = launchctl_path();
    if (!ctl) return;
    char *args[] = { (char *)"launchctl", (char *)"unload",
                     (char *)BT_GUARD_PLIST, NULL };
    run_blocking(ctl, args);
    unlink(BT_GUARD_READY);
}

/* launchd owns this shell, so an app crash/force-quit cannot kill recovery.
 * Arm it before removing Apple's services; disarm only after returning them.
 * All shell inputs are positional arguments, never interpolated commands. */
static BOOL start_bluetooth_guard(void) {
    const char *ctl = launchctl_path();
    if (!ctl) return NO;
    mkdir(BT_GUARD_DIR, 0700);
    struct stat st;
    if (lstat(BT_GUARD_DIR, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != 0 || (st.st_mode & 077) != 0) return NO;
    stop_bluetooth_guard();
    NSString *script =
        @"echo ready > \"$6\"; "
         "while kill -0 \"$1\" 2>/dev/null; do sleep 1; done; "
         "\"$7\" -TERM CarDisplaySim 2>/dev/null; "
         "\"$2\" unload \"$3\"; "
         "rm -f \"$8\"; "
         "\"$2\" load \"$4\"; \"$2\" load \"$5\"; "
         "rm -f \"$9\"; "
         "rm -f \"$6\"";
    NSDictionary *job = @{
        @"Label": @"com.reng.showcase.bluetooth-recovery",
        @"ProgramArguments": @[@JB_PATH("/bin/sh"), @"-c", script,
            @"showcase-bluetooth-recovery", [NSString stringWithFormat:@"%d", getpid()],
            @(ctl), @BTSTACK_PLIST, @BLUETOOL_PLIST, @BLUETOOTHD_PLIST,
            @BT_GUARD_READY, @JB_PATH("/usr/bin/killall"), @BTSTACK_SOCKET,
            @BT_OWNED_FLAG],
        @"RunAtLoad": @YES,
        @"EnvironmentVariables": @{@"PATH": @JB_PATH("/usr/bin") ":" JB_PATH("/bin") ":/usr/bin:/bin"},
        @"StandardOutPath": @LOG_DIR "/bluetooth-recovery.log",
        @"StandardErrorPath": @LOG_DIR "/bluetooth-recovery.log"
    };
    if (![job writeToFile:@BT_GUARD_PLIST atomically:YES]) return NO;
    char *args[] = { (char *)"launchctl", (char *)"load",
                     (char *)BT_GUARD_PLIST, NULL };
    if (run_blocking(ctl, args) != 0) return NO;
    for (int i = 0; i < 50; i++) {
        if (access(BT_GUARD_READY, F_OK) == 0) return YES;
        usleep(100000);
    }
    ip_log("[BT] recovery guard did not start; keeping system Bluetooth loaded");
    return NO;
}

static void restore_system_bluetooth(const char *reason) {
    const char *launchctl = launchctl_path();
    if (!launchctl) return;
    char *loadBlueTool[] = { (char *)"launchctl", (char *)"load",
                             (char *)BLUETOOL_PLIST, NULL };
    char *loadBluetoothd[] = { (char *)"launchctl", (char *)"load",
                               (char *)BLUETOOTHD_PLIST, NULL };
    int toolRc = run_blocking(launchctl, loadBlueTool);
    int daemonRc = run_blocking(launchctl, loadBluetoothd);
    unlink(BT_OWNED_FLAG);
    ip_log("[BT] system Bluetooth load requested (%s): BlueTool=%d bluetoothd=%d",
           reason, toolRc, daemonRc);
    stop_bluetooth_guard();
}

/* ═══════════════════════════════════════════════════════════════
 * Globals
 * ═══════════════════════════════════════════════════════════════ */

static volatile int g_touch_fd = -1;
static volatile uint32_t g_touch_epoch = 0;
static dispatch_queue_t g_touch_write_queue = NULL;
static volatile float g_carplay_w = 0;
static volatile float g_carplay_h = 0;
static volatile int32_t g_video_suspended = 0;
static volatile int32_t g_video_needs_resync = 0;
static volatile uint32_t g_video_target_latency_ms = 75;
static volatile int32_t g_video_respect_timestamps = 0;
static volatile double g_video_sender_to_host_offset = 0.0;
static volatile int32_t g_video_timing_offset_valid = 0;

/* ── Sender-timeline clock recovery and presentation scheduling ───
 * Every VideoFrame carries params[0]: a 32.32 fixed-point instant on the
 * sender's session timeline. Presenting a frame needs that instant expressed in
 * host time, which means an offset between the two clocks plus a budget for
 * transport jitter.
 *
 * Offset. Estimated from the minimum of (hostArrival - senderTime): the
 * fastest-delivered frame is the one that suffered least queueing, so it is the
 * best available view of the true offset. The minimum is taken over a trailing
 * window rather than the whole session, otherwise a single unusually fast frame
 * anchors the timeline forever and the budget silently erodes. The applied
 * offset slews toward that target instead of stepping, because a step moves
 * every future frame's slot and shows up as a hitch.
 *
 * Budget. Fixed at the sender's latencyMs, frames whose transport delay exceeds
 * it miss their slot. The budget therefore tracks recent jitter and grows up to
 * the 2x latency that the AccessorySDK itself treats as the late threshold.
 *
 * Pacing. A frame that has missed its slot must not simply be dumped at "now":
 * after a hiccup a whole burst arrives at once, every frame lands within a
 * millisecond or two, and the display shows only the last of them — the same
 * collapse that displaying on arrival caused. Late frames are instead paced off
 * the previous frame's presentation time at slightly under one frame interval,
 * so the backlog drains in order and slightly faster than real time until it
 * rejoins the grid. This also makes presentation timestamps monotonic by
 * construction.
 * ──────────────────────────────────────────────────────────────── */
#define VIDEO_CLOCK_WINDOW_SECONDS  8.0    /* trailing window for the offset   */
#define VIDEO_CLOCK_SLEW_PER_SEC    0.004  /* 4 ms/s, both directions          */
#define VIDEO_CLOCK_RESET_SECONDS   5.0    /* beyond this, a new timeline      */
/* Budget sizing. The AccessorySDK never adds latencyMs to the display time at
 * all — it maps the timestamp through the synchronised clock and presents at
 * exactly that instant, using latencyMs only to decide what counts as late.
 * Our anchor is a delay minimum rather than a true NTP clock, so some budget is
 * required, but latencyMs is the sender's statement of expected latency and so
 * belongs as the ceiling, never the floor. Buffering is the expensive way to
 * buy smoothness: every millisecond here is a millisecond of touch response.
 * Pacing absorbs the tail instead. */
#define VIDEO_BUDGET_FLOOR_FRAMES   2.0    /* two frames of slack, ~33 ms      */
#define VIDEO_JITTER_DEVIATIONS     3.0    /* budget = mean + 3 deviations     */
#define VIDEO_JITTER_EWMA_SHIFT     16.0   /* smoothing for mean and deviation */
#define VIDEO_CATCHUP_GAP_FRACTION  0.80   /* drain bursts 20% faster than 1x  */
#define VIDEO_FRAME_INTERVAL_MIN    (1.0 / 240.0)
#define VIDEO_FRAME_INTERVAL_MAX    (1.0 / 15.0)

static double g_video_clock_offset = 0.0;   /* hostTime - senderTime, seconds */
static double g_video_clock_last_update = 0.0;
static bool   g_video_clock_valid = false;
static double g_video_window_min = 0.0;     /* min delay, current window      */
static double g_video_window_prev_min = 0.0;/* min delay, previous window     */
static double g_video_window_start = 0.0;
static bool   g_video_window_has_sample = false;
static double g_video_jitter_mean = 0.0;    /* EWMA of delay above offset     */
static double g_video_jitter_dev = 0.0;     /* EWMA of deviation from mean    */
static double g_video_budget_seconds = 0.0; /* applied jitter budget          */
static double g_video_last_pts = 0.0;       /* last scheduled presentation    */
static bool   g_video_last_pts_valid = false;
static double g_video_last_sender = 0.0;
static bool   g_video_last_sender_valid = false;
static double g_video_frame_interval = 1.0 / 60.0;  /* sender's actual cadence */

static void video_clock_reset(void) {
    g_video_clock_valid = false;
    g_video_clock_offset = 0.0;
    g_video_clock_last_update = 0.0;
    g_video_window_min = 0.0;
    g_video_window_prev_min = 0.0;
    g_video_window_start = 0.0;
    g_video_window_has_sample = false;
    g_video_jitter_mean = 0.0;
    g_video_jitter_dev = 0.0;
    g_video_budget_seconds = 0.0;
    g_video_last_pts = 0.0;
    g_video_last_pts_valid = false;
    g_video_last_sender = 0.0;
    g_video_last_sender_valid = false;
    g_video_frame_interval = 1.0 / 60.0;
}

/* Computes the presentation host time for a frame. outMissedSlot reports that
 * the frame's own slot had already passed, i.e. transport exceeded the budget,
 * and outLatenessSeconds by how much.
 *
 * Magnitude is what matters, not the count. Apple's own receiver, measured on a
 * wired link, reports roughly half its frames past their slot — but never by
 * more than about 11 ms, and its headroom sits around 33 ms. A high late count
 * with small magnitudes is normal; large magnitudes are the defect. */
static double video_clock_schedule(uint64_t senderTimestamp,
                                   double hostArrival,
                                   bool *outMissedSlot,
                                   double *outLatenessSeconds) {
    double senderSeconds = (double)senderTimestamp / 4294967296.0;

    /*
     * Normal path: use the NTP mapping measured on the AirPlay timing socket.
     * This is what CarPlaySDK does through
     * AirTunesClock_GetUpTicksNearSynchronizedNTPTime. Arrival time is not a
     * clock sample; it includes Wi-Fi and TCP jitter, so it must never move a
     * correctly synchronized presentation timestamp.
     */
    if (g_video_timing_offset_valid) {
        double pts = senderSeconds + g_video_sender_to_host_offset;
        bool missed = pts <= hostArrival;
        if (outMissedSlot) *outMissedSlot = missed;
        if (outLatenessSeconds)
            *outLatenessSeconds = missed ? hostArrival - pts : 0.0;
        if (g_video_last_sender_valid) {
            double senderDelta = senderSeconds - g_video_last_sender;
            if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
                senderDelta <= VIDEO_FRAME_INTERVAL_MAX)
                g_video_frame_interval = senderDelta;
        }
        g_video_budget_seconds = 0.0;
        g_video_clock_offset = g_video_sender_to_host_offset;
        g_video_clock_valid = true;
        g_video_last_pts = pts;
        g_video_last_pts_valid = true;
        g_video_last_sender = senderSeconds;
        g_video_last_sender_valid = true;
        return pts;
    }

    double observed = hostArrival - senderSeconds;
    double latencySeconds = (double)g_video_target_latency_ms / 1000.0;

    if (!g_video_clock_valid ||
        fabs(observed - g_video_clock_offset) > VIDEO_CLOCK_RESET_SECONDS) {
        g_video_clock_valid = true;
        g_video_clock_offset = observed;
        g_video_clock_last_update = hostArrival;
        g_video_window_min = observed;
        g_video_window_prev_min = observed;
        g_video_window_start = hostArrival;
        g_video_window_has_sample = true;
        g_video_jitter_mean = 0.0;
        g_video_jitter_dev = 0.0;
        g_video_budget_seconds = 0.0;
        g_video_last_pts_valid = false;
        g_video_last_sender_valid = false;
    }

    /* Trailing-window minimum, kept as two half-windows so the estimate can
     * rise again when the path genuinely slows down. */
    if (!g_video_window_has_sample || observed < g_video_window_min)
        g_video_window_min = observed;
    g_video_window_has_sample = true;
    double jitter = observed - g_video_clock_offset;
    if (jitter < 0) jitter = 0;
    double deviation = fabs(jitter - g_video_jitter_mean);
    g_video_jitter_mean += (jitter - g_video_jitter_mean) / VIDEO_JITTER_EWMA_SHIFT;
    g_video_jitter_dev  += (deviation - g_video_jitter_dev) / VIDEO_JITTER_EWMA_SHIFT;

    if (hostArrival - g_video_window_start >= VIDEO_CLOCK_WINDOW_SECONDS) {
        g_video_window_prev_min = g_video_window_min;
        g_video_window_min = observed;
        g_video_window_start = hostArrival;
    }

    double target = g_video_window_min < g_video_window_prev_min
                  ? g_video_window_min : g_video_window_prev_min;
    double elapsed = hostArrival - g_video_clock_last_update;
    if (elapsed > 0) {
        double allowed = elapsed * VIDEO_CLOCK_SLEW_PER_SEC;
        double delta = target - g_video_clock_offset;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_clock_offset += delta;
    }
    g_video_clock_last_update = hostArrival;

    /* Budget from the smoothed jitter estimate. A window maximum was pinned at
     * the ceiling by a single bad frame per window and never recovered, which
     * spent the whole allowance on latency without buying smoothness. */
    double wanted = g_video_jitter_mean +
                    VIDEO_JITTER_DEVIATIONS * g_video_jitter_dev;
    double floorBudget = g_video_frame_interval * VIDEO_BUDGET_FLOOR_FRAMES;
    if (wanted < floorBudget) wanted = floorBudget;
    if (wanted > latencySeconds) wanted = latencySeconds;
    if (g_video_budget_seconds <= 0.0) g_video_budget_seconds = wanted;
    else if (elapsed > 0) {
        /* Grow quickly to stop dropping frames, shrink slowly to hold latency
         * down without oscillating. */
        double rate = (wanted > g_video_budget_seconds) ? 0.050 : 0.005;
        double allowed = elapsed * rate;
        double delta = wanted - g_video_budget_seconds;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_budget_seconds += delta;
    }

    double gridPTS = senderSeconds + g_video_clock_offset + g_video_budget_seconds;

    /* Pace anything that missed its slot instead of dumping it at "now". */
    double interval = g_video_frame_interval;
    if (g_video_last_sender_valid) {
        double senderDelta = senderSeconds - g_video_last_sender;
        if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
            senderDelta <= VIDEO_FRAME_INTERVAL_MAX) {
            interval = senderDelta;
            g_video_frame_interval = senderDelta;
        }
    }
    double floorPTS = hostArrival;
    if (g_video_last_pts_valid) {
        floorPTS = g_video_last_pts + interval * VIDEO_CATCHUP_GAP_FRACTION;
        if (floorPTS < hostArrival) floorPTS = hostArrival;
    }

    bool missed = (gridPTS <= hostArrival);
    double pts = (gridPTS > floorPTS) ? gridPTS : floorPTS;
    if (outLatenessSeconds)
        *outLatenessSeconds = missed ? (hostArrival - gridPTS) : 0.0;

    g_video_last_pts = pts;
    g_video_last_pts_valid = true;
    g_video_last_sender = senderSeconds;
    g_video_last_sender_valid = true;
    if (outMissedSlot) *outMissedSlot = missed;
    return pts;
}

static double video_host_now(void) {
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

/* AVSampleBufferDisplayLayer ignores presentationTimeStamp unless a control
 * timebase is attached — without one it paints every buffer as soon as it is
 * enqueued, which is the behaviour we are removing. Running the timebase on the
 * host clock at rate 1.0 makes sample PTS values plain host-time seconds. */
static void video_install_timebase(AVSampleBufferDisplayLayer *layer) {
    if (!layer || layer.controlTimebase) return;
    CMTimebaseRef timebase = NULL;
    OSStatus status = CMTimebaseCreateWithMasterClock(
        kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    if (status != noErr || !timebase) {
        ip_log("timebase create failed (%d); falling back to immediate display",
               (int)status);
        return;
    }
    CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()));
    CMTimebaseSetRate(timebase, 1.0);
    layer.controlTimebase = timebase;
    CFRelease(timebase);
}

typedef NS_ENUM(uint8_t, CarPlayWLANAttachment) {
    CarPlayWLANAttachmentUnknown = 0,
    CarPlayWLANAttachmentHSIC,
    CarPlayWLANAttachmentPCIe,
};

static const char *carplay_wlan_attachment_name(
    CarPlayWLANAttachment attachment) {
    switch (attachment) {
        case CarPlayWLANAttachmentHSIC: return "HSIC";
        case CarPlayWLANAttachmentPCIe: return "PCIe";
        default: return "unknown";
    }
}

typedef struct {
    uint16_t width;
    uint16_t height;
    uint16_t nativeLong;
    uint16_t nativeShort;
    uint64_t pixelBudget;
    uint64_t physicalMemory;
    NSUInteger activeProcessors;
    uint16_t framesPerSecond;
    CarPlayWLANAttachment wlanAttachment;
} CarPlayDisplayProfile;

static const char *first_existing_tool(const char *const paths[]);

static NSData *capture_process_output(const char *path, char *const argv[]) {
    int pipes[2];
    if (!path || pipe(pipes) != 0) return nil;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], 1);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);

    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (spawnError != 0) {
        close(pipes[0]);
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[8192];
    for (;;) {
        ssize_t count = read(pipes[0], buffer, sizeof(buffer));
        if (count > 0) {
            [output appendBytes:buffer length:(NSUInteger)count];
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(pipes[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return output;
}

static NSString *wlan_ioreg_snapshot(BOOL fullTree) {
    const char *ioregPaths[] = { "/usr/sbin/ioreg", "/usr/bin/ioreg", NULL };
    const char *ioreg = first_existing_tool(ioregPaths);
    if (!ioreg) return nil;
    char *fullArgv[] = {
        (char *)"ioreg", (char *)"-l", (char *)"-w", (char *)"0", NULL
    };
    char *interfaceArgv[] = {
        (char *)"ioreg", (char *)"-r", (char *)"-c",
        (char *)"IO80211Interface", (char *)"-l", (char *)"-w",
        (char *)"0", NULL
    };
    NSData *data = capture_process_output(
        ioreg, fullTree ? fullArgv : interfaceArgv);
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

typedef NS_ENUM(NSInteger, BluetoothRegistryProbeState) {
    BluetoothRegistryProbeUnavailable = -1,
    BluetoothRegistryProbeMissing = 0,
    BluetoothRegistryProbeLegacyUART = 1,
    BluetoothRegistryProbeSkywalk = 2,
};

static BluetoothRegistryProbeState bluetooth_registry_probe(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return BluetoothRegistryProbeUnavailable;

        BOOL uartService =
            [tree rangeOfString:@"<class AppleSimpleUARTSync"].location !=
                NSNotFound;
        BOOL bluetoothEndpoint =
            [tree rangeOfString:@"\"IOTTYBaseName\" = \"bluetooth\""].location !=
                NSNotFound ||
            [tree rangeOfString:@"\"device_type\" = <\"bluetooth\">"].location !=
                NSNotFound ||
            [tree rangeOfString:@"com.apple.uart.bluetooth"].location !=
                NSNotFound;
        BOOL convergedInterface =
            [tree rangeOfString:@"AppleConvergedIPCRTIInterface"].location !=
                NSNotFound ||
            [tree rangeOfString:@"AppleConvergedIPCInterface"].location !=
                NSNotFound;
        BOOL skywalkTransport =
            [tree rangeOfString:@"\"ACIPCInterfaceTransport\" = \"skywalk\""]
                    .location != NSNotFound;
        BOOL hciProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"hci\""]
                    .location != NSNotFound;
        BOOL aclProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"acl\""]
                    .location != NSNotFound;
        BOOL nexusUUID =
            [tree rangeOfString:@"IOSkywalkNexusUUID"].location != NSNotFound;
        if (convergedInterface && skywalkTransport && hciProtocol &&
            aclProtocol && nexusUUID) {
            return BluetoothRegistryProbeSkywalk;
        }
        return uartService && bluetoothEndpoint
            ? BluetoothRegistryProbeLegacyUART
            : BluetoothRegistryProbeMissing;
    }
}

static NSString *hardware_machine_identifier(void) {
    char machine[128] = {0};
    size_t length = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 &&
        machine[0]) {
        machine[sizeof(machine) - 1] = '\0';
        return [NSString stringWithUTF8String:machine];
    }
    return @"unknown";
}

static NSString *bounded_log_tail(NSString *path, NSUInteger maxBytes,
                                  NSUInteger maxLines) {
    if (!path.length || maxBytes == 0 || maxLines == 0) return @"";
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) return @"";
        unsigned long long end = [handle seekToEndOfFile];
        unsigned long long start = end > maxBytes ? end - maxBytes : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        if (!data.length) return @"";

        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [[NSString alloc] initWithData:data
                                         encoding:NSISOLatin1StringEncoding];
        }
        if (!text.length) return @"";
        NSArray<NSString *> *lines =
            [text componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
        NSUInteger first = lines.count > maxLines ? lines.count - maxLines : 0;
        NSArray<NSString *> *tail =
            [lines subarrayWithRange:NSMakeRange(first, lines.count - first)];
        return [tail componentsJoinedByString:@"\n"];
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

static NSString *bluetooth_failure_class(NSString *reason,
                                          NSString *combinedLogs,
                                          BluetoothRegistryProbeState registry) {
    NSString *lower = [[NSString stringWithFormat:@"%@\n%@",
                        reason ?: @"", combinedLogs ?: @""] lowercaseString];
    NSString *reasonLower = [reason.lowercaseString copy] ?: @"";
    if ([reasonLower containsString:@"btstack daemon is missing"])
        return @"btstack-daemon-missing";
    if ([reasonLower containsString:@"btstack library is missing"])
        return @"btstack-library-missing";
    if ([reasonLower containsString:@"launch daemon configuration is missing"])
        return @"btstack-launch-configuration-missing";
    if (registry == BluetoothRegistryProbeMissing)
        return @"supported-bluetooth-transport-not-present";
    if ([lower containsString:@"skywalk is present"] &&
        [lower containsString:@"userspace api is unavailable"])
        return @"converged-skywalk-api-unavailable";
    if ([lower containsString:@"skywalk:"] &&
        [lower containsString:@"channel create failed"])
        return @"converged-skywalk-channel-open-failed";
    if ([lower containsString:@"h4_open: ioctl failed"])
        return @"private-uart-endpoint-unavailable";
    if ([lower containsString:@"h4_open: socket failed"])
        return @"netgraph-control-socket-unavailable";
    if ([lower containsString:@"h4_open: connect failed"])
        return @"bluetooth-uart-connect-failed";
    if ([lower containsString:@"h4_open: getsockopt failed"] ||
        [lower containsString:@"h4_open: setsockopt failed"])
        return @"bluetooth-uart-configuration-failed";
    if ([lower containsString:@"btstack_event_poweron_failed"] ||
        [lower containsString:@"poweron_failed"])
        return @"controller-power-on-failed";
    if ([lower containsString:@"ioregisterforsystempower failed"])
        return @"bluetooth-power-registration-failed";
    if ([lower containsString:@"socket not available"])
        return @"btstack-daemon-socket-unavailable";
    if ([lower containsString:@"launch daemon failed"])
        return @"btstack-launch-failed";
    if ([lower containsString:@"ready sentinel"])
        return @"no-hci-events-before-timeout";
    return @"bluetooth-takeover-failed";
}

static NSDictionary *usage_values(void);

static NSString *bluetooth_diagnostic_report(
    NSString *reason, BOOL retryAttempted,
    BluetoothRegistryProbeState registry) {
    NSString *initial = bounded_log_tail(
        @LOG_DIR "/carplay_bt.log", 8192, 18);
    NSString *retry = retryAttempted
        ? bounded_log_tail(@LOG_DIR "/carplay_bt-retry.log", 8192, 18)
        : @"";
    NSString *daemon = bounded_log_tail(@SHOWCASE_BTSTACK_LOG_PATH, 8192, 18);
    NSString *combined = [NSString stringWithFormat:@"%@\n%@\n%@",
                          initial ?: @"", retry ?: @"", daemon ?: @""];
    NSString *failureClass =
        bluetooth_failure_class(reason, combined, registry);
    NSString *registryText = registry == BluetoothRegistryProbeLegacyUART
        ? @"legacy-uart-present"
        : (registry == BluetoothRegistryProbeSkywalk
            ? @"converged-skywalk-present"
            : (registry == BluetoothRegistryProbeMissing
                ? @"supported-transport-missing" : @"unavailable"));
#ifdef SHOWCASE_ROOTLESS
    NSString *layout = @"rootless";
#else
    NSString *layout = @"rootful";
#endif

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Showcase Bluetooth compatibility report\n"];
    [report appendFormat:@"version=%s\n", APP_VERSION];
    [report appendFormat:@"package=%@ jailbreak=%@\n", usage_values()[@"package"], usage_values()[@"jailbreak"]];
    [report appendFormat:@"device=%@\n", hardware_machine_identifier()];
    [report appendFormat:@"ios=%@\n", [UIDevice currentDevice].systemVersion];
    [report appendFormat:@"layout=%@ (diagnostic only)\n", layout];
    [report appendFormat:@"failure_class=%@\n", failureClass];
    [report appendFormat:@"stage=%@\n", reason ?: @"unknown"];
    [report appendFormat:@"euid=%u\n", geteuid()];
    [report appendFormat:@"registry=%@\n", registryText];
    [report appendFormat:@"helper=%s executable=%s\n", BT_HELPER_NAME,
        access([[[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@BT_HELPER_NAME] UTF8String],
            X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"btdaemon=%s executable=%s\n", BTDAEMON_PATH,
        access(BTDAEMON_PATH, X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"libbtstack=%s readable=%s\n", BTSTACK_DYLIB_PATH,
        access(BTSTACK_DYLIB_PATH, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"launch_plist=%s readable=%s\n", BTSTACK_PLIST,
        access(BTSTACK_PLIST, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"retry=%@\n", retryAttempted ? @"yes" : @"no"];
    if (initial.length)
        [report appendFormat:@"\ncarplay_bt tail:\n%@\n", initial];
    if (retry.length)
        [report appendFormat:@"\ncarplay_bt retry tail:\n%@\n", retry];
    if (daemon.length)
        [report appendFormat:@"\nBTstack daemon tail:\n%@\n", daemon];
    return report;
}

static CarPlayWLANAttachment wlan_attachment_class(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return CarPlayWLANAttachmentUnknown;

        /*
         * Match instantiated transport services and device-tree compatibility
         * strings. Do not use the IOKitDiagnostics class table: a driver class
         * may be present with zero live instances on unrelated hardware.
         */
        NSArray<NSString *> *hsicMarkers = @[
            @"<class AppleBCMWLANBusInterfaceHSIC",
            @"<class AppleBCMWLANChipManagerHSIC",
            @"AppleBCMWLANBusInterfaceHSICShim",
            @"wlan-hsic"
        ];
        for (NSString *marker in hsicMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentHSIC;
        }

        NSArray<NSString *> *pcieMarkers = @[
            @"<class AppleBCMWLANBusInterfacePCIe",
            @"<class AppleBCMWLANPCIe",
            @"wlan-pcie"
        ];
        for (NSString *marker in pcieMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentPCIe;
        }
        return CarPlayWLANAttachmentUnknown;
    }
}

/* BEGIN display selector: plain C, compiled by tests/test_display_profile.py */
#define CARPLAY_MAX_WIDTH 1920
#define CARPLAY_MAX_PIXELS (1920ULL * 1080ULL)
#define CARPLAY_MAX_OPTIONS 8

typedef struct { uint16_t width, height; } CarPlayVideoSize;

typedef enum {
    CarPlayVideoCustom = 0,
    CarPlayVideoQuality,
    CarPlayVideoPerformance,
} CarPlayVideoPriority;

/* The stream is sized from the receiver's screen and capability, never from
 * jailbreak layout. One-gigabyte devices share memory bandwidth between
 * UIKit, VideoToolbox, the CarPlay service and the hotspot, so they default
 * to a 960x720-class stream; two gigabytes and above to 720p-class. */
static uint64_t carplay_default_budget(double nativeLong, double nativeShort,
                                       uint64_t memory, unsigned processors) {
    uint64_t pixelBudget = 960ULL * 720ULL;
    if (memory >= 1536ULL * 1024ULL * 1024ULL)
        pixelBudget = 1280ULL * 720ULL;
    if (memory >= 3ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 4)
        pixelBudget = 1600ULL * 900ULL;
    if (memory >= 4ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 6)
        pixelBudget = CARPLAY_MAX_PIXELS;
    uint64_t nativePixels = (uint64_t)nativeLong * (uint64_t)nativeShort;
    if (nativePixels > 0 && pixelBudget > nativePixels)
        pixelBudget = nativePixels;
    return pixelBudget;
}

/* Codec-friendly 16-pixel dimensions. The score rewards using the budget but
 * penalizes aspect error heavily, so the stream fills the screen unstretched. */
static CarPlayVideoSize carplay_fit(double nativeLong, double nativeShort, uint64_t pixelBudget) {
    double aspect = nativeShort > 0 ? nativeLong / nativeShort : (5.0 / 3.0);
    CarPlayVideoSize best = {800, 480};
    double bestScore = -DBL_MAX;
    uint16_t maxWidth = (uint16_t)(floor(MIN(nativeLong, (double)CARPLAY_MAX_WIDTH) / 16.0) * 16.0);
    for (uint16_t width = 640; width <= maxWidth; width = (uint16_t)(width + 16)) {
        uint16_t height = (uint16_t)(floor(((width / aspect) / 16.0) + 0.5) * 16.0);
        if (height < 360 || height > nativeShort) continue;
        uint64_t pixels = (uint64_t)width * height;
        if (pixels > pixelBudget) continue;
        double aspectError = fabs((double)width / height - aspect) / aspect;
        double score = (pixelBudget ? (double)pixels / (double)pixelBudget : 0) - aspectError * 10.0;
        if (score > bestScore) {
            bestScore = score;
            best.width = width;
            best.height = height;
        }
    }
    return best;
}

/* The resolutions offered in Settings, largest first, like the scaled
 * resolutions macOS lists for a display. Each step has about half to
 * two-thirds of the previous one's pixels and takes the size closest to the
 * screen's aspect ratio there (within 1%). The default is always listed, and
 * a size within a fifth of its pixels is left out. Returns how many. */
static unsigned carplay_resolution_options(double nativeLong, double nativeShort, CarPlayVideoSize fallback,
                                           CarPlayVideoSize out[CARPLAY_MAX_OPTIONS]) {
    double aspect = nativeShort > 0 ? nativeLong / nativeShort : (5.0 / 3.0);
    uint16_t maxWidth = (uint16_t)(floor(MIN(nativeLong, (double)CARPLAY_MAX_WIDTH) / 16.0) * 16.0);
    CarPlayVideoSize candidates[128];
    double errors[128];
    unsigned found = 0;
    for (uint16_t width = maxWidth; width >= 640 && found < 128; width = (uint16_t)(width - 16)) {
        uint16_t height = (uint16_t)(floor(((width / aspect) / 16.0) + 0.5) * 16.0);
        double error = fabs((double)width / height - aspect) / aspect;
        if (height < 360 || height > nativeShort || (uint64_t)width * height > CARPLAY_MAX_PIXELS || error > 0.01)
            continue;
        candidates[found].width = width;
        candidates[found].height = height;
        errors[found++] = error;
    }
    uint64_t fallbackPixels = (uint64_t)fallback.width * fallback.height;
    unsigned count = 0;
    uint64_t ceiling = found ? (uint64_t)candidates[0].width * candidates[0].height : 0;
    uint64_t floor_ = ceiling * 8 / 10;
    while (count < CARPLAY_MAX_OPTIONS - 1) {
        int best = -1;
        for (unsigned i = 0; i < found; i++) {
            uint64_t pixels = (uint64_t)candidates[i].width * candidates[i].height;
            if (pixels > ceiling || pixels <= floor_) continue;
            if (best < 0 || errors[i] < errors[best] - 1e-9) best = (int)i;
        }
        if (best < 0) break;
        uint64_t pixels = (uint64_t)candidates[best].width * candidates[best].height;
        if (pixels * 5 >= fallbackPixels * 6 || pixels * 5 <= fallbackPixels * 4)
            out[count++] = candidates[best];
        ceiling = pixels * 2 / 3;
        floor_ = pixels / 2;
    }
    unsigned at = 0;
    while (at < count && (uint64_t)out[at].width * out[at].height > fallbackPixels) at++;
    for (unsigned i = count; i > at; i--) out[i] = out[i - 1];
    out[at] = fallback;
    return count + 1;
}

/* Default: the hardware budget at the screen's rate. Quality: the largest
 * offered size at up to 60 fps. Performance: about half the default's pixels
 * at 30 fps, which roughly halves the bytes each frame puts on the hotspot
 * link. Custom: the chosen size and rate when they are still offered. */
static CarPlayVideoSize carplay_select_video(double nativeLong, double nativeShort, uint64_t memory,
                                             unsigned processors, uint16_t defaultFPS, uint16_t screenFPS,
                                             CarPlayVideoPriority priority, CarPlayVideoSize chosen,
                                             uint16_t chosenFPS, uint16_t *fps, uint64_t *budget) {
    uint64_t pixelBudget = carplay_default_budget(nativeLong, nativeShort, memory, processors);
    CarPlayVideoSize fallback = carplay_fit(nativeLong, nativeShort, pixelBudget);
    CarPlayVideoSize options[CARPLAY_MAX_OPTIONS];
    unsigned count = carplay_resolution_options(nativeLong, nativeShort, fallback, options);
    CarPlayVideoSize size = fallback;
    *fps = defaultFPS;
    if (priority == CarPlayVideoQuality) {
        size = options[0];
        *fps = (uint16_t)MAX(30, MIN(screenFPS, 60));
        pixelBudget = (uint64_t)size.width * size.height;
    } else if (priority == CarPlayVideoPerformance) {
        pixelBudget = MAX(640ULL * 384ULL, (pixelBudget * 9ULL) / 16ULL);
        size = carplay_fit(nativeLong, nativeShort, pixelBudget);
        *fps = MIN(defaultFPS, 30);
    } else {
        for (unsigned i = 0; i < count; i++)
            if (options[i].width == chosen.width && options[i].height == chosen.height) {
                size = chosen;
                pixelBudget = (uint64_t)size.width * size.height;
            }
        if (chosenFPS == 30 || (chosenFPS == 60 && screenFPS >= 60)) *fps = chosenFPS;
    }
    *budget = pixelBudget;
    return size;
}
/* END display selector */

/* The receiver's screen and capability. The Wi-Fi bus probe runs ioreg, so
 * the answer is kept for the life of the app. */
typedef struct {
    double nativeLong, nativeShort;
    uint64_t memory;
    unsigned processors;
    uint16_t screenFPS, defaultFPS;
    CarPlayWLANAttachment wlanAttachment;
} CarPlayDisplayHardware;

static CarPlayDisplayHardware carplay_display_hardware(void) {
    static CarPlayDisplayHardware hardware;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGSize nativeSize = [screen respondsToSelector:@selector(nativeBounds)]
            ? screen.nativeBounds.size
            : CGSizeMake(screen.bounds.size.width * screen.scale,
                         screen.bounds.size.height * screen.scale);
        hardware.nativeLong = MAX(nativeSize.width, nativeSize.height);
        hardware.nativeShort = MIN(nativeSize.width, nativeSize.height);
        NSProcessInfo *process = [NSProcessInfo processInfo];
        hardware.memory = process.physicalMemory;
        hardware.processors = (unsigned)process.activeProcessorCount;
        NSInteger screenFPS = [screen respondsToSelector:@selector(maximumFramesPerSecond)]
            ? screen.maximumFramesPerSecond : 60;
        hardware.screenFPS = (uint16_t)MAX(30, MIN(screenFPS, 60));
        hardware.wlanAttachment = wlan_attachment_class();
        /* HSIC-attached Wi-Fi drops bursts; 30 fps halves them. */
        hardware.defaultFPS = hardware.wlanAttachment == CarPlayWLANAttachmentHSIC
            ? 30 : hardware.screenFPS;
    });
    return hardware;
}

static CarPlayVideoPriority carplay_video_priority(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:QUALITY_VIDEO_KEY]) return CarPlayVideoQuality;
    if ([d boolForKey:SMOOTH_VIDEO_KEY]) return CarPlayVideoPerformance;
    return CarPlayVideoCustom;
}

static unsigned carplay_offered_resolutions(CarPlayVideoSize out[CARPLAY_MAX_OPTIONS], CarPlayVideoSize *fallback) {
    CarPlayDisplayHardware h = carplay_display_hardware();
    *fallback = carplay_fit(h.nativeLong, h.nativeShort,
        carplay_default_budget(h.nativeLong, h.nativeShort, h.memory, h.processors));
    return carplay_resolution_options(h.nativeLong, h.nativeShort, *fallback, out);
}

static CarPlayDisplayProfile preferred_carplay_display_profile(void) {
    CarPlayDisplayHardware h = carplay_display_hardware();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CarPlayVideoSize chosen = {
        (uint16_t)[d integerForKey:VIDEO_WIDTH_KEY], (uint16_t)[d integerForKey:VIDEO_HEIGHT_KEY]};
    uint16_t fps = 0;
    uint64_t budget = 0;
    CarPlayVideoSize size = carplay_select_video(h.nativeLong, h.nativeShort, h.memory, h.processors,
        h.defaultFPS, h.screenFPS, carplay_video_priority(), chosen,
        (uint16_t)[d integerForKey:VIDEO_FPS_KEY], &fps, &budget);
    CarPlayDisplayProfile profile = {
        .width = size.width,
        .height = size.height,
        .nativeLong = (uint16_t)h.nativeLong,
        .nativeShort = (uint16_t)h.nativeShort,
        .pixelBudget = budget,
        .physicalMemory = h.memory,
        .activeProcessors = h.processors,
        .framesPerSecond = fps,
        .wlanAttachment = h.wlanAttachment,
    };
    return profile;
}

/* ═══════════════════════════════════════════════════════════════
 * Dedicated radio: leave other Wi-Fi networks during CarPlay
 *
 * The receiver's single Wi-Fi radio otherwise stays joined to the home or
 * office network while it hosts the CarPlay hotspot. iOS puts the hotspot on
 * 2.4 GHz (channel 1, 6, or 11) and that network is usually on 5 GHz, so the
 * radio time-shares between two bands. Each time it serves the other network,
 * the hotspot channel goes dark: the iPhone's frames go unacknowledged and
 * queue, then arrive in bursts. Measured on an iPad4,2: with the home network
 * joined, 12% of received frames were discarded and video gaps reached 3 s;
 * hotspot only, frame delivery more than doubled and gaps fell under 1 s.
 *
 * A CarPlay head unit never joins another network. While CarPlay runs, the
 * joined network's auto-join is paused and the radio disassociates; stopping
 * CarPlay re-enables it. The network name is persisted so a session ended by
 * a crash is restored on the next launch.
 * ═══════════════════════════════════════════════════════════════ */

static void *showcase_mobilewifi_symbol(const char *name) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
                        RTLD_NOW);
    });
    return handle ? dlsym(handle, name) : NULL;
}

static void *showcase_wifi_manager(void) {
    static void *manager = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *(*create)(CFAllocatorRef, int) =
            showcase_mobilewifi_symbol("WiFiManagerClientCreate");
        void (*schedule)(void *, CFRunLoopRef, CFStringRef) =
            showcase_mobilewifi_symbol("WiFiManagerClientScheduleWithRunLoop");
        if (create) manager = create(kCFAllocatorDefault, 0);
        if (manager && schedule)
            schedule(manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    });
    return manager;
}

/* Returns the network that was left, or nil when none was joined. */
static NSString *showcase_hold_other_wifi(void) {
    void *manager = showcase_wifi_manager();
    CFArrayRef (*copyDevices)(void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientCopyDevices");
    void *(*copyCurrent)(void *) =
        showcase_mobilewifi_symbol("WiFiDeviceClientCopyCurrentNetwork");
    int (*disassociate)(void *) =
        showcase_mobilewifi_symbol("WiFiDeviceClientDisassociate");
    void (*disable)(void *, void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientDisableNetwork");
    CFStringRef (*ssidOf)(void *) =
        showcase_mobilewifi_symbol("WiFiNetworkGetSSID");
    if (!manager || !copyDevices || !copyCurrent || !disassociate ||
        !disable || !ssidOf) {
        ip_log("[RADIO] MobileWiFi unavailable; other Wi-Fi left joined");
        return nil;
    }
    CFArrayRef devices = copyDevices(manager);
    void *device = devices && CFArrayGetCount(devices) > 0
        ? (void *)CFArrayGetValueAtIndex(devices, 0) : NULL;
    void *network = device ? copyCurrent(device) : NULL;
    NSString *ssid = nil;
    if (network) {
        CFStringRef name = ssidOf(network);
        ssid = name ? [(__bridge NSString *)name copy] : nil;
        if (ssid.length) {
            [[NSUserDefaults standardUserDefaults] setObject:ssid
                                                      forKey:HELD_WIFI_NETWORK_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
            disable(manager, network);
            int rc = disassociate(device);
            ip_log("[RADIO] left '%s' for the session (disassociate rc=%d)",
                   ssid.UTF8String, rc);
        }
        CFRelease(network);
    } else {
        ip_log("[RADIO] no other Wi-Fi network joined");
    }
    if (devices) CFRelease(devices);
    return ssid;
}

static void showcase_release_other_wifi(const char *reason) {
    NSString *ssid = [[NSUserDefaults standardUserDefaults]
        stringForKey:HELD_WIFI_NETWORK_KEY];
    if (!ssid.length) return;
    void *manager = showcase_wifi_manager();
    CFArrayRef (*copyNetworks)(void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientCopyNetworks");
    void (*enable)(void *, void *) =
        showcase_mobilewifi_symbol("WiFiManagerClientEnableNetwork");
    CFStringRef (*ssidOf)(void *) =
        showcase_mobilewifi_symbol("WiFiNetworkGetSSID");
    BOOL restored = NO;
    if (manager && copyNetworks && enable && ssidOf) {
        CFArrayRef networks = copyNetworks(manager);
        for (CFIndex i = 0; networks && i < CFArrayGetCount(networks); i++) {
            void *network = (void *)CFArrayGetValueAtIndex(networks, i);
            CFStringRef name = ssidOf(network);
            if (name && [(__bridge NSString *)name isEqualToString:ssid]) {
                enable(manager, network);
                restored = YES;
            }
        }
        if (networks) CFRelease(networks);
    }
    ip_log("[RADIO] %s '%s' (%s)", restored ? "re-enabled" : "could not find",
           ssid.UTF8String, reason);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:HELD_WIFI_NETWORK_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/* ═══════════════════════════════════════════════════════════════
 * Anonymous usage
 *
 * Counts how many people use Showcase and on what. Each item below can be
 * turned off in Settings › Anonymous Usage, or all of it at once:
 *
 *   id         a random UUID made here, not derived from the device
 *   version    Showcase package version, for example 1.0~beta5-2
 *   package    rootful, rootless or taurine
 *   model      hardware model, for example iPad4,2
 *   ios        iOS version
 *   jailbreak  guessed from the jailbreak's marker file, or "unknown"
 *   language   Showcase's language
 *   country    asks the server to keep the country Cloudflare reports
 *
 * It is posted to https://aminerostane.com/api/ping (telemetry/worker.js)
 * when it differs from the last one sent, or after 30 days. The server keeps
 * one row per id and never stores IP addresses. Failures are ignored.
 * ═══════════════════════════════════════════════════════════════ */

/* Settings key and payload key for each item, in Settings order. */
static NSArray<NSArray<NSString *> *> *usage_items(void) {
    return @[@[@"anonymousUsageModel", @"model"], @[@"anonymousUsageIOS", @"ios"],
             @[@"anonymousUsageJailbreak", @"jailbreak"], @[@"anonymousUsageVersion", @"version"],
             @[@"anonymousUsagePackage", @"package"], @[@"anonymousUsageLanguage", @"language"],
             @[@"anonymousUsageCountry", @"country"]];
}

static NSString *usage_jailbreak(void) {
    const char *markers[][2] = {
        {"/var/jb/.installed_dopamine", "dopamine"}, {"/var/jb/.palecursus_strapped", "palera1n"},
        {"/.palecursus_strapped", "palera1n"}, {"/.installed_amethyst", "amethyst"},
        {"/.installed_taurine", "taurine"}, {"/.installed_odyssey", "odyssey"},
        {"/.installed_unc0ver", "unc0ver"}, {"/.bootstrapped_electra", "chimera"},
        {"/var/checkra1n.dmg", "checkra1n"}};
    for (size_t i = 0; i < sizeof markers / sizeof markers[0]; i++)
        if (access(markers[i][0], F_OK) == 0) return @(markers[i][1]);
    return @"unknown";
}

static NSDictionary *usage_values(void) {
#if defined(SHOWCASE_ROOTLESS)
    NSString *package = @"rootless";
#elif defined(SHOWCASE_TAURINE)
    NSString *package = @"taurine";
#else
    NSString *package = @"rootful";
#endif
    NSOperatingSystemVersion os = [NSProcessInfo processInfo].operatingSystemVersion;
    return @{@"model": hardware_machine_identifier(), @"jailbreak": usage_jailbreak(),
             @"ios": [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion,
                      (long)os.minorVersion, (long)os.patchVersion],
             @"version": @PACKAGE_VERSION, @"package": package,
             @"language": showcase_language(), @"country": @YES};
}

static void send_anonymous_usage(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:USAGE_KEY]) return;
    NSDictionary *values = usage_values();
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    for (NSArray *item in usage_items())
        if ([d boolForKey:item[0]]) payload[item[1]] = values[item[1]];
    NSMutableString *summary = [NSMutableString string];
    for (NSString *key in [payload.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [summary appendFormat:@"%@=%@;", key, payload[key]];
    NSDate *sent = [d objectForKey:USAGE_SENT_DATE_KEY];
    if ([summary isEqualToString:[d stringForKey:USAGE_SENT_KEY]] && [sent isKindOfClass:[NSDate class]] &&
        -sent.timeIntervalSinceNow < 30 * 24 * 3600) return;

    NSString *identifier = [d stringForKey:USAGE_ID_KEY];
    if (!identifier.length) {
        identifier = [NSUUID UUID].UUIDString.lowercaseString;
        [d setObject:identifier forKey:USAGE_ID_KEY];
    }
    payload[@"id"] = identifier;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://aminerostane.com/api/ping"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || ((NSHTTPURLResponse *)response).statusCode != 204) return;
            [d setObject:summary forKey:USAGE_SENT_KEY];
            [d setObject:[NSDate date] forKey:USAGE_SENT_DATE_KEY];
            [d synchronize];
        }] resume];
}

/* ═══════════════════════════════════════════════════════════════
 * Personal Hotspot control
 *
 * Showcase starts the hotspot itself instead of sending the user to Settings:
 * Mobile Internet Sharing state ON plus wifid's discovery flag is what the
 * Personal Hotspot screen does when it is open. The band is iOS's choice.
 * ═══════════════════════════════════════════════════════════════ */

static id showcase_mis_manager(void) {
    static id manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/"
               "WirelessModemSettings", RTLD_NOW);
        Class managerClass = NSClassFromString(@"MISManager");
        if (!managerClass) return;
        SEL shared = NSSelectorFromString(@"sharedManager");
        manager = [managerClass respondsToSelector:shared]
            ? ((id (*)(id, SEL))objc_msgSend)(managerClass, shared)
            : [[managerClass alloc] init];
    });
    return manager;
}

static int showcase_hotspot_state(void) {
    id manager = showcase_mis_manager();
    if (!manager) return -1;
    int state = -1, reason = -1;
    ((void (*)(id, SEL, int *, int *))objc_msgSend)(
        manager, NSSelectorFromString(@"getState:andReason:"), &state, &reason);
    return state;
}

static BOOL showcase_set_hotspot(BOOL on) {
    id manager = showcase_mis_manager();
    if (!manager) return NO;
    ((void (*)(id, SEL, int))objc_msgSend)(
        manager, NSSelectorFromString(@"setState:"),
        on ? MIS_STATE_ON : MIS_STATE_OFF);
    return YES;
}

static void showcase_set_hotspot_discovery(BOOL discoverable) {
    void (*setDiscovery)(void *, int) =
        showcase_mobilewifi_symbol("WiFiManagerClientSetMISDiscoveryState");
    void *manager = showcase_wifi_manager();
    if (setDiscovery && manager) setDiscovery(manager, discoverable ? 1 : 0);
}

static void showcase_set_wifi_power(BOOL on) {
    void (*setPower)(void *, int) =
        showcase_mobilewifi_symbol("WiFiManagerClientSetPower");
    void *manager = showcase_wifi_manager();
    if (setPower && manager) setPower(manager, on ? 1 : 0);
}

/* ═══════════════════════════════════════════════════════════════
 * Touch IPC
 * ═══════════════════════════════════════════════════════════════ */

static dispatch_queue_t touch_write_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_touch_write_queue = dispatch_queue_create(
            "com.rostane.showcase.touch-writer", DISPATCH_QUEUE_SERIAL);
    });
    return g_touch_write_queue;
}

static void send_ipc_payload(uint8_t type, const void *payload,
                             uint32_t payloadLength) {
    int fd = g_touch_fd;
    uint32_t epoch = g_touch_epoch;
    if (fd < 0) return;

    NSMutableData *message =
        [NSMutableData dataWithLength:(NSUInteger)payloadLength + 5];
    uint8_t *bytes = message.mutableBytes;
    bytes[0] = payloadLength & 0xff;
    bytes[1] = (payloadLength >> 8) & 0xff;
    bytes[2] = (payloadLength >> 16) & 0xff;
    bytes[3] = (payloadLength >> 24) & 0xff;
    bytes[4] = type;
    if (payloadLength) memcpy(bytes + 5, payload, payloadLength);

    dispatch_async(touch_write_queue(), ^{
        if (g_touch_fd != fd || g_touch_epoch != epoch) return;
        const uint8_t *cursor = message.bytes;
        size_t remaining = message.length;
        while (remaining > 0) {
            ssize_t written = write(fd, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                ip_log("IPC write failed type=0x%02x: %s",
                       type, strerror(errno));
                return;
            }
            cursor += written;
            remaining -= (size_t)written;
        }
    });
}

/* Each record keeps the UIKit sample time even though the current single
 * touch HID report has no timestamp field. Keeping it in IPC makes ordering
 * measurable and leaves the transport ready for a richer HID descriptor.
 * [phase][contact][x LE16][y LE16][timestampNs LE64] */
static void send_touch_records(NSData *records) {
    if (records.length == 0 || records.length > UINT32_MAX) return;
    send_ipc_payload(MSG_TOUCH, records.bytes, (uint32_t)records.length);
}

static void send_app_visibility(uint8_t visible) {
    uint8_t payload = visible ? 1 : 0;
    send_ipc_payload(MSG_APP_VISIBILITY, &payload, sizeof(payload));
}

static void send_video_resync_request(void) {
    uint8_t payload = 1;
    send_ipc_payload(MSG_VIDEO_RESYNC, &payload, sizeof(payload));
}

/* ═══════════════════════════════════════════════════════════════
 * AP detection
 * ═══════════════════════════════════════════════════════════════ */

static BOOL is_ap_up(void) {
    struct ifaddrs *ifa = NULL, *cur;
    if (getifaddrs(&ifa) != 0) return NO;
    BOOL up = NO;
    for (cur = ifa; cur != NULL; cur = cur->ifa_next) {
        if (cur->ifa_name && strcmp(cur->ifa_name, AP_INTERFACE) == 0
            && (cur->ifa_flags & IFF_UP)) { up = YES; break; }
    }
    freeifaddrs(ifa);
    return up;
}

/* ═══════════════════════════════════════════════════════════════
 * AWDL suppression during an active session
 *
 * AWDL is the radio Apple uses for AirDrop, Handoff and Continuity. It shares
 * the single Wi-Fi radio with the Personal Hotspot that carries CarPlay, and it
 * periodically pulls that radio onto its own social channels — 6 in the 2.4 GHz
 * band, which is where this receiver's low-latency interface was observed
 * sitting. While the radio is away, nothing is received, and the screen stream
 * arrives as a late burst afterwards. The published symptom of AWDL contention
 * is 50-200 ms stalls, which matches the residual lateness spikes measured here.
 *
 * This touches no part of pairing, iAP2, BAA or the RTSP negotiation. It is
 * applied only once a session is fully established and streaming, and undone
 * when the session ends, so the protocol phase is never affected. Bringing the
 * interface down costs AirDrop and Handoff for the duration — an acceptable
 * trade on a device dedicated to being a head unit.
 * ═══════════════════════════════════════════════════════════════ */

/* llw0 does not exist before iOS 13 — verified absent on the iOS 12 receiver
 * and present on the iOS 15 one — so every entry is probed, never assumed. */
static const char *const kAWDLInterfaces[] = { "awdl0", "llw0" };
#define AWDL_INTERFACE_COUNT (sizeof(kAWDLInterfaces) / sizeof(kAWDLInterfaces[0]))
#define AWDL_REASSERT_SECONDS  10.0

/* Only interfaces this code actually took down are brought back, so a receiver
 * where the user had already disabled AirDrop is left as it was found. */
static BOOL g_awdl_was_up[AWDL_INTERFACE_COUNT];

static BOOL interface_exists(const char *name) {
    return if_nametoindex(name) != 0;
}

/* Returns YES when the interface ended up in the requested state. */
static BOOL set_interface_up(const char *name, BOOL up) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;

    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);

    BOOL ok = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0) {
        short current = request.ifr_flags;
        short wanted = up ? (current | IFF_UP) : (current & (short)~IFF_UP);
        if (wanted == current) {
            ok = YES;
        } else {
            request.ifr_flags = wanted;
            ok = (ioctl(fd, SIOCSIFFLAGS, &request) == 0);
            if (!ok)
                ip_log("AWDL: %s %s failed: %s", name,
                       up ? "up" : "down", strerror(errno));
        }
    }
    close(fd);
    return ok;
}

static BOOL interface_is_up(const char *name) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);
    BOOL up = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0)
        up = (request.ifr_flags & IFF_UP) != 0;
    close(fd);
    return up;
}

/* iOS brings AWDL back on its own whenever a Continuity service wants it, so
 * the suppression is re-asserted on a slow timer rather than set once. */
static volatile int32_t g_awdl_suppressed = 0;

static void awdl_suppress(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        const char *name = kAWDLInterfaces[i];
        if (!interface_exists(name)) { g_awdl_was_up[i] = NO; continue; }
        if (!interface_is_up(name)) continue;   /* already down; leave it */
        g_awdl_was_up[i] = YES;
        if (set_interface_up(name, NO) && logEachInterface)
            ip_log("AWDL: %s -> down", name);
    }
}

static void awdl_restore(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        if (!g_awdl_was_up[i]) continue;
        const char *name = kAWDLInterfaces[i];
        g_awdl_was_up[i] = NO;
        if (!interface_exists(name) || interface_is_up(name)) continue;
        if (set_interface_up(name, YES) && logEachInterface)
            ip_log("AWDL: %s -> up", name);
    }
}

static const char *first_existing_tool(const char *const paths[]) {
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

static const char *tcpdump_tool_path(void) {
    const char *paths[] = {
        "/var/jb/usr/sbin/tcpdump",
        "/var/jb/usr/bin/tcpdump",
        "/usr/sbin/tcpdump",
        "/usr/bin/tcpdump",
        NULL
    };
    return first_existing_tool(paths);
}

static void enable_btstack_hci_logging(void) {
    mkdir("/var/mobile/Library", 0755);
    mkdir(BTSTACK_PREFS_DIR, 0755);
    const char *plist =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n"
        "<dict>\n"
        "    <key>Logging</key>\n"
        "    <true/>\n"
        "</dict>\n"
        "</plist>\n";
    int fd = open(BTSTACK_PREFS, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        ip_log("BTstack logging prefs write failed: %s", strerror(errno));
        return;
    }
    ssize_t want = (ssize_t)strlen(plist);
    ssize_t wrote = write(fd, plist, (size_t)want);
    close(fd);
    chmod(BTSTACK_PREFS, 0644);
    ip_log("BTstack HCI logging %s at %s",
           wrote == want ? "enabled" : "partially written", BTSTACK_PREFS);
}

static void disable_btstack_hci_logging(void) {
    unlink(BTSTACK_PREFS);
    ip_log("BTstack HCI logging disabled");
}

/* ═══════════════════════════════════════════════════════════════
 * Process spawn helpers
 * ═══════════════════════════════════════════════════════════════ */

static int run_blocking(const char *path, char *const argv[]) {
    pid_t pid;
    int status;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) {
        BOOL redacted = (i > 1 &&
            (!strcmp(argv[i - 1], "--pass") || !strcmp(argv[i - 1], "-p")));
        [cmdline appendFormat:@" %s", redacted ? "******" : argv[i]];
    }
    ip_log("run_blocking: %s (uid=%u euid=%u)", [cmdline UTF8String], getuid(), geteuid());

    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) { ip_log("  posix_spawn FAIL: %s", strerror(err)); return -1; }
    if (waitpid(pid, &status, 0) < 0) { ip_log("  waitpid FAIL: %s", strerror(errno)); return -1; }
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    ip_log("  exit=%d", rc);
    return rc;
}

static int run_capture(const char *path, char *const argv[], const char *outfile) {
    if (!path || access(path, X_OK) != 0) return -1;
    pid_t pid;
    int status;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, outfile, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) return -1;
    if (waitpid(pid, &status, 0) < 0) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static pid_t spawn_daemon(const char *path, char *const argv[], const char *logfile) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);

    if (access(path, X_OK) != 0) {
        ip_log("spawn_daemon: %s NOT EXECUTABLE (%s)", path, strerror(errno));
        return 0;
    }

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) [cmdline appendFormat:@" %s", argv[i]];
    ip_log("spawn_daemon: %s", [cmdline UTF8String]);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, logfile, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("  posix_spawn FAIL: %s", strerror(err));
        return 0;
    }
    ip_log("  pid=%d log=%s", pid, logfile);

    usleep(200000);
    if (kill(pid, 0) != 0) {
        ip_log("  CHILD ALREADY DEAD — check %s", logfile);
    } else {
        ip_log("  child still alive ✓");
    }
    return pid;
}

/* kill(pid, 0) succeeds for a zombie, so an exited helper looked alive until
 * kill_pid's two-second timeout and was never reaped: each session left a
 * zombie carplay_bt and carplay_services behind. Reap our own children here;
 * fall back to kill() only for processes that are not our children. */
static BOOL pid_alive(pid_t pid) {
    if (pid <= 0) return NO;
    int status = 0;
    pid_t reaped = waitpid(pid, &status, WNOHANG);
    if (reaped == pid) return NO;
    if (reaped < 0 && errno == ECHILD) return kill(pid, 0) == 0;
    return YES;
}

static BOOL wait_for_bt_ready_or_exit(pid_t pid, int seconds) {
    int loops = seconds * 10;
    for (int i = 0; i < loops; i++) {
        if (access(BT_READY_PATH, F_OK) == 0) {
            ip_log("[BT] ready sentinel observed at %s", BT_READY_PATH);
            return YES;
        }

        int status = 0;
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 62) {
                ip_log("[BT] helper exited with BTSTACK_EVENT_POWERON_FAILED (62)");
            } else if (WIFEXITED(status)) {
                ip_log("[BT] helper exited before ready sentinel exit=%d", WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                ip_log("[BT] helper exited before ready sentinel signal=%d", WTERMSIG(status));
            } else {
                ip_log("[BT] helper exited before ready sentinel status=0x%x", status);
            }
            return NO;
        }
        if (done < 0 && errno != EINTR) {
            if (errno == ECHILD && !pid_alive(pid)) {
                ip_log("[BT] helper vanished before ready sentinel");
                return NO;
            }
            ip_log("[BT] waitpid while waiting for ready sentinel failed: %s", strerror(errno));
        }
        usleep(100000);
    }

    ip_log("[BT] ready sentinel timeout after %d seconds path=%s", seconds, BT_READY_PATH);
    return NO;
}

static BOOL wait_for_pid_alive(pid_t pid, int seconds, const char *name) {
    for (int i = 0; i < seconds; i++) {
        if (!pid_alive(pid)) {
            ip_log("%s exited during startup wait at %d/%d sec", name, i, seconds);
            return NO;
        }
        sleep(1);
    }
    return YES;
}

/* Like wait_for_pid_alive, but done as soon as `ready` exists. */
static BOOL wait_for_pid_alive_until(pid_t pid, int seconds, const char *name, const char *ready) {
    for (int i = 0; i < seconds * 20; i++) {
        if (!pid_alive(pid)) {
            ip_log("%s exited during startup wait at %d/%d sec", name, i / 20, seconds);
            return NO;
        }
        if (access(ready, F_OK) == 0) return YES;
        usleep(50000);
    }
    return YES;
}

static BOOL wait_for_path(const char *path, int seconds, const char *name) {
    for (int i = 0; i < seconds * 10; i++) {
        if (access(path, F_OK) == 0) {
            ip_log("%s ready at %s", name, path);
            return YES;
        }
        usleep(100000);
    }
    ip_log("%s not ready at %s after %d sec", name, path, seconds);
    return NO;
}

static void kill_pid(pid_t pid) {
    if (!pid_alive(pid)) return;
    kill(pid, SIGTERM);
    for (int i = 0; i < 20; i++) {
        usleep(100000);
        if (!pid_alive(pid)) return;
    }
    kill(pid, SIGKILL);
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
}

static void signal_processes_named(const char *name, int sig, pid_t preservedPid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return;

    struct kinfo_proc *procs = malloc(len);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return;
    }

    pid_t self = getpid();
    int count = (int)(len / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        const char *comm = procs[i].kp_proc.p_comm;
        if (pid <= 0 || pid == self || pid == preservedPid) continue;
        if (strcmp(comm, name) != 0) continue;
        ip_log("reap stale helper: kill -%d %s pid=%d", sig, name, pid);
        kill(pid, sig);
    }
    free(procs);
}

static BOOL process_named_running(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        int count = (int)(len / sizeof(struct kinfo_proc));
        for (int i = 0; i < count && !found; i++)
            found = procs[i].kp_proc.p_pid > 0 && !strcmp(procs[i].kp_proc.p_comm, name);
    }
    free(procs);
    return found;
}

#if !defined(SHOWCASE_TAURINE) && !defined(SHOWCASE_ROOTLESS)
/* Taurine marks its install at the root and keeps jailbreakd in /taurine. */
static BOOL showcase_on_taurine(void) {
    return [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion == 14 &&
        (access("/.installed_taurine", F_OK) == 0 || access("/taurine", F_OK) == 0);
}
#endif

static void reap_stale_helpers(pid_t preservedPid) {
    const char *names[] = {
        "carplay_services",
        "carplay_bt",
        "CarDisplaySim",
        "CarPlay Simulator",
        "CarPlay Simulato",
        "BTdaemon"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGTERM, preservedPid);
    usleep(700000);
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGKILL, preservedPid);
    if (preservedPid <= 0)
        unlink(BAA_BROKER_PATH);
    unlink(SOCK_PATH);
#ifdef SHOWCASE_ROOTLESS
    unlink(BTSTACK_SOCKET);
#endif
}

/* ═══════════════════════════════════════════════════════════════
 * Data model + persistence
 *
 *   Car        = { name }                — display label CarPlay advertises
 *   APCreds    = { ssid, password }       — global, set once, used by all cars
 *
 * NSUserDefaults schema:
 *   "cars"            => NSArray of NSDictionary { name }
 *   "selectedCarName" => NSString
 *   "apSSID"          => NSString          (the iPad's hotspot SSID)
 *   "apPassword"      => NSString          (the iPad's hotspot password)
 *
 * On first run we seed one car ("Miata"). AP creds start empty;
 * the user must set them before Start CarPlay enables.
 *
 * Migration: if loaded cars carry legacy ssid/password fields and
 * apSSID is empty, promote the first non-empty pair to global creds.
 * ═══════════════════════════════════════════════════════════════ */

@interface Car : NSObject
@property (nonatomic, copy) NSString *name;
- (NSDictionary *)toDict;
+ (Car *)fromDict:(NSDictionary *)d;
@end

@implementation Car
- (NSDictionary *)toDict { return @{ @"name": self.name ?: @"" }; }
+ (Car *)fromDict:(NSDictionary *)d {
    Car *c = [[Car alloc] init];
    c.name = d[@"name"] ?: @"";
    return c;
}
@end

/* ─── Validation ───────────────────────────────────────────────
 * iOS 26 rejects auto-joining hotspots whose SSID:
 *  - is shorter than ~6 chars (default iPad name "iPad" doesn't work)
 *  - contains an Apple device name substring (iPad/iPhone/iPod/Mac)
 *
 * Returns nil if valid, otherwise human-readable error message.
 * ────────────────────────────────────────────────────────────── */
static NSString *validateSSID(NSString *ssid) {
    if (ssid.length == 0) return L(@"Wi-Fi network is required.");
    if (ssid.length < 6) {
        return L(@"Wi-Fi name must be at least 6 characters. iOS rejects shorter names for CarPlay.");
    }
    NSString *lower = [ssid lowercaseString];
    NSArray *forbidden = @[@"ipad", @"iphone", @"ipod"];
    for (NSString *bad in forbidden) {
        if ([lower rangeOfString:bad].location != NSNotFound) {
            return [NSString stringWithFormat:
                L(@"Wi-Fi name cannot contain \"%@\". Rename this %@ in Settings › General › About › Name."),
                bad, UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone"];
        }
    }
    return nil;
}

@interface CarStore : NSObject
@property (nonatomic, strong) NSMutableArray<Car *> *cars;
@property (nonatomic, strong) Car *selected;
@property (nonatomic, copy)   NSString *apSSID;
@property (nonatomic, copy)   NSString *apPassword;
- (void)load;
- (void)save;
- (void)addCar:(Car *)car;
- (void)deleteCarAtIndex:(NSInteger)idx;
- (void)selectCar:(Car *)car;
- (BOOL)apReady;
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw;
@end

@implementation CarStore
- (instancetype)init {
    if ((self = [super init])) [self load];
    return self;
}
- (BOOL)apReady {
    return self.apSSID.length > 0 && self.apPassword.length > 0
        && validateSSID(self.apSSID) == nil;
}
- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *raw = [d arrayForKey:@"cars"];
    self.cars = [NSMutableArray array];
    NSString *legacySSID = nil, *legacyPass = nil;
    for (NSDictionary *dict in raw) {
        Car *c = [Car fromDict:dict];
        [self.cars addObject:c];
        /* Migration: capture first non-empty embedded creds */
        if (!legacySSID) {
            NSString *s = dict[@"ssid"], *p = dict[@"password"];
            if (s.length > 0 && p.length > 0) { legacySSID = s; legacyPass = p; }
        }
    }
    if (self.cars.count == 0) {
        Car *miata = [[Car alloc] init];
        miata.name = @"Miata";
        [self.cars addObject:miata];
    }

    self.apSSID     = [d stringForKey:@"apSSID"]     ?: @"";
    self.apPassword = [d stringForKey:@"apPassword"] ?: @"";
    /* Promote legacy creds if global is empty */
    if (self.apSSID.length == 0 && legacySSID.length > 0) {
        self.apSSID = legacySSID;
        self.apPassword = legacyPass;
        ip_log("migrated legacy AP creds from car embedded fields");
    }

    NSString *selName = [d stringForKey:@"selectedCarName"];
    self.selected = nil;
    for (Car *c in self.cars) {
        if ([c.name isEqualToString:selName]) { self.selected = c; break; }
    }
    if (!self.selected) self.selected = self.cars.firstObject;

    [self save]; /* persist any migration */
}
- (void)save {
    NSMutableArray *raw = [NSMutableArray array];
    for (Car *c in self.cars) [raw addObject:[c toDict]];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:raw forKey:@"cars"];
    [d setObject:(self.selected.name ?: @"") forKey:@"selectedCarName"];
    [d setObject:(self.apSSID ?: @"")        forKey:@"apSSID"];
    [d setObject:(self.apPassword ?: @"")    forKey:@"apPassword"];
    [d synchronize];
}
- (void)addCar:(Car *)car {
    [self.cars addObject:car];
    if (!self.selected) self.selected = car;
    [self save];
}
- (void)deleteCarAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.cars.count) return;
    Car *c = self.cars[idx];
    [self.cars removeObjectAtIndex:idx];
    if (self.selected == c) self.selected = self.cars.firstObject;
    [self save];
}
- (void)selectCar:(Car *)car { self.selected = car; [self save]; }
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw {
    self.apSSID = ssid ?: @"";
    self.apPassword = pw ?: @"";
    [self save];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * VideoView — UIView backed by AVSampleBufferDisplayLayer
 * ═══════════════════════════════════════════════════════════════ */

@interface VideoView : UIView
@end

@implementation VideoView
+ (Class)layerClass { return [AVSampleBufferDisplayLayer class]; }
@end

/* ═══════════════════════════════════════════════════════════════
 * CarPlayAudioPlayer — one Audio Queue per negotiated CarPlay stream
 *
 * Wireless CarPlay supplies codec packets rather than an audio file.
 * Audio Queue accepts AAC/AAC-ELD/Opus packets directly and uses the system
 * codec, avoiding an extra PCM copy and keeping decoding off the IPC path.
 * ═══════════════════════════════════════════════════════════════ */

@interface CarPlayAudioPlayer : NSObject {
    AudioQueueRef _audioQueue;
    AudioConverterRef _audioConverter;
    uint32_t _streamType;
    uint64_t _formatMask;
    uint32_t _framesPerPacket;
    uint32_t _latencyMs;
    Float64 _sampleRate;
    UInt32 _channels;
    UInt32 _decodedBytesPerFrame;
    uint64_t _decodedPackets;
    NSUInteger _queuedPackets;
    NSUInteger _requiredStartPackets;
    volatile int32_t _outstandingBuffers;
    uint64_t _queueDrainCount;
    BOOL _started;
    BOOL _paused;
    BOOL _isPCM;
    BOOL _decodeAACToPCM;
    BOOL _haveSequence;
    uint16_t _lastSequence;
    uint64_t _lastRenderReportNanos;
}
- (instancetype)initWithStreamType:(uint32_t)streamType;
- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs;
- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence;
- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue;
- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue;
- (void)setPlaybackPaused:(BOOL)paused;
- (void)flushBufferedAudio;
- (void)stop;
@end

static void carplay_audio_queue_callback(void *userData, AudioQueueRef queue,
                                         AudioQueueBufferRef buffer) {
    CarPlayAudioPlayer *player =
        (__bridge CarPlayAudioPlayer *)userData;
    [player completedBuffer:buffer forQueue:queue];
}

typedef struct {
    const uint8_t *bytes;
    UInt32 length;
    UInt32 channels;
    BOOL consumed;
    AudioStreamPacketDescription packet;
} CarPlayAACInputContext;

static OSStatus carplay_aac_input_callback(
    AudioConverterRef converter,
    UInt32 *ioNumberDataPackets,
    AudioBufferList *ioData,
    AudioStreamPacketDescription **outPacketDescription,
    void *userData) {
    (void)converter;
    CarPlayAACInputContext *input =
        (CarPlayAACInputContext *)userData;
    if (!input || input->consumed || !input->bytes || input->length == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = input->channels;
    ioData->mBuffers[0].mDataByteSize = input->length;
    ioData->mBuffers[0].mData = (void *)input->bytes;
    input->packet.mStartOffset = 0;
    input->packet.mVariableFramesInPacket = 0;
    input->packet.mDataByteSize = input->length;
    if (outPacketDescription)
        *outPacketDescription = &input->packet;
    *ioNumberDataPackets = 1;
    input->consumed = YES;
    return noErr;
}

@implementation CarPlayAudioPlayer

- (instancetype)initWithStreamType:(uint32_t)streamType {
    if ((self = [super init])) _streamType = streamType;
    return self;
}

- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs {
    [self stop];

    Float64 sampleRate = 0;
    UInt32 channels = 0;
    AudioFormatID formatID = 0;
    uint32_t defaultFrames = 0;
    BOOL isPCM = NO;
    switch (formatMask) {
        case 0x00000004ULL: /* PCM 8 kHz, 16-bit mono */
            sampleRate = 8000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000010ULL: /* PCM 16 kHz, 16-bit mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000040ULL: /* PCM 24 kHz, 16-bit mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000800ULL: /* PCM 44.1 kHz, 16-bit stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00008000ULL: /* PCM 48 kHz, 16-bit stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00400000ULL: /* AAC-LC 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x00800000ULL: /* AAC-LC 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x01000000ULL: /* AAC-ELD 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x02000000ULL: /* AAC-ELD 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x04000000ULL: /* AAC-ELD 16 kHz mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x08000000ULL: /* AAC-ELD 24 kHz mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x10000000ULL: /* Opus 16 kHz mono, 20 ms */
            sampleRate = 16000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 320; break;
        case 0x20000000ULL: /* Opus 24 kHz mono, 20 ms */
            sampleRate = 24000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 480; break;
        case 0x40000000ULL: /* Opus 48 kHz mono, 20 ms */
            sampleRate = 48000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 960; break;
        default:
            ip_log("audio stream %u unsupported format=0x%llx",
                   _streamType, (unsigned long long)formatMask);
            return NO;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:0 error:&sessionError];
    if (!sessionError) [session setActive:YES error:&sessionError];
    if (sessionError) {
        ip_log("audio session activation failed: %s",
               sessionError.localizedDescription.UTF8String);
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = formatID;
    asbd.mChannelsPerFrame = channels;
    if (isPCM) {
        /* AirPlay PCM is signed, packed, 16-bit network byte order. */
        asbd.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked |
            kLinearPCMFormatFlagIsBigEndian;
        asbd.mBitsPerChannel = 16;
        asbd.mBytesPerFrame = channels * 2;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    } else {
        asbd.mFramesPerPacket =
            framesPerPacket > 0 ? framesPerPacket : defaultFrames;
    }

    /*
     * MainHighAudio (type 102) is a one-second-latency UDP media stream.
     * Apple's receiver decodes its AAC access units to PCM before handing
     * them to the platform audio device. Keep MainBuffered type 103 on the
     * proven direct AudioQueue path, but mirror Apple's decode boundary for
     * type 102. The PCM meter then distinguishes encoded-data problems from
     * output routing problems in the same run.
     */
    AudioStreamBasicDescription queueASBD = asbd;
    _decodeAACToPCM =
        _streamType == 102 &&
        (formatMask == 0x00400000ULL ||
         formatMask == 0x00800000ULL);
    if (_decodeAACToPCM) {
        memset(&queueASBD, 0, sizeof(queueASBD));
        queueASBD.mSampleRate = sampleRate;
        queueASBD.mFormatID = kAudioFormatLinearPCM;
        queueASBD.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked;
        queueASBD.mChannelsPerFrame = channels;
        queueASBD.mBitsPerChannel = 16;
        queueASBD.mBytesPerFrame = channels * 2;
        queueASBD.mFramesPerPacket = 1;
        queueASBD.mBytesPerPacket = queueASBD.mBytesPerFrame;
        OSStatus converterStatus =
            AudioConverterNew(&asbd, &queueASBD, &_audioConverter);
        if (converterStatus != noErr || !_audioConverter) {
            ip_log("audio stream %u AAC converter create failed status=%d",
                   _streamType, (int)converterStatus);
            _audioConverter = NULL;
            return NO;
        }
    }

    OSStatus status = AudioQueueNewOutput(
        &queueASBD, carplay_audio_queue_callback, (__bridge void *)self,
        NULL, NULL, 0,
        &_audioQueue);
    if (status != noErr || !_audioQueue) {
        ip_log("audio stream %u queue create failed status=%d",
               _streamType, (int)status);
        _audioQueue = NULL;
        if (_audioConverter) {
            AudioConverterDispose(_audioConverter);
            _audioConverter = NULL;
        }
        return NO;
    }
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, 1.0f);
    _formatMask = formatMask;
    _framesPerPacket = asbd.mFramesPerPacket;
    _latencyMs = latencyMs;
    _sampleRate = sampleRate;
    _channels = channels;
    _decodedBytesPerFrame = queueASBD.mBytesPerFrame;
    _decodedPackets = 0;
    _isPCM = isPCM || _decodeAACToPCM;
    _queuedPackets = 0;
    /*
     * MainHighAudio is a jitter-buffered media stream. The sender asked for
     * one second of latency in every observed Spotify SETUP, but starting
     * after the old six-packet floor left only 139 ms at 44.1 kHz. Video
     * bursts on the shared IPC path routinely exceed that and drained the
     * queue. Other stream types retain the proven six-packet start.
     */
    _requiredStartPackets = 6;
    if (_streamType == 102 && latencyMs > 0 &&
        sampleRate > 0 && _framesPerPacket > 0) {
        double requestedPackets =
            ((double)latencyMs * sampleRate) /
            (1000.0 * (double)_framesPerPacket);
        _requiredStartPackets =
            MAX((NSUInteger)6, (NSUInteger)ceil(requestedPackets));
    }
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    ip_log("audio stream %u configured format=0x%llx %.0fHz/%uch "
           "framesPerPacket=%u latency=%ums startPackets=%lu output=%s",
           _streamType, (unsigned long long)_formatMask, sampleRate,
           (unsigned)channels, _framesPerPacket, _latencyMs,
           (unsigned long)_requiredStartPackets,
           _decodeAACToPCM ? "decoded-pcm" : "direct");
    return YES;
}

- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence {
    if (!_audioQueue || !bytes || length == 0) return;
    if (_haveSequence && sequence != (uint16_t)(_lastSequence + 1)) {
        ip_log("audio stream %u RTP gap expected=%u got=%u",
               _streamType, (uint16_t)(_lastSequence + 1), sequence);
    }
    _lastSequence = sequence;
    _haveSequence = YES;

    UInt32 queueLength = _decodeAACToPCM
        ? _framesPerPacket * _decodedBytesPerFrame : length;
    AudioQueueBufferRef buffer = NULL;
    OSStatus status =
        AudioQueueAllocateBuffer(_audioQueue, queueLength, &buffer);
    if (status != noErr || !buffer) {
        ip_log("audio stream %u buffer allocation failed status=%d",
               _streamType, (int)status);
        return;
    }

    if (_decodeAACToPCM) {
        CarPlayAACInputContext input = {
            .bytes = bytes,
            .length = length,
            .channels = _channels,
            .consumed = NO
        };
        AudioBufferList output;
        memset(&output, 0, sizeof(output));
        output.mNumberBuffers = 1;
        output.mBuffers[0].mNumberChannels = _channels;
        output.mBuffers[0].mDataByteSize = queueLength;
        output.mBuffers[0].mData = buffer->mAudioData;
        UInt32 outputPackets = _framesPerPacket;
        status = AudioConverterFillComplexBuffer(
            _audioConverter, carplay_aac_input_callback, &input,
            &outputPackets, &output, NULL);
        if (status != noErr || output.mBuffers[0].mDataByteSize == 0) {
            AudioQueueFreeBuffer(_audioQueue, buffer);
            ip_log("audio stream %u AAC decode failed status=%d bytes=%u",
                   _streamType, (int)status, length);
            return;
        }
        buffer->mAudioDataByteSize =
            output.mBuffers[0].mDataByteSize;
        _decodedPackets++;
        if (_decodedPackets <= 3 || (_decodedPackets % 250) == 0) {
            const int16_t *samples =
                (const int16_t *)buffer->mAudioData;
            size_t sampleCount =
                buffer->mAudioDataByteSize / sizeof(int16_t);
            double squareSum = 0.0;
            for (size_t index = 0; index < sampleCount; index++) {
                double value = (double)samples[index] / 32768.0;
                squareSum += value * value;
            }
            double rms = sampleCount > 0
                ? sqrt(squareSum / (double)sampleCount) : 0.0;
            ip_log("audio stream %u decoded #%llu in=%u out=%u "
                   "frames=%u rms=%.6f",
                   _streamType,
                   (unsigned long long)_decodedPackets,
                   length, buffer->mAudioDataByteSize,
                   outputPackets, rms);
        }
    } else {
        memcpy(buffer->mAudioData, bytes, length);
        buffer->mAudioDataByteSize = length;
    }
    if (_isPCM) {
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    } else {
        AudioStreamPacketDescription packet = {
            .mStartOffset = 0,
            .mVariableFramesInPacket = _framesPerPacket,
            .mDataByteSize = length
        };
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 1, &packet);
    }
    if (status != noErr) {
        AudioQueueFreeBuffer(_audioQueue, buffer);
        ip_log("audio stream %u enqueue failed status=%d",
               _streamType, (int)status);
        return;
    }

    int32_t outstanding =
        __sync_add_and_fetch(&_outstandingBuffers, 1);
    _queuedPackets++;
    if (!_started && !_paused &&
        outstanding >= (int32_t)_requiredStartPackets) {
        UInt32 preparedFrames = 0;
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
        if (_started) _paused = NO;
        ip_log("audio stream %u playback start status=%d primed=%u "
               "buffered=%d/%lu",
               _streamType, (int)status, preparedFrames, outstanding,
               (unsigned long)_requiredStartPackets);
    }
    if ((_queuedPackets % 500) == 0) {
        ip_log("audio stream %u live packets=%lu",
               _streamType, (unsigned long)_queuedPackets);
    }
}

- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue {
    [self reportPlaybackTimeForQueue:queue];
    int32_t outstanding =
        __sync_sub_and_fetch(&_outstandingBuffers, 1);
    if (_started && !_paused && outstanding == 0) {
        _queueDrainCount++;
        ip_log("audio stream %u queue drained #%llu packets=%lu",
               _streamType, (unsigned long long)_queueDrainCount,
               (unsigned long)_queuedPackets);
    }
    AudioQueueFreeBuffer(queue, buffer);
}

- (void)setPlaybackPaused:(BOOL)paused {
    if (!_audioQueue) return;

    if (paused) {
        _paused = YES;
        OSStatus status = _started
            ? AudioQueuePause(_audioQueue) : noErr;
        ip_log("audio stream %u pause status=%d started=%d queued=%lu",
               _streamType, (int)status, (int)_started,
               (unsigned long)_queuedPackets);
        return;
    }

    _paused = NO;
    OSStatus status = noErr;
    UInt32 preparedFrames = 0;
    if (_started) {
        status = AudioQueueStart(_audioQueue, NULL);
    } else if (_outstandingBuffers >= (int32_t)_requiredStartPackets) {
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
    }
    ip_log("audio stream %u resume status=%d started=%d queued=%lu primed=%u",
           _streamType, (int)status, (int)_started,
           (unsigned long)_queuedPackets, preparedFrames);
}

- (void)flushBufferedAudio {
    if (!_audioQueue) return;

    /*
     * AudioQueueFlush drains already-enqueued buffers, which is the opposite
     * of AirPlay's FLUSHBUFFERED transition. Reset returns those buffers
     * immediately and preserves the queue's negotiated format. Keep the
     * paused state established by SETRATEANCHORTIME rate=0; the new RTP epoch
     * will not start until the following rate=1 command.
     */
    BOOL wasPaused = _paused;
    _started = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    OSStatus status = AudioQueueReset(_audioQueue);
    _outstandingBuffers = 0;
    if (_audioConverter) AudioConverterReset(_audioConverter);
    _paused = wasPaused;
    ip_log("audio stream %u buffered flush status=%d paused=%d",
           _streamType, (int)status, (int)_paused);
}

- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue {
    if (!queue || queue != _audioQueue || !_started) return;

    uint64_t nowNanos = monotonic_nanos_now();
    if (_lastRenderReportNanos != 0 &&
        nowNanos - _lastRenderReportNanos < 250 * NSEC_PER_MSEC) {
        return;
    }

    AudioTimeStamp audioTime;
    memset(&audioTime, 0, sizeof(audioTime));
    Boolean discontinuity = false;
    OSStatus status = AudioQueueGetCurrentTime(
        queue, NULL, &audioTime, &discontinuity);
    if (status != noErr ||
        !(audioTime.mFlags & kAudioTimeStampSampleTimeValid)) {
        return;
    }

    int64_t sampleTime = (int64_t)llround(audioTime.mSampleTime);
    uint64_t hostTicks =
        (audioTime.mFlags & kAudioTimeStampHostTimeValid)
            ? audioTime.mHostTime : mach_absolute_time();
    uint8_t payload[20] = {0};
    memcpy(payload, &_streamType, 4);
    memcpy(payload + 4, &sampleTime, 8);
    memcpy(payload + 12, &hostTicks, 8);
    send_ipc_payload(MSG_AUDIO_RENDER, payload, sizeof(payload));
    _lastRenderReportNanos = nowNanos;

    if (discontinuity) {
        ip_log("audio stream %u render clock discontinuity sample=%lld",
               _streamType, (long long)sampleTime);
    }
}

- (void)stop {
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    _decodeAACToPCM = NO;
    _decodedPackets = 0;
    _sampleRate = 0;
    _latencyMs = 0;
    _requiredStartPackets = 6;
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
}

- (void)dealloc {
    [self stop];
}
@end

/* Full-screen pause-menu scrim. It consumes ordinary touches so CarPlay
 * receives no input until another three-finger tap dismisses it. */
@interface ControlsOverlayView : UIView
@end
@implementation ControlsOverlayView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
@end

/* A bounded, scrollable compatibility report. Bluetooth failures used to
 * return the state machine to Idle with no user-visible explanation; a long
 * raw daemon log also does not belong in a UIAlertController message. */
@interface CompatibilityErrorViewController : UIViewController
@property (nonatomic, copy) NSString *errorTitle;
@property (nonatomic, copy) NSString *explanation;
@property (nonatomic, copy) NSString *diagnostic;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *explanationLabel;
@property (nonatomic, strong) UITextView *diagnosticView;
@property (nonatomic, strong) UIButton *diagnosticCopyButton;
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation CompatibilityErrorViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    self.view = root;

    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.masksToBounds = YES;
    [root addSubview:self.panel];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font =
        [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.titleLabel];

    self.explanationLabel = [[UILabel alloc] init];
    self.explanationLabel.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.explanationLabel.font = [UIFont systemFontOfSize:14];
    self.explanationLabel.numberOfLines = 3;
    self.explanationLabel.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.explanationLabel];

    self.diagnosticView = [[UITextView alloc] init];
    self.diagnosticView.editable = NO;
    self.diagnosticView.selectable = YES;
    self.diagnosticView.alwaysBounceVertical = YES;
    self.diagnosticView.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.38];
    self.diagnosticView.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.88];
    self.diagnosticView.font =
        [UIFont fontWithName:@"Menlo-Regular" size:11] ?:
            [UIFont systemFontOfSize:11];
    self.diagnosticView.layer.cornerRadius = 8;
    self.diagnosticView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.panel addSubview:self.diagnosticView];

    self.diagnosticCopyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.diagnosticCopyButton.backgroundColor = [UIColor whiteColor];
    [self.diagnosticCopyButton setTitleColor:[UIColor blackColor]
                                    forState:UIControlStateNormal];
    [self.diagnosticCopyButton setTitle:L(@"Copy Diagnostic")
                               forState:UIControlStateNormal];
    self.diagnosticCopyButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.diagnosticCopyButton.layer.cornerRadius = 9;
    [self.diagnosticCopyButton addTarget:self action:@selector(copyDiagnostic)
                        forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.diagnosticCopyButton];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    [self.closeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    [self.closeButton setTitle:L(@"Close") forState:UIControlStateNormal];
    self.closeButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.closeButton.layer.cornerRadius = 9;
    [self.closeButton addTarget:self action:@selector(close)
               forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.closeButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.titleLabel.text = self.errorTitle;
    self.explanationLabel.text = self.explanation;
    self.diagnosticView.text = self.diagnostic;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat panelWidth = MIN(size.width - 32.0, 720.0);
    CGFloat panelHeight = MIN(size.height - 24.0, 520.0);
    self.panel.frame = CGRectMake((size.width - panelWidth) / 2.0,
                                  (size.height - panelHeight) / 2.0,
                                  panelWidth, panelHeight);
    CGFloat inset = 18.0;
    self.titleLabel.frame = CGRectMake(inset, 14, panelWidth - inset * 2, 32);
    self.explanationLabel.frame =
        CGRectMake(inset, 48, panelWidth - inset * 2, 58);
    CGFloat buttonsY = panelHeight - 56;
    self.diagnosticView.frame =
        CGRectMake(inset, 112, panelWidth - inset * 2,
                   MAX(56, buttonsY - 122));
    CGFloat gap = 12;
    CGFloat buttonWidth = (panelWidth - inset * 2 - gap) / 2.0;
    self.diagnosticCopyButton.frame =
        CGRectMake(inset, buttonsY, buttonWidth, 40);
    self.closeButton.frame =
        CGRectMake(inset + buttonWidth + gap, buttonsY, buttonWidth, 40);
}

- (void)copyDiagnostic {
    [UIPasteboard generalPasteboard].string = self.diagnostic ?: @"";
    [self.diagnosticCopyButton setTitle:L(@"Copied")
                               forState:UIControlStateNormal];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

/* The interface-orientation names describe the content rotation, not the
 * physical device rotation. LandscapeLeft therefore places the top edge
 * (and a notch or Dynamic Island) on the right side of the display. Long
 * phone panels are used as the hardware signal so this remains independent
 * of model identifier, OS version, and jailbreak layout. */
static BOOL showcase_phone_has_landscape_cutout(void) {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPhone) return NO;
    CGSize pixels = [UIScreen mainScreen].nativeBounds.size;
    CGFloat shortEdge = MIN(pixels.width, pixels.height);
    CGFloat longEdge = MAX(pixels.width, pixels.height);
    return shortEdge > 0.0 && (longEdge / shortEdge) > 2.0;
}

/* "iPad" or "iPhone", for text that names the device running Showcase. */
static NSString *showcase_device_noun(void) {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
}

static UIInterfaceOrientationMask showcase_orientation_mask(void) {
    return showcase_phone_has_landscape_cutout()
        ? UIInterfaceOrientationMaskLandscapeLeft
        : UIInterfaceOrientationMaskLandscape;
}

static UIInterfaceOrientation showcase_preferred_orientation(void) {
    return UIInterfaceOrientationLandscapeLeft;
}

static UIImage *showcase_star_image(CGFloat side);

/* Asks for a GitHub star: the link, Copy Link and Open GitHub. Tapping
 * outside the panel closes it. */
@interface StarViewController : UIViewController
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *linkButton;
@end

@implementation StarViewController

- (UIButton *)button:(NSString *)title filled:(BOOL)filled action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = filled ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.13];
    [button setTitleColor:filled ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.layer.cornerRadius = 10;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:button];
    return button;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    [root addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    self.view = root;

    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.panel.layer.cornerRadius = 16;
    /* Taps on the panel itself must not close it. */
    [self.panel addGestureRecognizer:[[UITapGestureRecognizer alloc] init]];
    [root addSubview:self.panel];

    UIImageView *star = [[UIImageView alloc] initWithImage:showcase_star_image(30)];
    star.tintColor = [UIColor whiteColor];
    star.tag = 1;
    [self.panel addSubview:star];

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"Give us a star on GitHub!");
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.7;
    title.tag = 2;
    [self.panel addSubview:title];

    UILabel *link = [[UILabel alloc] init];
    link.text = [GITHUB_URL stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    link.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    link.font = [UIFont systemFontOfSize:16];
    link.textAlignment = NSTextAlignmentCenter;
    link.adjustsFontSizeToFitWidth = YES;
    link.tag = 3;
    [self.panel addSubview:link];

    self.linkButton = [self button:L(@"Copy Link") filled:NO action:@selector(copyLink)];
    [self button:L(@"Open GitHub") filled:YES action:@selector(openGitHub)].tag = 4;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat w = MIN(size.width - 32, 420), h = 236, inset = 20;
    self.panel.frame = CGRectMake((size.width - w) / 2, (size.height - h) / 2, w, h);
    [self.panel viewWithTag:1].frame = CGRectMake((w - 30) / 2, 22, 30, 30);
    [self.panel viewWithTag:2].frame = CGRectMake(inset, 64, w - inset * 2, 30);
    [self.panel viewWithTag:3].frame = CGRectMake(inset, 100, w - inset * 2, 24);
    CGFloat buttonW = (w - inset * 2 - 12) / 2;
    self.linkButton.frame = CGRectMake(inset, h - 70, buttonW, 48);
    [self.panel viewWithTag:4].frame = CGRectMake(inset + buttonW + 12, h - 70, buttonW, 48);
}

- (void)copyLink {
    [UIPasteboard generalPasteboard].string = GITHUB_URL;
    [self.linkButton setTitle:L(@"Copied") forState:UIControlStateNormal];
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:GITHUB_URL] options:@{} completionHandler:nil];
    [self close];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * RootViewController — landscape-only touch routing
 * ═══════════════════════════════════════════════════════════════ */

@class AppDelegate;

@interface RootViewController : UIViewController
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, weak) VideoView *videoView;
@property (nonatomic, weak) AppDelegate *appDelegate;
@property (nonatomic, assign) BOOL fullscreenMode; /* iPhone Active bypass of the 1024x768 canvas */
@end

@implementation RootViewController
- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    if (self.fullscreenMode) {
        /* iPhone Active: drop the 1024x768 canvas; let video fill the screen. */
        self.contentView.transform = CGAffineTransformIdentity;
        self.contentView.bounds = self.view.bounds;
        self.contentView.center = CGPointMake(self.view.bounds.size.width / 2.0,
                                              self.view.bounds.size.height / 2.0);
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}

- (BOOL)mapTouch:(UITouch *)touch toX:(uint16_t *)outX y:(uint16_t *)outY {
    if (g_carplay_w <= 0 || g_carplay_h <= 0) return NO;
    CGPoint pt = [touch locationInView:self.videoView];
    CGSize vs = self.videoView.bounds.size;
    float vw = vs.width, vh = vs.height;
    float cw = g_carplay_w, ch = g_carplay_h;
    float va = cw / ch, vva = vw / vh;
    float rw, rh, rx, ry;
    if (va > vva) { rw = vw; rh = vw / va; rx = 0; ry = (vh - rh) / 2.0f; }
    else          { rh = vh; rw = vh * va; rx = (vw - rw) / 2.0f; ry = 0; }
    float nx = (pt.x - rx) / rw, ny = (pt.y - ry) / rh;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return NO;
    *outX = (uint16_t)(nx * cw);
    *outY = (uint16_t)(ny * ch);
    return YES;
}
- (void)handleTouches:(NSSet<UITouch *> *)touches
                event:(UIEvent *)event
                phase:(uint8_t)phase {
    NSMutableData *records = [NSMutableData data];
    for (UITouch *touch in touches) {
        NSArray<UITouch *> *samples = nil;
        if (phase == TOUCH_MOVE) {
            samples = [event coalescedTouchesForTouch:touch];
        }
        if (samples.count == 0) samples = @[touch];

        uint8_t contact = (uint8_t)(touch.hash & 0xff);
        for (UITouch *sample in samples) {
            uint16_t x = 0, y = 0;
            if (![self mapTouch:sample toX:&x y:&y]) continue;
            uint64_t timestampNs =
                (uint64_t)llround(sample.timestamp * (double)NSEC_PER_SEC);
            uint8_t record[14] = { phase, contact };
            record[2] = x & 0xff;
            record[3] = x >> 8;
            record[4] = y & 0xff;
            record[5] = y >> 8;
            memcpy(record + 6, &timestampNs, sizeof(timestampNs));
            [records appendBytes:record length:sizeof(record)];
        }
    }
    send_touch_records(records);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_DOWN];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_MOVE];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_UP];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_CANCEL];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * Shared drawing: settings glyph and connection progress
 * ═══════════════════════════════════════════════════════════════ */

/* SF Symbols do not exist on iOS 12, so the gear is drawn once as a
 * template image: a toothed ring with a round hole, tinted by the button. */
static UIImage *showcase_gear_image(CGFloat side) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(side / 2.0, side / 2.0);
    CGFloat outer = side * 0.48, body = side * 0.36, hole = side * 0.15;
    const int teeth = 8;
    UIBezierPath *gear = [UIBezierPath bezierPath];
    for (int i = 0; i < teeth; i++) {
        double mid = (2.0 * M_PI * i) / teeth;
        double half = M_PI / teeth * 0.46;
        double inHalf = M_PI / teeth * 0.62;
        CGPoint a = CGPointMake(c.x + body * cos(mid - inHalf), c.y + body * sin(mid - inHalf));
        CGPoint b = CGPointMake(c.x + outer * cos(mid - half), c.y + outer * sin(mid - half));
        CGPoint d = CGPointMake(c.x + outer * cos(mid + half), c.y + outer * sin(mid + half));
        CGPoint e = CGPointMake(c.x + body * cos(mid + inHalf), c.y + body * sin(mid + inHalf));
        if (i == 0) [gear moveToPoint:a]; else [gear addLineToPoint:a];
        [gear addLineToPoint:b];
        [gear addLineToPoint:d];
        [gear addLineToPoint:e];
        double next = (2.0 * M_PI * (i + 1)) / teeth;
        [gear addArcWithCenter:c radius:body startAngle:mid + inHalf
                    endAngle:next - inHalf clockwise:YES];
    }
    [gear closePath];
    [gear appendPath:[UIBezierPath bezierPathWithArcCenter:c radius:hole
        startAngle:0 endAngle:2.0 * M_PI clockwise:NO]];
    gear.usesEvenOddFillRule = YES;
    [[UIColor whiteColor] setFill];
    [gear fill];
    (void)ctx;
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

/* A five-pointed star, drawn like the gear as a template image. */
static UIImage *showcase_star_image(CGFloat side) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGPoint c = CGPointMake(side / 2.0, side * 0.53);
    CGFloat outer = side * 0.48, inner = outer * 0.42;
    UIBezierPath *star = [UIBezierPath bezierPath];
    for (int i = 0; i < 10; i++) {
        CGFloat r = i % 2 ? inner : outer;
        double angle = -M_PI_2 + i * M_PI / 5.0;
        CGPoint p = CGPointMake(c.x + r * cos(angle), c.y + r * sin(angle));
        if (i == 0) [star moveToPoint:p]; else [star addLineToPoint:p];
    }
    [star closePath];
    star.lineJoinStyle = kCGLineJoinRound;
    star.lineWidth = side * 0.06;
    [[UIColor whiteColor] set];
    [star fill];
    [star stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIView *showcase_check_badge(CGFloat side, UIColor *fill, UIColor *mark) {
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    badge.backgroundColor = fill;
    badge.layer.cornerRadius = side / 2.0;
    badge.userInteractionEnabled = NO;
    CAShapeLayer *check = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(side * 0.28, side * 0.52)];
    [path addLineToPoint:CGPointMake(side * 0.44, side * 0.67)];
    [path addLineToPoint:CGPointMake(side * 0.73, side * 0.35)];
    check.path = path.CGPath;
    check.strokeColor = mark.CGColor;
    check.fillColor = [UIColor clearColor].CGColor;
    check.lineWidth = MAX(1.5, side * 0.11);
    check.lineCap = kCALineCapRound;
    check.lineJoin = kCALineJoinRound;
    [badge.layer addSublayer:check];
    return badge;
}

typedef NS_ENUM(NSInteger, ConnectStep) {
    ConnectStepBluetooth = 0,
    ConnectStepServices,
    ConnectStepPhoneBluetooth,
    ConnectStepVerify,
    ConnectStepHotspotDetails,
    ConnectStepJoinWiFi,
    ConnectStepPairing,
    ConnectStepSession,
    ConnectStepVideo,
    ConnectStepCount
};

/* A vertical checklist of the connection milestones. Completed steps carry a
 * check, the step in progress a spinner, later steps a quiet dot. When the
 * screen is short it shows a segmented bar with the previous, current, and
 * next step instead of the full list. */
@interface ConnectStepsView : UIView
@property (nonatomic, copy) NSArray<NSString *> *pendingTitles;
@property (nonatomic, copy) NSArray<NSString *> *doneTitles;
@property (nonatomic, assign) NSInteger completed;   /* highest finished index */
@property (nonatomic, assign) BOOL compact;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)reload;
@end

@implementation ConnectStepsView

- (CGFloat)rowHeight { return self.compact ? 24.0 : 30.0; }

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    if (self.compact) return 14.0 + 3.0 * [self rowHeight];
    return (CGFloat)self.pendingTitles.count * [self rowHeight];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self reload];
}

- (UIView *)indicatorForState:(int)state size:(CGFloat)size {
    if (state == 2) {
        return showcase_check_badge(size, [UIColor whiteColor], [UIColor blackColor]);
    }
    if (state == 1) {
        UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spin.transform = CGAffineTransformMakeScale(0.8, 0.8);
        [spin startAnimating];
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        spin.center = CGPointMake(size / 2.0, size / 2.0);
        [holder addSubview:spin];
        return holder;
    }
    UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6, 6)];
    dot.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    dot.layer.cornerRadius = 3;
    dot.center = CGPointMake(size / 2.0, size / 2.0);
    [holder addSubview:dot];
    return holder;
}

- (void)addRowForIndex:(NSInteger)index y:(CGFloat)y width:(CGFloat)width
             leftInset:(CGFloat)left {
    NSInteger count = (NSInteger)self.pendingTitles.count;
    if (index < 0 || index >= count) return;
    int state = index <= self.completed ? 2
              : (index == self.completed + 1 ? 1 : 0);
    CGFloat rowH = [self rowHeight];
    CGFloat size = self.compact ? 16.0 : 18.0;
    UIView *indicator = [self indicatorForState:state size:size];
    indicator.frame = CGRectMake(left, y + (rowH - size) / 2.0, size, size);
    [self addSubview:indicator];

    UILabel *label = [[UILabel alloc] initWithFrame:
        CGRectMake(left + size + 12, y, width - left - size - 12, rowH)];
    label.text = state == 2 ? self.doneTitles[index] : self.pendingTitles[index];
    label.font = [UIFont systemFontOfSize:(self.compact ? 14 : 16)
                                   weight:(state == 1 ? UIFontWeightMedium
                                                      : UIFontWeightRegular)];
    label.textColor = [UIColor colorWithWhite:1
        alpha:(state == 1 ? 1.0 : (state == 2 ? 0.6 : 0.3))];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [self addSubview:label];
}

- (void)reload {
    for (UIView *v in [self.subviews copy]) [v removeFromSuperview];
    NSInteger count = (NSInteger)self.pendingTitles.count;
    if (count == 0) return;
    CGFloat W = self.bounds.size.width;
    CGFloat rowH = [self rowHeight];

    if (!self.compact) {
        /* Center a fixed-width column so labels line up under each other. */
        CGFloat column = MIN(W, 360.0);
        CGFloat left = (W - column) / 2.0;
        for (NSInteger i = 0; i < count; i++)
            [self addRowForIndex:i y:i * rowH width:left + column leftInset:left];
        return;
    }

    CGFloat column = MIN(W, 320.0);
    CGFloat left = (W - column) / 2.0;
    CGFloat gap = 4.0;
    CGFloat segment = (column - gap * (count - 1)) / count;
    for (NSInteger i = 0; i < count; i++) {
        UIView *bar = [[UIView alloc] initWithFrame:
            CGRectMake(left + i * (segment + gap), 0, segment, 4)];
        bar.layer.cornerRadius = 2;
        bar.backgroundColor = [UIColor colorWithWhite:1
            alpha:(i <= self.completed ? 0.9
                   : (i == self.completed + 1 ? 0.45 : 0.15))];
        [self addSubview:bar];
    }
    NSInteger current = MIN(self.completed + 1, count - 1);
    NSInteger first = MAX(0, MIN(current - 1, count - 3));
    for (NSInteger i = 0; i < 3; i++)
        [self addRowForIndex:first + i y:14.0 + i * rowH
                       width:left + column leftInset:left];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * AppDelegate — state machine, UI, IPC
 * ═══════════════════════════════════════════════════════════════ */


@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) RootViewController *vc;
@property (nonatomic, strong) VideoView *videoView;
@property (nonatomic, strong)
    NSMutableDictionary<NSNumber *, CarPlayAudioPlayer *> *audioPlayers;

/* Setup overlay */
@property (nonatomic, strong) UIView   *setupOverlay;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *headlineLabel;
@property (nonatomic, strong) UIButton *primaryButton;     /* Start CarPlay / Open Settings */
@property (nonatomic, strong) UIButton *secondaryButton;   /* Cancel */
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) ConnectStepsView *stepsView;

/* Connection progress shown while the iPhone connects */
@property (nonatomic, assign) NSInteger connectCompleted;
@property (nonatomic, assign) BOOL firstTimePairing;
@property (nonatomic, assign) int btProgressToken;
@property (nonatomic, assign) BOOL autoStartConsumed;

/* Hotspot automation */
@property (nonatomic, assign) BOOL hotspotManual;          /* fell back to Settings */
@property (nonatomic, assign) NSInteger hotspotAttempt;
@property (nonatomic, strong) NSTimer *hotspotWatchdog;
@property (nonatomic, strong) NSTimer *discoveryTimer;

/* Floating chrome */
@property (nonatomic, strong) UIButton *closeButton;       /* top-right, only ACTIVE */
@property (nonatomic, strong) UIButton *settingsButton;    /* top-left, revealed with close during Active */
@property (nonatomic, strong) UIButton *starButton;        /* top-right on the setup screen */
@property (nonatomic, strong) ControlsOverlayView *controlsOverlay;

/* Three-finger tap is reserved for Showcase chrome and leaves pinch to CarPlay. */
@property (nonatomic, strong) UITapGestureRecognizer *controlsGesture;
@property (nonatomic, assign) BOOL chromeVisible;
/* The iPhone ended a running session; start again and wait for it, as a car
 * head unit does. The Stop button never sets this. */
@property (nonatomic, assign) BOOL restartAfterStop;

/* Lifecycle */
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;

/* State */
@property (nonatomic, assign) ShowcaseState state;

/* Children */
@property (nonatomic, assign) pid_t btdaemonPid;
@property (nonatomic, assign) pid_t carplayBtPid;
@property (nonatomic, assign) pid_t carplayServicesPid;
@property (nonatomic, assign) pid_t baaBrokerPid;

/* bridge100 tcpdump capture */
@property (nonatomic, assign) pid_t tcpdumpPid;
@property (nonatomic, copy)   NSString *currentTcpdumpPath;
@property (nonatomic, strong) NSTimer *tcpdumpStopTimer;
@property (nonatomic, strong) NSTimer *tcpdumpWaitTimer;
@property (nonatomic, assign) BOOL tcpdumpMissingPromptShown;
@property (nonatomic, assign) BOOL diagnosticsEnabled;
@property (nonatomic, assign) BOOL helpersLoggedThisRun;
@property (nonatomic, assign) BOOL bluetoothHandedOff;
@property (nonatomic, assign) BOOL bluetoothRetryAttempted;
@property (nonatomic, copy) NSString *pendingBluetoothErrorTitle;
@property (nonatomic, copy) NSString *pendingBluetoothErrorExplanation;
@property (nonatomic, copy) NSString *pendingBluetoothDiagnostic;

/* Networking */
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) int clientFd;
@property (nonatomic, strong) dispatch_queue_t bgQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;

/* BAA preheater and local signing broker */
@property (nonatomic, assign) BOOL baaReady;
@property (nonatomic, assign) BOOL baaLoading;
@property (nonatomic, copy) NSString *baaError;

/* AP polling */
@property (nonatomic, strong) NSTimer *apPollTimer;
@property (nonatomic, strong) dispatch_source_t awdlReassertTimer;

/* Cars */
@property (nonatomic, strong) CarStore *cars;
@end

/* Forward: defined later */
@interface WifiSetupViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@interface SettingsViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@property (nonatomic, copy) NSString *initialPage;
- (void)refresh;
@end

@implementation AppDelegate

- (UIInterfaceOrientationMask)application:(UIApplication *)application
        supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;
    (void)window;
    return showcase_orientation_mask();
}

- (UIView *)rootContentView {
    return self.vc.contentView ?: self.vc.view;
}

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {

    self.bgQueue = dispatch_queue_create("com.reng.showcase.bg", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create(
        "com.reng.showcase.video", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(self.videoQueue,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    self.audioPlayers = [NSMutableDictionary dictionary];
    /* No crash-recovery pass is needed here: iOS re-enables AWDL by itself
     * whenever a Continuity service wants it, which is exactly why the
     * suppression below has to be re-asserted on a timer. A run killed
     * mid-session therefore heals on its own. */
    self.state = StateIdle;
    self.listenFd = -1;
    self.clientFd = -1;
    self.bgTask = UIBackgroundTaskInvalid;
    self.tcpdumpPid = 0;
    self.tcpdumpMissingPromptShown = NO;
    /* Opening Showcase is turning the car on: start and page the iPhone. */
    NSMutableDictionary *defaults = [@{
        DEDICATED_RADIO_KEY: @YES,
        AUTO_START_KEY: @YES,
        USAGE_KEY: @YES
    } mutableCopy];
    for (NSArray *item in usage_items()) defaults[item[0]] = @YES;
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
    /* Prioritize Quality becomes the default once, existing setups included,
     * except with HSIC Wi-Fi (iPad Air 1, iPad mini 2 and 3): their tuned
     * 30 fps default plays smoother. 5-2 turned it on there too, so it is
     * turned back off once. Settings reads the display hardware anyway, so
     * the Wi-Fi bus probe runs off the main thread now. */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL hsic = carplay_display_hardware().wlanAttachment == CarPlayWLANAttachmentHSIC;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
            if (![prefs boolForKey:QUALITY_DEFAULT_SET_KEY]) {
                if (!hsic) {
                    [prefs setBool:YES forKey:QUALITY_VIDEO_KEY];
                    [prefs setBool:NO forKey:SMOOTH_VIDEO_KEY];
                }
                [prefs setBool:YES forKey:QUALITY_DEFAULT_SET_KEY];
            } else if (hsic && ![prefs boolForKey:QUALITY_HSIC_RESTORED_KEY]) {
                [prefs setBool:NO forKey:QUALITY_VIDEO_KEY];
            }
            [prefs setBool:YES forKey:QUALITY_HSIC_RESTORED_KEY];
            [prefs synchronize];
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ send_anonymous_usage(); });
    _diagnosticsEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:DIAGNOSTICS_ENABLED_KEY];
    /* A session that ended without stopFlow may have left a network paused. */
    dispatch_async(self.bgQueue, ^{
        stop_bluetooth_guard();
        showcase_release_other_wifi("launch recovery");
        /* A session that ended without stopFlow can leave BTstack holding the
         * controller and BlueTool unloaded. Release and hand it back. */
        const char *launchctl = launchctl_path();
        if (launchctl) {
            char *unloadBTstack[] = { (char *)"launchctl", (char *)"unload",
                                      (char *)BTSTACK_PLIST, NULL };
            run_blocking(launchctl, unloadBTstack);
            unlink(BTSTACK_SOCKET);
        }
        restore_system_bluetooth("launch recovery");
    });
    self.cars = [[CarStore alloc] init];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];

    self.vc = [[RootViewController alloc] init];
    self.vc.view.backgroundColor = [UIColor blackColor];
    self.vc.appDelegate = self;

    UIView *content = [self rootContentView];

    self.videoView = [[VideoView alloc] initWithFrame:content.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = [UIColor blackColor];
    ((AVSampleBufferDisplayLayer *)self.videoView.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [content addSubview:self.videoView];
    self.vc.videoView = self.videoView;

    [self buildSetupOverlay];
    [self buildChrome];

    self.window.rootViewController = self.vc;
    [self.window makeKeyAndVisible];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleBackground)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleForeground)
        name:UIApplicationWillEnterForegroundNotification object:nil];

    [self startObservingBluetoothProgress];
    [self transitionTo:StateIdle];
#ifdef SHOWCASE_UI_PREVIEW
    [self schedulePreviewFromFile];
#endif
    [self startBAA];
    /* The first preheat fails when the iPad is offline at launch, for example
     * before it rejoins Wi-Fi. Retry when the network changes. */
    int networkToken = 0;
    notify_register_dispatch("com.apple.system.config.network_change", &networkToken,
                             dispatch_get_main_queue(), ^(int token) { [self networkChanged]; });
    return YES;
}

- (void)networkChanged {
    static CFAbsoluteTime lastRetry = 0;
    if (self.state != StateIdle || self.baaReady || self.baaLoading || !self.baaError ||
        CFAbsoluteTimeGetCurrent() - lastRetry < 5) return;
    lastRetry = CFAbsoluteTimeGetCurrent();
    ip_log("network changed; retrying CarPlay authentication");
    [self startBAA];
}

/* Reaping stale helpers sleeps, so the broker starts off the main thread and
 * the first frame draws at once. Try Again comes here too when the broker
 * exited after a failed preheat. */
- (void)startBAA {
    if (self.baaLoading) return;
    self.baaLoading = YES;
    self.baaError = nil;
    [self renderState];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL started = [self startBAABroker];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaLoading = NO;
            if (started) {
                [self preheatBAA];
                return;
            }
            self.baaError = @"The local authentication broker could not start.";
            ip_log("BAA broker failed to start");
            [self renderState];
        });
    });
}

/* A broker from an earlier launch still holds a certificate, so a relaunch
 * after iOS ends Showcase in the background needs no internet. It is reused
 * for 12 hours, well inside the certificate's validity. */
#ifndef LOCAL_PEERPID
#define LOCAL_PEERPID 0x002
#endif
#define BAA_BROKER_REUSE_SECONDS (12 * 3600)

static pid_t reusable_baa_broker(void) {
    int fd = baa_broker_connect();
    if (fd < 0) return 0;
    pid_t pid = 0;
    socklen_t length = sizeof(pid);
    if (getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERPID, &pid, &length) != 0) pid = 0;
    close(fd);
    if (pid <= 0) return 0;
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0 ||
        time(NULL) - info.kp_proc.p_starttime.tv_sec > BAA_BROKER_REUSE_SECONDS) return 0;
    uint8_t *leaf = NULL, *intermediate = NULL;
    int leafLength = 0, intermediateLength = 0;
    int rc = baa_broker_get_certs(&leaf, &leafLength, &intermediate, &intermediateLength);
    free(leaf);
    free(intermediate);
    /* A broker that still holds its certificate may have lost its key. */
    static const uint8_t probe[] = "Showcase BAA reuse";
    uint8_t *signature = NULL;
    int signatureLength = 0;
    if (rc == 0) rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1), &signature, &signatureLength);
    free(signature);
    return rc == 0 && signatureLength > 0 ? pid : 0;
}

- (BOOL)startBAABroker {
    pid_t existing = reusable_baa_broker();
    if (existing > 0) {
        reap_stale_helpers(existing);
        self.baaBrokerPid = existing;
        ip_log("BAA broker pid=%d from an earlier launch reused", existing);
        return YES;
    }
    reap_stale_helpers(0);
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@SVC_HELPER_NAME];
    char *argv[] = {
        (char *)SVC_HELPER_NAME,
        (char *)"--baa-broker",
        NULL
    };
    self.baaBrokerPid = spawn_daemon([helper UTF8String], argv,
                                     LOG_DIR "/baa_broker.log");
    if (self.baaBrokerPid <= 0) return NO;
    ip_log("BAA preheat helper pid=%d", self.baaBrokerPid);
    return YES;
}

- (void)preheatBAA {
    if (self.baaLoading || self.baaReady || self.baaBrokerPid <= 0) return;
    self.baaLoading = YES;
    self.baaError = nil;
    [self renderState];
    ip_log("BAA preheat started before hotspot");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = -1;
        uint8_t *leaf = NULL, *intermediate = NULL;
        int leafLength = 0, intermediateLength = 0;
        for (int attempt = 0; attempt < 450; attempt++) {
            if (!pid_alive(self.baaBrokerPid)) {
                rc = -1;
                break;
            }
            rc = baa_broker_get_certs(&leaf, &leafLength,
                                      &intermediate, &intermediateLength);
            if (rc == 0) break;
            usleep(100000);
        }
        uint8_t *signature = NULL;
        int signatureLength = 0;
        static const uint8_t probe[] = "Showcase BAA preheat";
        if (rc == 0) {
            rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1),
                                 &signature, &signatureLength);
        }
        BOOL success = rc == 0 && signatureLength > 0;
        free(leaf);
        free(intermediate);
        free(signature);
        if (success) {
            ip_log("BAA preheat helper ready: leaf=%d intermediate=%d signature=%d",
                   leafLength, intermediateLength, signatureLength);
        } else {
            ip_log("BAA preheat helper failed rc=%d", rc);
            /* The next attempt starts a fresh broker. */
            kill_pid(self.baaBrokerPid);
            self.baaBrokerPid = 0;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaLoading = NO;
            self.baaReady = success;
            self.baaError = success ? nil :
                @"Unable to prepare CarPlay authentication. Check the internet connection.";
            [self renderState];
            [self startAutomaticallyIfRequested];
        });
    });
}

- (void)handleBackground {
    if (self.state != StateIdle && self.state != StateStopping) {
        ip_log("backgrounded — preserving CarPlay session");
        g_video_suspended = 1;
        g_video_needs_resync = 1;
        send_app_visibility(0);
        dispatch_async(self.videoQueue, ^{
            AVSampleBufferDisplayLayer *layer =
                (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });
    }
}

- (void)handleForeground {
    [self endBackgroundTask];
    ip_log("foregrounded — continuing state=%ld", (long)self.state);
    if (self.state == StateActive || self.state == StateAwaitingPhone) {
        g_video_needs_resync = 1;
        g_video_suspended = 0;
        dispatch_async(self.videoQueue, ^{
            AVSampleBufferDisplayLayer *layer =
                (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flush];
        });
        send_app_visibility(1);
        ip_log("foreground video resync requested");
    }
    if (self.state == StateAwaitingAP) [self pollAP];
    [self renderState];
    [self presentPendingBluetoothCompatibilityError];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [self endAWDLSuppression];
    showcase_release_other_wifi("app terminating");
    [self stopNetworkDumpCaptureWithReason:@"app terminating"];
    /* The BAA broker stays up so the next launch can reuse its certificate. */
}

- (void)endBackgroundTask {
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

/* ─── UI construction ──────────────────────────────────────── */

- (void)buildSetupOverlay {
    UIView *content = [self rootContentView];
    self.setupOverlay = [[UIView alloc] initWithFrame:content.bounds];
    self.setupOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.setupOverlay.backgroundColor = [UIColor blackColor];
    [content addSubview:self.setupOverlay];

    /* Wordmark */
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @APP_NAME;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont systemFontOfSize:64 weight:UIFontWeightUltraLight];
    [self.setupOverlay addSubview:self.titleLabel];

    /* Headline (state-dependent) */
    self.headlineLabel = [[UILabel alloc] init];
    self.headlineLabel.textAlignment = NSTextAlignmentCenter;
    self.headlineLabel.textColor = [UIColor whiteColor];
    self.headlineLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightRegular];
    self.headlineLabel.adjustsFontSizeToFitWidth = YES;
    self.headlineLabel.minimumScaleFactor = 0.75;
    [self.setupOverlay addSubview:self.headlineLabel];

    /* Spinner, for the states that have no step list */
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.setupOverlay addSubview:self.spinner];

    /* Connection checklist */
    self.stepsView = [[ConnectStepsView alloc] init];
    self.stepsView.userInteractionEnabled = NO;
    self.stepsView.completed = -1;
    [self.setupOverlay addSubview:self.stepsView];

    /* Primary button */
    self.primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.primaryButton.backgroundColor = [UIColor whiteColor];
    [self.primaryButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [self.primaryButton setTitleColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateHighlighted];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.primaryButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.primaryButton];

    /* Secondary button (Cancel) */
    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.3] forState:UIControlStateHighlighted];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.secondaryButton addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.secondaryButton];

    [self layoutSetupOverlay];
}

- (BOOL)isConnectingState {
    return self.state == StatePreparingBT ||
           self.state == StatePreparingNet ||
           self.state == StateAwaitingPhone;
}

/* Every visible element is stacked in one column and the column is centered
 * in the screen, so no element can overlap another at any screen size. */
- (void)layoutSetupOverlay {
    CGSize s = [self rootContentView].bounds.size;
    CGFloat W = s.width, H = s.height, cx = W / 2.0;
    BOOL phone = [self isPhone];
    BOOL shortScreen = H < 560;
    BOOL connecting = [self isConnectingState];

    self.titleLabel.font = [UIFont systemFontOfSize:(phone ? 44 : 64) weight:UIFontWeightUltraLight];
    self.headlineLabel.font = [UIFont systemFontOfSize:(phone ? 20 : 24) weight:UIFontWeightRegular];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 16 : 18) weight:UIFontWeightSemibold];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 14 : 15) weight:UIFontWeightRegular];

    CGFloat side = phone ? 70 : 40;
    CGFloat colW = MIN(W - side * 2, 560);
    CGFloat btnW = MIN(240, W - 80);
    CGFloat btnH = phone ? 46 : 52;

    /* The wordmark yields its space to the checklist on short screens. */
    self.titleLabel.hidden = connecting && shortScreen;
    self.stepsView.hidden = !connecting;
    self.stepsView.compact = shortScreen;

    NSMutableArray<NSArray *> *items = [NSMutableArray array];
    void (^add)(UIView *, CGFloat, CGFloat, CGFloat) =
        ^(UIView *view, CGFloat width, CGFloat height, CGFloat gapAfter) {
            if (view.hidden || height <= 0) return;
            [items addObject:@[view, @(width), @(height), @(gapAfter)]];
        };
    add(self.titleLabel, W, phone ? 54 : 78, shortScreen ? 18 : (phone ? 26 : 48));
    add(self.spinner, 36, 36, 20);
    add(self.headlineLabel, colW, phone ? 28 : 32,
        connecting ? (shortScreen ? 18 : 28) : (phone ? 26 : 36));
    add(self.stepsView, colW, [self.stepsView preferredHeightForWidth:colW], shortScreen ? 14 : 28);
    add(self.primaryButton, btnW, btnH, phone ? 12 : 16);
    add(self.secondaryButton, btnW, phone ? 30 : 34, 10);

    CGFloat total = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        total += [items[i][2] doubleValue];
        if (i + 1 < items.count) total += [items[i][3] doubleValue];
    }
    CGFloat y = MAX(phone ? 14 : 40, floor((H - total) * (phone ? 0.5 : 0.46)));
    for (NSArray *item in items) {
        UIView *view = item[0];
        CGFloat width = [item[1] doubleValue], height = [item[2] doubleValue];
        view.frame = CGRectMake(floor(cx - width / 2.0), floor(y), width, height);
        y += height + [item[3] doubleValue];
    }
    self.primaryButton.layer.cornerRadius = btnH / 2.0;
    [self.stepsView setNeedsLayout];
}

- (void)buildChrome {
    UIView *content = [self rootContentView];
    CGFloat sz = 44;
    CGFloat margin = 18;
    CGSize bs = content.bounds.size;

    self.controlsOverlay = [[ControlsOverlayView alloc]
        initWithFrame:content.bounds];
    self.controlsOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controlsOverlay.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.52];
    self.controlsOverlay.hidden = YES;
    [content addSubview:self.controlsOverlay];

    /* Any tap on the dimmed screen returns to CarPlay. */
    [self.controlsOverlay addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideChrome)]];

    /* Close button, top right, only while CarPlay runs */
    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.frame = CGRectMake(bs.width - sz - margin, margin, sz, sz);
    self.closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.closeButton.layer.cornerRadius = sz / 2.0;
    [self.closeButton setTitle:@"×" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
    self.closeButton.titleEdgeInsets = UIEdgeInsetsMake(-3, 0, 0, 0);
    self.closeButton.hidden = YES;
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.closeButton];

    /* Settings button, top left */
    self.settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.settingsButton.frame = CGRectMake(margin, margin, sz, sz);
    self.settingsButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    self.settingsButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.settingsButton.layer.cornerRadius = sz / 2.0;
    self.settingsButton.tintColor = [UIColor whiteColor];
    [self.settingsButton setImage:showcase_gear_image(22) forState:UIControlStateNormal];
    self.settingsButton.adjustsImageWhenHighlighted = YES;
    self.settingsButton.accessibilityLabel = L(@"Settings");
    [self.settingsButton addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.settingsButton];

    /* GitHub star button, top right; part of the setup screen, so it hides with it. */
    self.starButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.starButton.frame = CGRectMake(bs.width - sz - margin, margin, sz, sz);
    self.starButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.starButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.starButton.layer.cornerRadius = sz / 2.0;
    self.starButton.tintColor = [UIColor whiteColor];
    [self.starButton setImage:showcase_star_image(20) forState:UIControlStateNormal];
    self.starButton.accessibilityLabel = L(@"Give us a star on GitHub!");
    [self.starButton addTarget:self action:@selector(starTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.starButton];

    self.controlsGesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleChrome:)];
    self.controlsGesture.numberOfTouchesRequired = 3;
    self.controlsGesture.numberOfTapsRequired = 1;
    self.controlsGesture.cancelsTouchesInView = YES;
    self.controlsGesture.delaysTouchesBegan = NO;
    /* UIGestureRecognizer delays touch-up delivery by default while it
     * decides whether a gesture matches. That made every ordinary CarPlay
     * tap wait on the three-finger menu recognizer. */
    self.controlsGesture.delaysTouchesEnded = NO;
    self.controlsGesture.enabled = NO;
    [content addGestureRecognizer:self.controlsGesture];
}

- (BOOL)isPhone {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
}

/* ─── State machine ────────────────────────────────────────── */

- (void)transitionTo:(ShowcaseState)s {
    ShowcaseState old = self.state;
    self.state = s;

    if (s == StateAwaitingPhone && old != StateAwaitingPhone) {
        ip_log("[HANDOFF] Awaiting sender; CarPlay should perform Wi-Fi association through iAP2 handoff");
        if (self.diagnosticsEnabled)
            ip_log("diagnostics active; tcpdump remains off unless requested manually");
    } else if ((s == StateStopping || s == StateIdle) && old != s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopNetworkDumpCaptureWithReason:@"flow stopped"];
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (s == StatePreparingNet)
            [self completeConnectStep:ConnectStepBluetooth];
        else if (s == StateAwaitingPhone)
            [self completeConnectStep:ConnectStepServices];
        [self renderState];
        [self refreshPresentedSettings];
    });
}

/* ─── Connection progress ──────────────────────────────────── */

- (void)resetConnectProgress {
    self.connectCompleted = -1;
    self.firstTimePairing = NO;
}

- (void)completeConnectStep:(ConnectStep)step {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeConnectStep:step];
        });
        return;
    }
    if (step <= self.connectCompleted) return;
    self.connectCompleted = step;
    ip_log("[PROGRESS] step %ld complete", (long)step);
    if ([self isConnectingState]) [self renderState];
}

- (void)startObservingBluetoothProgress {
    int token = 0;
    uint32_t rc = notify_register_dispatch(
        SHOWCASE_BT_PROGRESS_NOTIFICATION, &token,
        dispatch_get_main_queue(), ^(int t) {
            uint64_t bits = 0;
            notify_get_state(t, &bits);
            [self applyBluetoothProgress:bits];
        });
    self.btProgressToken = rc == NOTIFY_STATUS_OK ? token : -1;
}

- (void)applyBluetoothProgress:(uint64_t)bits {
    if (![self isConnectingState] || bits == 0) return;
    ip_log("[PROGRESS] Bluetooth milestones=0x%llx", (unsigned long long)bits);
    if (bits & BT_PROGRESS_CONNECTED)
        [self completeConnectStep:ConnectStepPhoneBluetooth];
    if ((bits & BT_PROGRESS_AUTHORIZED) && (bits & BT_PROGRESS_IDENTIFIED))
        [self completeConnectStep:ConnectStepVerify];
    if (bits & BT_PROGRESS_WIFI_SENT)
        [self completeConnectStep:ConnectStepHotspotDetails];
}

- (void)updateConnectSteps {
    self.stepsView.pendingTitles = @[
        @"Bluetooth", L(@"CarPlay services"), @"iPhone", L(@"Verification"),
        L(@"Hotspot details"), @"Wi-Fi", L(@"Pairing"), @"CarPlay", L(@"Video")
    ];
    self.stepsView.doneTitles = self.stepsView.pendingTitles;
    self.stepsView.completed = self.connectCompleted;
    [self.stepsView setNeedsLayout];
}

- (void)renderState {
    self.setupOverlay.hidden = NO;
    self.closeButton.hidden = YES;
    self.controlsGesture.enabled = (self.state == StateActive);
    if (self.state != StateActive) {
        /* Restore the 1024x768 canvas in every non-Active state. */
        if ([self isPhone] && self.vc.fullscreenMode) {
            self.vc.fullscreenMode = NO;
            [self.vc.view setNeedsLayout];
        }
        self.videoView.transform = CGAffineTransformIdentity;
        self.chromeVisible = NO;
        self.controlsOverlay.hidden = YES;
        self.controlsOverlay.alpha = 1;
        self.settingsButton.hidden = NO;
        self.settingsButton.alpha = 1.0;
        self.closeButton.alpha = 1.0;
    }
    self.spinner.hidden = YES; [self.spinner stopAnimating];
    self.primaryButton.hidden = YES;
    self.primaryButton.enabled = YES;
    self.primaryButton.alpha = 1.0;
    self.secondaryButton.hidden = YES;

    Car *sel = self.cars.selected;
    NSString *carName = sel.name.length ? sel.name : L(@"your car");

    switch (self.state) {
        case StateIdle: {
            BOOL apReady = [self.cars apReady];
            self.primaryButton.hidden = NO;

            if (!apReady) {
                /* First run: Wi-Fi setup is the headline action. */
                self.headlineLabel.text = L(@"Welcome");
                [self.primaryButton setTitle:L(@"Set Up Wi-Fi") forState:UIControlStateNormal];
            } else {
                if (self.baaLoading) {
                    self.headlineLabel.text = L(@"Preparing");
                    [self.primaryButton setTitle:L(@"Preparing…") forState:UIControlStateNormal];
                    self.primaryButton.enabled = NO;
                    self.primaryButton.alpha = 0.55;
                } else if (!self.baaReady) {
                    self.headlineLabel.text = L(@"Connect to the Internet");
                    [self.primaryButton setTitle:L(@"Try Again")
                                       forState:UIControlStateNormal];
                } else {
                    self.headlineLabel.text = L(@"Wireless CarPlay");
                    [self.primaryButton setTitle:L(@"Start CarPlay")
                                       forState:UIControlStateNormal];
                }
            }
            break;
        }

        case StateAwaitingAP:
            if (!self.hotspotManual) {
                self.headlineLabel.text = L(@"Starting Personal Hotspot");
                self.spinner.hidden = NO;
                [self.spinner startAnimating];
            } else {
                self.headlineLabel.text = L(@"Turn On Personal Hotspot");
                [self.primaryButton setTitle:L(@"Open Settings") forState:UIControlStateNormal];
                self.primaryButton.hidden = NO;
            }
            [self.secondaryButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StatePreparingBT:
        case StatePreparingNet:
            self.headlineLabel.text = L(@"Getting Ready");
            [self updateConnectSteps];
            break;

        case StateAwaitingPhone:
            self.headlineLabel.text = self.connectCompleted >= ConnectStepPhoneBluetooth
                ? L(@"Connecting")
                : [NSString stringWithFormat:L(@"Choose %@ in CarPlay on your iPhone"), carName];
            [self updateConnectSteps];
            [self.secondaryButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StateActive:
            self.setupOverlay.hidden = YES;
            if ([self isPhone]) {
                self.vc.fullscreenMode = YES;
                [self.vc.view setNeedsLayout];
            }
            self.videoView.transform = CGAffineTransformIdentity;
            self.chromeVisible = NO;
            self.controlsOverlay.hidden = YES;
            self.controlsOverlay.alpha = 1;
            self.settingsButton.hidden = YES;
            self.closeButton.hidden = YES;
            break;

        case StateStopping:
            self.headlineLabel.text = L(@"Stopping");
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;
    }
    if (self.state == StateIdle && self.baaLoading) {
        self.spinner.hidden = NO;
        [self.spinner startAnimating];
    }
    [self layoutSetupOverlay];
}

- (void)primaryTapped {
    switch (self.state) {
        case StateIdle:
            if ([self.cars apReady]) [self attemptStart];
            else                     [self showWifiSetup];
            break;
        case StateAwaitingAP:
            [self openHotspotSettings];
            break;
        default:
            break;
    }
}

- (void)secondaryTapped {
    if (self.state == StateAwaitingAP || self.state == StateAwaitingPhone) {
        [self stopFlow];
    }
}

- (void)closeTapped { [self stopFlow]; }
- (void)settingsTapped { [self presentSettingsPage:nil]; }

- (void)starTapped {
    if (self.vc.presentedViewController) return;
    StarViewController *star = [[StarViewController alloc] init];
    star.modalPresentationStyle = UIModalPresentationOverFullScreen;
    star.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self.vc presentViewController:star animated:YES completion:nil];
}

- (void)presentSettingsPage:(NSString *)page {
    if ([self.vc.presentedViewController isKindOfClass:[SettingsViewController class]])
        return;
    SettingsViewController *settings = [[SettingsViewController alloc] init];
    settings.appDelegate = self;
    settings.initialPage = page;
    settings.modalPresentationStyle = UIModalPresentationOverFullScreen;
    settings.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:settings animated:YES completion:nil];
}

- (void)refreshPresentedSettings {
    UIViewController *presented = self.vc.presentedViewController;
    if ([presented isKindOfClass:[SettingsViewController class]])
        [(SettingsViewController *)presented refresh];
}

- (void)settingsDidClose {
    if (self.state == StateActive && self.chromeVisible) [self hideChrome];
    [self renderState];
    [self presentPendingBluetoothCompatibilityError];
}

- (void)toggleChrome:(UITapGestureRecognizer *)gesture {
    if (self.state != StateActive ||
        gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.chromeVisible) {
        [self hideChrome];
        return;
    }
    [self showChrome];
}

- (void)showChrome {
    if (self.state != StateActive || self.chromeVisible) return;
    self.chromeVisible = YES;
    self.controlsOverlay.alpha = 0;
    self.controlsOverlay.hidden = NO;
    self.settingsButton.hidden = NO;
    self.closeButton.hidden = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsOverlay.alpha = 1;
        self.settingsButton.alpha = 1;
        self.closeButton.alpha = 1;
    }];
}
- (void)hideChrome {
    self.chromeVisible = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.controlsOverlay.alpha = 0;
        self.settingsButton.alpha = 0;
        self.closeButton.alpha = 0;
    } completion:^(BOOL d) {
        if (self.state == StateActive) {
            self.controlsOverlay.hidden = YES;
            self.settingsButton.hidden = YES;
            self.closeButton.hidden = YES;
        }
    }];
}

#ifdef SHOWCASE_UI_PREVIEW
/* Development-only: never compiled into packages. Watches
 * /tmp/showcase_preview for a page name, or "steps:N", and shows that screen
 * in place so screens can be captured without a phone or a relaunch. */
- (void)schedulePreviewFromFile {
    static NSString *lastSpec = nil;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSString *spec = [[NSString stringWithContentsOfFile:@"/tmp/showcase_preview"
            encoding:NSUTF8StringEncoding error:NULL]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!spec.length || [spec isEqualToString:lastSpec]) return;
        lastSpec = spec;
        void (^apply)(void) = ^{
            if ([spec hasPrefix:@"steps:"]) {
                NSInteger n = [[spec substringFromIndex:6] integerValue];
                self.state = n < 1 ? StatePreparingBT : StateAwaitingPhone;
                self.connectCompleted = n - 1;
                self.firstTimePairing = n >= 6;
                [self renderState];
            } else if ([spec isEqualToString:@"home"]) {
                self.state = StateIdle;
                [self renderState];
            } else {
                self.state = StateIdle;
                [self renderState];
                [self presentSettingsPage:[spec isEqualToString:@"root"] ? nil : spec];
            }
        };
        void (^snapshot)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIGraphicsBeginImageContextWithOptions(self.window.bounds.size, YES, 0);
                [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
                UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [UIImagePNGRepresentation(image) writeToFile:@"/tmp/showcase_preview.png"
                                                  atomically:YES];
            });
        };
        if (self.vc.presentedViewController)
            [self.vc dismissViewControllerAnimated:NO completion:^{ apply(); snapshot(); }];
        else {
            apply();
            snapshot();
        }
    }];
}
#endif

/* ─── Action helpers ───────────────────────────────────────── */

/* "Start CarPlay automatically" runs once per launch, as soon as the
 * authentication certificate is ready, so a car-mounted screen needs no tap. */
- (void)startAutomaticallyIfRequested {
    /* Authentication may come later, after a retry; wait for it. */
    if (self.autoStartConsumed || !self.baaReady) return;
    self.autoStartConsumed = YES;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:AUTO_START_KEY]) return;
    if (self.state != StateIdle || !self.baaReady || ![self.cars apReady] ||
        self.cars.cars.count == 0 || self.vc.presentedViewController) {
        ip_log("auto start skipped: state=%ld baa=%d ap=%d presented=%d",
               (long)self.state, self.baaReady, [self.cars apReady],
               self.vc.presentedViewController != nil);
        return;
    }
    ip_log("auto start: starting CarPlay on launch");
    [self startFlow];
}

- (void)attemptStart {
    /* Should never be reachable when AP not ready (button is disabled) — defensive */
    if (![self.cars apReady]) { [self showWifiSetup]; return; }
    if (self.cars.cars.count == 0) return;
    if (!self.baaReady) {
        if (self.baaBrokerPid > 0 && pid_alive(self.baaBrokerPid)) [self preheatBAA];
        else [self startBAA];
        return;
    }
    [self startFlow];
}

- (void)startFlow {
    ip_log("startFlow: car='%s' ssid='%s'",
           [self.cars.selected.name UTF8String],
           [self.cars.apSSID UTF8String]);
    NSString *deviceName = hotspot_name();
    if (deviceName && ![deviceName isEqualToString:self.cars.apSSID])
        ip_log("[HOTSPOT] WARNING: hotspot is named '%s' but Showcase sends '%s'",
               deviceName.UTF8String, self.cars.apSSID.UTF8String);
    self.bluetoothHandedOff = NO;
    [self resetConnectProgress];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:DEDICATED_RADIO_KEY]) {
        dispatch_async(self.bgQueue, ^{ showcase_hold_other_wifi(); });
    }
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:HOTSPOT_OWNED_KEY];
    self.hotspotManual = NO;
    self.hotspotAttempt = 0;
    [self.apPollTimer invalidate];
    self.apPollTimer = nil;
    [self transitionTo:StateAwaitingAP];
    [self startHotspotAttempt];
}

/* ─── Hotspot automation ───────────────────────────────────── */

/* Showcase turns on Personal Hotspot itself. Attempt 1 repeats after a
 * Wi-Fi power cycle, which clears an access point wifid could not start.
 * After that the user turns the hotspot on in Settings. */
- (void)startHotspotAttempt {
    NSInteger attempt = self.hotspotAttempt;
    dispatch_async(self.bgQueue, ^{
        if (self.state != StateAwaitingAP) return;
        int state = showcase_hotspot_state();
        if (state < 0) {
            ip_log("[HOTSPOT] Mobile Internet Sharing unavailable; manual setup");
            dispatch_async(dispatch_get_main_queue(), ^{ [self fallBackToManualHotspot]; });
            return;
        }
        if (attempt == 0) {
            /* Turn the hotspot off at stop only if Showcase turned it on. */
            [[NSUserDefaults standardUserDefaults] setBool:(state != MIS_STATE_ON)
                                                    forKey:HOTSPOT_OWNED_KEY];
        }
        if (state == MIS_STATE_ON && !is_ap_up()) {
            /* On but not advertising: start it fresh. */
            showcase_set_hotspot(NO);
            usleep(1000000);
        }
        if (attempt == 1) {
            showcase_set_wifi_power(NO);
            sleep(3);
            showcase_set_wifi_power(YES);
            sleep(6);
        }
        if (self.state != StateAwaitingAP) return;
        showcase_set_hotspot(YES);
        usleep(800000);
        showcase_set_hotspot_discovery(YES);
        ip_log("[HOTSPOT] attempt %ld: hotspot requested", (long)attempt);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.state != StateAwaitingAP) return;
            [self renderState];
            [self.apPollTimer invalidate];
            self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
            [self.hotspotWatchdog invalidate];
            self.hotspotWatchdog = [NSTimer scheduledTimerWithTimeInterval:15.0
                target:self selector:@selector(hotspotAttemptTimedOut)
                userInfo:nil repeats:NO];
            [self startDiscoveryKeepalive];
        });
    });
}

- (void)hotspotAttemptTimedOut {
    self.hotspotWatchdog = nil;
    if (self.state != StateAwaitingAP || self.hotspotManual) return;
    ip_log("[HOTSPOT] attempt %ld did not bring up %s", (long)self.hotspotAttempt,
           AP_INTERFACE);
    self.hotspotAttempt += 1;
    if (self.hotspotAttempt <= 1) {
        [self startHotspotAttempt];
    } else {
        [self fallBackToManualHotspot];
    }
}

- (void)fallBackToManualHotspot {
    if (self.state != StateAwaitingAP) return;
    self.hotspotManual = YES;
    [self renderState];
    if (!self.apPollTimer) {
        self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
            target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
    }
}

/* wifid withdraws a discoverable hotspot that has no clients after a short
 * time. Keep it discoverable until the iPhone has joined and video runs. */
- (void)startDiscoveryKeepalive {
    [self.discoveryTimer invalidate];
    self.discoveryTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
        target:self selector:@selector(refreshDiscovery) userInfo:nil repeats:YES];
}

- (void)refreshDiscovery {
    BOOL connecting = self.state == StateAwaitingAP || [self isConnectingState];
    if (!connecting) {
        [self.discoveryTimer invalidate];
        self.discoveryTimer = nil;
        return;
    }
    showcase_set_hotspot_discovery(YES);
}

- (void)beginAWDLSuppression {
    if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 0, 1)) {
        awdl_suppress(YES);
        ip_log("AWDL suppressed for the duration of the session");
    }
    if (self.awdlReassertTimer) return;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    if (!timer) return;
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC)),
        (uint64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC),
        (uint64_t)(NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        if (g_awdl_suppressed) awdl_suppress(NO);
    });
    dispatch_resume(timer);
    self.awdlReassertTimer = timer;
}

- (void)endAWDLSuppression {
    if (self.awdlReassertTimer) {
        dispatch_source_cancel(self.awdlReassertTimer);
        self.awdlReassertTimer = nil;
    }
    if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 1, 0)) {
        awdl_restore(YES);
        ip_log("AWDL restored");
    }
}

- (void)pollAP {
    if (self.state != StateAwaitingAP) {
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        return;
    }
    if (is_ap_up()) {
        NSString *conf = [NSString stringWithContentsOfFile:@"/var/run/hostapd.conf"
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        NSString *channel = @"unknown";
        for (NSString *line in [conf componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"channel="]) channel = [line substringFromIndex:8];
        }
        ip_log("AP detected on channel %s; advancing", channel.UTF8String);
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        [self.hotspotWatchdog invalidate]; self.hotspotWatchdog = nil;
        [self transitionTo:StatePreparingBT];
        dispatch_async(self.bgQueue, ^{ [self bgPrepareBT]; });
    }
}

- (void)bgPrepareBT {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *btPath = [bundlePath stringByAppendingPathComponent:@BT_HELPER_NAME];
    Car *sel = self.cars.selected;
    ip_log("bgPrepareBT: euid=%u, name='%s' ssid='%s'",
           geteuid(), [sel.name UTF8String], [self.cars.apSSID UTF8String]);
    self.bluetoothRetryAttempted = NO;

    if (geteuid() != 0) {
        [self failBluetoothWithReason:
            @"The Showcase executable is not running as root (setuid setup failed)."
                             unsupported:NO];
        return;
    }
    if (access([btPath fileSystemRepresentation], X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled Bluetooth helper is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTDAEMON_PATH, X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack daemon is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_DYLIB_PATH, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled BTstack library is missing or is not readable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_PLIST, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon configuration is missing or unreadable."
                             unsupported:NO];
        return;
    }

    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    ip_log("[BT-COMPAT] registry probe=%s",
           registry == BluetoothRegistryProbeLegacyUART
               ? "legacy-uart-present"
               : (registry == BluetoothRegistryProbeSkywalk
                   ? "converged-skywalk-present"
                   : (registry == BluetoothRegistryProbeMissing
                       ? "supported-transport-missing" : "unavailable")));
    if (registry == BluetoothRegistryProbeMissing) {
        [self failBluetoothWithReason:
            @"The Bluetooth transport required by Showcase is not present in IOKit."
                             unsupported:YES];
        return;
    }
    if (registry == BluetoothRegistryProbeUnavailable) {
        /* A missing ioreg utility must not create a false rejection. The
         * controller takeover below is the authoritative runtime probe. */
        ip_log("[BT-COMPAT] static probe unavailable; continuing to runtime HCI probe");
    }

    if (self.diagnosticsEnabled) {
        enable_btstack_hci_logging();
    } else {
        disable_btstack_hci_logging();
    }
    self.helpersLoggedThisRun = self.diagnosticsEnabled;
    unlink(BT_READY_PATH);

    reap_stale_helpers(self.baaBrokerPid);

    const char *launchctl = launchctl_path();
    if (!launchctl) {
        [self failBluetoothWithReason:@"launchctl was not found."
                             unsupported:NO];
        return;
    }
    ip_log("launchctl path: %s", launchctl);
    if (!start_bluetooth_guard()) {
        [self failBluetoothWithReason:@"Bluetooth crash recovery could not start."
                             unsupported:NO];
        return;
    }
#ifdef SHOWCASE_TAURINE
    /* 1. Start the bundled BTstack daemon while launchd still spawns jobs.
     * On iOS 14 (Taurine) unloading bluetoothd leaves the unload "in
     * progress" while mediaserverd and others retry the vanished Bluetooth
     * services; launchd then stops spawning anything, so an on-demand
     * BTdaemon would hang in xpcproxy and never answer. The daemon only
     * touches the UART when a client powers it on. */
    if (![self startBTstackDaemon:launchctl]) return;

    /* 2. Release the UART: bluetoothd holds it (EBUSY) even with Bluetooth
     * off, and BlueTool owns it on iOS 14 and newer. */
    [self stopSystemBluetooth:launchctl];
#else
    /* 1. Unload bluetoothd */
    char *unloadArgv[] = { (char*)"launchctl", (char*)"unload",
                           (char*)BLUETOOTHD_PLIST, NULL };
    int rc = run_blocking(launchctl, unloadArgv);
    if (rc != 0) ip_log("  WARNING: launchctl unload returned %d", rc);
#ifdef SHOWCASE_ROOTLESS
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    rc = run_blocking(launchctl, unloadBlueToolArgv);
    if (rc != 0) ip_log("  WARNING: BlueTool unload returned %d", rc);
#endif
    /* Wait for Apple's Bluetooth to let go of the controller, up to 2 s. */
    for (int i = 0; i < 40 && (process_named_running("bluetoothd") ||
                                process_named_running("BlueTool")); i++)
        usleep(50000);

    /* 2. Start bundled BTstack through launchd so the advertised socket exists. */
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    unlink(BTSTACK_SOCKET);

    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    rc = run_blocking(launchctl, loadBTstackArgv);
    if (rc != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon failed to load."
                             unsupported:NO];
        return;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not create its control socket."
                             unsupported:NO];
        return;
    }
    self.btdaemonPid = 0;
#endif

    /* 3. Spawn carplay_bt with car name + global AP creds */
    char nameBuf[64], ssidBuf[128], passBuf[128];
    snprintf(nameBuf, sizeof(nameBuf), "%s", [sel.name UTF8String]);
    snprintf(ssidBuf, sizeof(ssidBuf), "%s", [self.cars.apSSID UTF8String]);
    snprintf(passBuf, sizeof(passBuf), "%s", [self.cars.apPassword UTF8String]);
    char *btArgv[] = {
        (char*)BT_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--ssid", ssidBuf,
        (char*)"--pass", passBuf,
        NULL
    };
    self.carplayBtPid = spawn_daemon([btPath UTF8String], btArgv,
                                     LOG_DIR "/carplay_bt.log");
    if (self.carplayBtPid <= 0) {
        [self failBluetoothWithReason:
            @"The Bluetooth helper could not be started."
                             unsupported:NO];
        return;
    }
    if (!wait_for_pid_alive_until(self.carplayBtPid, 8, "carplay_bt", BT_READY_PATH)) {
        [self failBluetoothWithReason:
            @"The Bluetooth helper exited during setup."
                             unsupported:YES];
        return;
    }
    if (!wait_for_bt_ready_or_exit(self.carplayBtPid, BT_READY_SECONDS)) {
        /* On some rootless boots BlueTool releases the controller after its
         * launchd job has already exited. BTstack then accepts a client and
         * its power command, but emits no HCI events. A complete daemon/client
         * restart is deterministic and preserves pairing data. */
        ip_log("[BT] first controller takeover produced no events; "
               "performing one clean retry");
        self.bluetoothRetryAttempted = YES;
        kill_pid(self.carplayBtPid);
        self.carplayBtPid = 0;
#ifdef SHOWCASE_TAURINE
        /* Bring Apple's Bluetooth back first so launchd can spawn the
         * daemon again. */
        char *loadBlueToolArgv[] = { (char*)"launchctl", (char*)"load",
                                     (char*)BLUETOOL_PLIST, NULL };
        char *loadArgv[] = { (char*)"launchctl", (char*)"load",
                             (char*)BLUETOOTHD_PLIST, NULL };
        run_blocking(launchctl, loadBlueToolArgv);
        run_blocking(launchctl, loadArgv);
        unlink(BT_OWNED_FLAG);
        sleep(2);
        if ([self startBTstackDaemon:launchctl]) {
            [self stopSystemBluetooth:launchctl];
            unlink(BT_READY_PATH);
            self.carplayBtPid =
                spawn_daemon([btPath UTF8String], btArgv,
                             LOG_DIR "/carplay_bt-retry.log");
        }
#else
        run_blocking(launchctl, unloadBTstackArgv);
        unlink(BTSTACK_SOCKET);
        sleep(2);
        rc = run_blocking(launchctl, loadBTstackArgv);
        if (rc == 0 &&
            wait_for_path(BTSTACK_SOCKET, 8, "BTstack retry socket")) {
            unlink(BT_READY_PATH);
            self.carplayBtPid =
                spawn_daemon([btPath UTF8String], btArgv,
                             LOG_DIR "/carplay_bt-retry.log");
        }
#endif
        if (self.carplayBtPid <= 0 ||
            !wait_for_bt_ready_or_exit(self.carplayBtPid, BT_RETRY_READY_SECONDS)) {
            [self failBluetoothWithReason:
                @"Bluetooth takeover failed after one clean retry; no HCI "
                 "controller-ready event was received."
                                 unsupported:YES];
            return;
        }
    }

    [self transitionTo:StatePreparingNet];
    [self bgPrepareNet];
}

#ifdef SHOWCASE_TAURINE
- (BOOL)startBTstackDaemon:(const char *)launchctl {
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    char *startBTstackArgv[] = { (char*)"launchctl", (char*)"start",
                                 (char*)"ch.ringwald.BTstack", NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    signal_processes_named("BTdaemon", SIGKILL, 0);
    unlink(BTSTACK_SOCKET);
    if (run_blocking(launchctl, loadBTstackArgv) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon failed to load."
                             unsupported:NO];
        return NO;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not create its control socket."
                             unsupported:NO];
        return NO;
    }
    run_blocking(launchctl, startBTstackArgv);
    for (int i = 0; i < 50 && !process_named_running("BTdaemon"); i++)
        usleep(100000);
    if (!process_named_running("BTdaemon")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not start."
                             unsupported:NO];
        return NO;
    }
    ip_log("[BT] BTdaemon running before system Bluetooth stops");
    self.btdaemonPid = 0;
    return YES;
}

- (void)stopSystemBluetooth:(const char *)launchctl {
    int flag = open(BT_OWNED_FLAG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (flag >= 0) close(flag);
    char *unloadArgv[] = { (char*)"launchctl", (char*)"unload",
                           (char*)BLUETOOTHD_PLIST, NULL };
    int rc = run_blocking(launchctl, unloadArgv);
    if (rc != 0) ip_log("  WARNING: launchctl unload returned %d", rc);
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    rc = run_blocking(launchctl, unloadBlueToolArgv);
    if (rc != 0) ip_log("  WARNING: BlueTool unload returned %d", rc);
    /* An unload can stay in progress; make sure the UART is free. */
    signal_processes_named("bluetoothd", SIGKILL, 0);
    signal_processes_named("BlueTool", SIGKILL, 0);
    sleep(2);
}
#endif

- (void)bgPrepareNet {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *svcPath = [bundlePath stringByAppendingPathComponent:@SVC_HELPER_NAME];
    Car *sel = self.cars.selected;
    ip_log("bgPrepareNet");

    if (![self startIPCListener]) { [self failWith:@"IPC listener failed"]; return; }

    char nameBuf[64];
    char widthBuf[16], heightBuf[16], fpsBuf[16], receiveBufferBuf[16];
    CarPlayVideoPriority priority = carplay_video_priority();
    BOOL receiverAudio = [[NSUserDefaults standardUserDefaults]
        boolForKey:RECEIVER_AUDIO_KEY];
    BOOL rightHandDrive = [[NSUserDefaults standardUserDefaults]
        boolForKey:RIGHT_HAND_DRIVE_KEY];
    CarPlayDisplayProfile display =
        preferred_carplay_display_profile();
    uint16_t displayWidth = display.width;
    uint16_t displayHeight = display.height;
    /*
     * The TCP receive window bounds how much screen data the iPhone may have
     * in flight, and so how large a burst reaches this radio at once.
     *
     * HSIC-attached Broadcom chips post a small pool of host receive buffers
     * across a USB-class bus. A burst larger than that pool is acknowledged
     * over the air and then discarded inside the chip ("Rx Out Of Buffers"),
     * so the 802.11 layer never retries it and TCP must recover the hole.
     * Measured on an iPad4,2 with a CarPlay-shaped stream (30 fps, 40 KB
     * frames, 200 KB keyframes): 2 MiB window 6-7% of frames discarded,
     * 512 KiB 2-4%, 256 KiB 2-3%, 128 KiB 0.4-0.8%, 64 KiB 0.2% but with
     * window-limited delivery. The same test on a PCIe iPhone9,3 discarded
     * nothing at any window. The old 2 MiB "headroom" also let seconds of
     * video queue in flight (smoothed RTT 1.4-2.5 s in July captures), which
     * is what made the sender's screen sink skip frames.
     *
     * Apple's receiver sizes this socket at 110% of a 160 KiB frame. Use that
     * everywhere, and 128 KiB on HSIC where the bus is the bottleneck.
     */
    int screenReceiveBuffer =
        display.wlanAttachment == CarPlayWLANAttachmentHSIC
            ? 128 * 1024
            : (110 * 160 * 1024) / 100;
    snprintf(nameBuf, sizeof(nameBuf), "%s", [sel.name UTF8String]);
    snprintf(widthBuf, sizeof(widthBuf), "%u", displayWidth);
    snprintf(heightBuf, sizeof(heightBuf), "%u", displayHeight);
    snprintf(fpsBuf, sizeof(fpsBuf), "%u", display.framesPerSecond);
    snprintf(receiveBufferBuf, sizeof(receiveBufferBuf), "%d",
             screenReceiveBuffer);
    ip_log("display profile: native=%ux%u memory=%lluMB cores=%lu "
           "budget=%llu pixels selected=%ux%u@%u wlan=%s rcvbuf=%d "
           "priority=%s audio=%s dock=%s",
           display.nativeLong, display.nativeShort,
           (unsigned long long)(display.physicalMemory / (1024ULL * 1024ULL)),
           (unsigned long)display.activeProcessors,
           (unsigned long long)display.pixelBudget,
           displayWidth, displayHeight, display.framesPerSecond,
           carplay_wlan_attachment_name(display.wlanAttachment),
           screenReceiveBuffer,
           priority == CarPlayVideoQuality ? "quality"
               : (priority == CarPlayVideoPerformance ? "performance" : "custom"),
           receiverAudio ? "receiver" : "sender",
           rightHandDrive ? "right" : "left");
    char *svcArgv[] = {
        (char*)SVC_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--width", widthBuf,
        (char*)"--height", heightBuf,
        (char*)"--fps", fpsBuf,
        (char*)"--screen-rcvbuf", receiveBufferBuf,
        (char*)"--audio", (char*)(receiverAudio ? "receiver" : "sender"),
        rightHandDrive ? (char*)"--right-hand-drive" : NULL,
        NULL
    };
    /*
     * The service log is the only record of encrypted RTSP negotiation and
     * transport arrival. Keep it for every run; spawn_daemon truncates the
     * file at launch, so this has bounded storage cost and cannot silently
     * erase the evidence needed to diagnose a failed session.
     */
    self.carplayServicesPid = spawn_daemon(
        [svcPath UTF8String], svcArgv, LOG_DIR "/carplay_services.log");
    if (self.carplayServicesPid <= 0) { [self failWith:@"carplay_services failed to start"]; return; }
    if (!wait_for_pid_alive(self.carplayServicesPid, 4, "carplay_services")) {
        [self failWith:@"carplay_services exited during setup"];
        return;
    }

    /* A paired phone can resume quickly enough to deliver video while the
     * helper-alive check above is still running. Do not overwrite Active
     * with the older setup state when that happens. */
    if (self.state != StateActive) {
        [self transitionTo:StateAwaitingPhone];
    } else {
        ip_log("[HANDOFF] Existing paired session resumed during startup");
    }
}

- (void)completeBluetoothHandoff {
    dispatch_async(self.bgQueue, ^{
        if (self.bluetoothHandedOff ||
            self.state == StateStopping || self.state == StateIdle) {
            return;
        }

        /*
         * The controller has completed Bluetooth discovery and moved the
         * CarPlay session onto Wi-Fi. Own teardown here, outside BTstack's
         * callback and signal contexts. Leaving BTstack active forces the
         * combo radio to arbitrate 2.4 GHz airtime while the H.264 TCP stream
         * is running, which turns individual Wi-Fi losses into visible
         * head-of-line stalls.
         */
        ip_log("[HANDOFF] Wi-Fi session established; stopping Bluetooth helper");
        kill_pid(self.carplayBtPid);
        self.carplayBtPid = 0;

        const char *launchctl = launchctl_path();
        int rc = -1;
        if (launchctl) {
            char *unloadBTstackArgv[] = {
                (char *)"launchctl", (char *)"unload",
                (char *)BTSTACK_PLIST, NULL
            };
            rc = run_blocking(launchctl, unloadBTstackArgv);
        }
        unlink(BTSTACK_SOCKET);

        self.bluetoothHandedOff = YES;
        ip_log("[HANDOFF] Bluetooth transport stopped (BTstack unload=%d)", rc);
        /* The session now runs over Wi-Fi alone. Leaving bluetoothd unloaded
         * would keep launchd and mediaserverd busy for the whole session,
         * about one core of a two-core receiver. */
        restore_system_bluetooth("Wi-Fi handoff complete");
    });
}

- (void)stopFlow {
    BOOL restart = self.restartAfterStop;
    self.restartAfterStop = NO;
    [self endAWDLSuppression];
    [self stopNetworkDumpCaptureWithReason:@"user cancelled / stopping flow"];
    [self endBackgroundTask];
    [self.apPollTimer invalidate]; self.apPollTimer = nil;
    [self.hotspotWatchdog invalidate]; self.hotspotWatchdog = nil;
    [self.discoveryTimer invalidate]; self.discoveryTimer = nil;
    [self transitionTo:StateStopping];
    dispatch_async(self.bgQueue, ^{
        if (self.clientFd >= 0) { close(self.clientFd); self.clientFd = -1; }
        if (self.listenFd >= 0) { close(self.listenFd); self.listenFd = -1; }
        unlink(SOCK_PATH);
        g_touch_fd = -1;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        g_carplay_w = 0; g_carplay_h = 0;
        g_video_suspended = 0;
        g_video_needs_resync = 0;

        kill_pid(self.carplayServicesPid); self.carplayServicesPid = 0;
        kill_pid(self.carplayBtPid);       self.carplayBtPid = 0;
        self.btdaemonPid = 0;
        self.bluetoothHandedOff = NO;

        const char *launchctl = launchctl_path();
        if (launchctl) {
            char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                          (char*)BTSTACK_PLIST, NULL };
            run_blocking(launchctl, unloadBTstackArgv);
            unlink(BTSTACK_SOCKET);
            restore_system_bluetooth("CarPlay stopped");
        } else {
            ip_log("WARNING: launchctl not found while restoring bluetoothd");
        }
        if ([[NSUserDefaults standardUserDefaults] boolForKey:HOTSPOT_OWNED_KEY]) {
            showcase_set_hotspot_discovery(NO);
            showcase_set_hotspot(NO);
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:HOTSPOT_OWNED_KEY];
            ip_log("[HOTSPOT] turned off the hotspot Showcase started");
        }
        showcase_release_other_wifi("CarPlay stopped");

        dispatch_async(dispatch_get_main_queue(), ^{
            AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });

        [self transitionTo:StateIdle];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPendingBluetoothCompatibilityError];
            if (restart && self.state == StateIdle && self.baaReady &&
                !self.vc.presentedViewController) [self startFlow];
        });
    });
}

- (void)failBluetoothWithReason:(NSString *)reason
                    unsupported:(BOOL)unsupported {
    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    NSString *report = bluetooth_diagnostic_report(
        reason, self.bluetoothRetryAttempted, registry);
    NSString *failureClass =
        bluetooth_failure_class(reason, report, registry);
    ip_log("[BT-COMPAT] failure class=%s reason=%s\n%s",
           [failureClass UTF8String], [reason UTF8String],
           [report UTF8String]);

    self.pendingBluetoothErrorTitle = unsupported
        ? L(@"Bluetooth Hardware Not Supported")
        : L(@"Bluetooth Setup Failed");
    self.pendingBluetoothErrorExplanation = unsupported
        ? L(@"Showcase could not take over this device's Bluetooth controller. "
          "Tell the developer or community that this model is not yet supported "
          "and include the diagnostic below.")
        : L(@"Showcase's Bluetooth components are incomplete or could not start. "
          "Copy the diagnostic below before reinstalling or reporting the problem.");
#if !defined(SHOWCASE_TAURINE) && !defined(SHOWCASE_ROOTLESS)
    /* Taurine on iOS 14 needs its own package's Bluetooth takeover. */
    if (showcase_on_taurine()) {
        self.pendingBluetoothErrorTitle = L(@"Install Showcase for Taurine");
        self.pendingBluetoothErrorExplanation =
            L(@"This device runs Taurine, which needs a different Bluetooth setup. "
             "Install Showcase for Taurine from the same repository; it replaces this package.");
    }
#endif
    self.pendingBluetoothDiagnostic = report;
    [self stopFlow];
}

- (void)presentPendingBluetoothCompatibilityError {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPendingBluetoothCompatibilityError];
        });
        return;
    }
    if (!self.pendingBluetoothDiagnostic.length ||
        [UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive ||
        self.vc.presentedViewController) {
        return;
    }

    CompatibilityErrorViewController *error =
        [[CompatibilityErrorViewController alloc] init];
    error.errorTitle = self.pendingBluetoothErrorTitle;
    error.explanation = self.pendingBluetoothErrorExplanation;
    error.diagnostic = self.pendingBluetoothDiagnostic;
    error.modalPresentationStyle = UIModalPresentationOverFullScreen;
    error.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    self.pendingBluetoothErrorTitle = nil;
    self.pendingBluetoothErrorExplanation = nil;
    self.pendingBluetoothDiagnostic = nil;
    [self.vc presentViewController:error animated:YES completion:nil];
}

- (void)failWith:(NSString *)reason {
    ip_log("FAIL: %s", [reason UTF8String]);
    [self stopFlow];
}

- (void)openHotspotSettings {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=INTERNET_TETHERING"];
    UIApplication *a = [UIApplication sharedApplication];
    if ([a canOpenURL:u]) {
        [a openURL:u options:@{} completionHandler:nil];
    } else {
        u = [NSURL URLWithString:@"prefs:root=INTERNET_TETHERING"];
        [a openURL:u options:@{} completionHandler:nil];
    }
}

/* ─── Wi-Fi setup ───────────────────────────────────────────────
 * Two-step flow surfaced through WifiSetupViewController.
 *   Step 1: instructional content asking the user to rename the iPad
 *           in iOS Settings (the iPad's name IS the hotspot SSID).
 *   Step 2: a focused credentials prompt for the SSID and password.
 * ─────────────────────────────────────────────────────────────── */

- (void)showWifiSetup {
    WifiSetupViewController *vc = [[WifiSetupViewController alloc] init];
    vc.appDelegate = self;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self.vc presentViewController:vc animated:YES completion:nil];
}

/* iOS names Personal Hotspot after the device. The iPhone is told to join the
 * name entered here, so a different name leaves it unable to connect. */
static NSString *gestalt_string(CFStringRef key) {
    void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    CFTypeRef (*copy)(CFStringRef) = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
    CFTypeRef value = copy ? copy(key) : NULL;
    NSString *string = value && CFGetTypeID(value) == CFStringGetTypeID() ?
        [(__bridge NSString *)value copy] : nil;
    if (value) CFRelease(value);
    return string.length ? string : nil;
}

/* Without access, iOS 16 and later answer with the model ("iPad"). */
static NSString *hotspot_name(void) {
    NSString *name = gestalt_string(CFSTR("UserAssignedDeviceName"));
    return [name isEqualToString:gestalt_string(CFSTR("DeviceName"))] ? nil : name;
}

- (void)saveSSID:(NSString *)ssid password:(NSString *)pass host:(UIViewController *)host {
    [self.cars setAPSSID:ssid password:pass];
    [host dismissViewControllerAnimated:YES completion:^{ [self renderState]; }];
}

/* Called by WifiSetupViewController when the user taps "Set credentials".
 * This is a focused alert prompt for SSID + password. */
- (void)promptForCredentialsFromController:(UIViewController *)host {
    NSString *deviceName = hotspot_name();
    NSString *currentSSID = self.cars.apSSID.length ? self.cars.apSSID : (deviceName ?: @"");
    NSString *currentPass = self.cars.apPassword ?: @"";

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:L(@"Hotspot Details")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = L(@"Name");
        tf.text = currentSSID;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = L(@"Password");
        tf.text = currentPass;
        tf.secureTextEntry = YES;
    }];

    __weak UIViewController *weakHost = host;
    [ac addAction:[UIAlertAction actionWithTitle:L(@"Save") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            NSString *ssid = ac.textFields[0].text ?: @"";
            NSString *pass = ac.textFields[1].text ?: @"";
            NSString *err = validateSSID(ssid);
            if (!err && pass.length < 8) {
                err = L(@"Hotspot passwords must be at least 8 characters.");
            }
            if (err) {
                UIAlertController *e = [UIAlertController
                    alertControllerWithTitle:L(@"Try Again")
                                     message:err
                              preferredStyle:UIAlertControllerStyleAlert];
                [e addAction:[UIAlertAction actionWithTitle:L(@"OK")
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *_b) {
                        [self promptForCredentialsFromController:weakHost];
                    }]];
                [weakHost presentViewController:e animated:YES completion:nil];
                return;
            }
            if (deviceName && ![ssid isEqualToString:deviceName]) {
                UIAlertController *m = [UIAlertController
                    alertControllerWithTitle:L(@"Different Name")
                                     message:[NSString stringWithFormat:
                        L(@"This iPad's hotspot is called \u201c%@\u201d. Your iPhone joins the name you enter here, so it has to match. To use \u201c%@\u201d, rename the iPad in Settings > General > About > Name."),
                        deviceName, ssid]
                              preferredStyle:UIAlertControllerStyleAlert];
                [m addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:L(@"Use \u201c%@\u201d"), deviceName]
                    style:UIAlertActionStyleDefault handler:^(UIAlertAction *_b) {
                        if (validateSSID(deviceName)) {
                            [self promptForCredentialsFromController:weakHost];
                            return;
                        }
                        [self saveSSID:deviceName password:pass host:weakHost];
                    }]];
                [m addAction:[UIAlertAction actionWithTitle:L(@"Keep") style:UIAlertActionStyleCancel
                    handler:^(UIAlertAction *_b) { [self saveSSID:ssid password:pass host:weakHost]; }]];
                [weakHost presentViewController:m animated:YES completion:nil];
                return;
            }
            [self saveSSID:ssid password:pass host:weakHost];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:L(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];

    [host presentViewController:ac animated:YES completion:nil];
}

/* ─── bridge100 tcpdump capture ────────────────────────────── */

- (UIViewController *)topPresenter {
    UIViewController *p = self.vc ?: self.window.rootViewController;
    while (p.presentedViewController) p = p.presentedViewController;
    return p ?: self.window.rootViewController;
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenter] presentViewController:ac animated:YES completion:nil];
}

- (void)presentExportSavedAlertForPath:(NSString *)path reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:L(@"%@\n\nSaved to:\n%@"),
                         reason ?: L(@"The share sheet could not be shown."), path ?: @"(unknown)"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:L(@"Export Saved")
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"Copy Path")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                if (path.length) [UIPasteboard generalPasteboard].string = path;
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = [self topPresenter];
        if ([presenter isKindOfClass:[UIAlertController class]] && presenter.presentingViewController) {
            presenter = presenter.presentingViewController;
        }
        [presenter presentViewController:ac animated:YES completion:nil];
    });
}

- (void)presentShareForURL:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = url.path;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!url || ![fm fileExistsAtPath:path] || ![fm isReadableFileAtPath:path]) {
            ip_log("[SHARE] file missing/unreadable path=%s", path ? [path UTF8String] : "(nil)");
            [self presentAlertWithTitle:L(@"File Missing") message:L(@"The export file could not be found or read.")];
            return;
        }

        UIActivityViewController *avc =
            [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                              applicationActivities:nil];
        avc.excludedActivityTypes = @[ UIActivityTypeAirDrop ];

        UIViewController *presenter = [self topPresenter];
        if (!presenter) {
            ip_log("[SHARE] share failed: no presenter path=%s", [path UTF8String]);
            [self presentExportSavedAlertForPath:path reason:L(@"The share sheet could not be shown.")];
            return;
        }
        if ([presenter isKindOfClass:[UIAlertController class]]) {
            ip_log("[SHARE] share delayed: top presenter is alert");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentShareForURL:url];
            });
            return;
        }

        if (avc.popoverPresentationController) {
            UIView *source = presenter.view ?: self.vc.contentView ?: self.vc.view;
            if (!source || CGRectIsEmpty(source.bounds)) {
                ip_log("[SHARE] share failed: no stable source view path=%s", [path UTF8String]);
                [self presentExportSavedAlertForPath:path reason:L(@"The export was created, but the share sheet had no valid presentation view.")];
                return;
            }
            avc.popoverPresentationController.sourceView = source;
            avc.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1, 1);
            avc.popoverPresentationController.permittedArrowDirections = 0;
        }

        ip_log("[SHARE] presenting share sheet path=%s airdrop=excluded", [path UTF8String]);
        [presenter presentViewController:avc animated:YES completion:nil];
    });
}

- (void)applyDiagnosticsEnabled:(BOOL)enabled {
    _diagnosticsEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DIAGNOSTICS_ENABLED_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("diagnostics %s", enabled ? "enabled" : "disabled");

    if (enabled) {
        enable_btstack_hci_logging();
    } else {
        [self stopNetworkDumpCaptureWithReason:@"diagnostics disabled"];
        disable_btstack_hci_logging();
    }
}

- (void)clearLogsAndDumps {
    [self stopNetworkDumpCaptureWithReason:@"clearing logs and dumps"];

    if (g_logfile) {
        fclose(g_logfile);
        g_logfile = NULL;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        @LOG_DIR,
        @TCPDUMP_DIR,
        @"/var/mobile/Library/Showcase/diagnostics",
        @"/tmp/hci_dump.pklg",
        @SHOWCASE_BTSTACK_LOG_PATH
    ];
    for (NSString *path in paths) {
        [fm removeItemAtPath:path error:nil];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    ip_log_open();
    ip_log("logs and dumps cleared");
}

- (NSString *)timestampStringForFilename {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}

- (NSString *)latestNetworkDumpPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"latestTcpdumpPath"];
    if (stored.length > 0 && [fm fileExistsAtPath:stored]) return stored;

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:@TCPDUMP_DIR error:nil];
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *f in files) {
        if (![f hasSuffix:@".pcap"]) continue;
        NSString *path = [@TCPDUMP_DIR stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (!best || [mtime compare:bestDate] == NSOrderedDescending) {
            best = path;
            bestDate = mtime;
        }
    }
    if (best) {
        [[NSUserDefaults standardUserDefaults] setObject:best forKey:@"latestTcpdumpPath"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return best;
}

- (BOOL)spawnTcpdumpAtPath:(NSString *)pcapPath useSelfTimeout:(BOOL)useSelfTimeout {
    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) return NO;

    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(TCPDUMP_DIR, 0755);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, TCPDUMP_LOG, O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);

    /* Diagnostics must not become part of the performance problem. Full
     * screen packets plus -U forced hundreds of pcap writes per second on
     * older flash. A 256-byte snap length retains Ethernet/IP/TCP/UDP
     * headers and enough protocol prefix for flow, ACK, retransmission, and
     * RTP timing analysis. The larger capture buffer is flushed normally
     * when SIGINT stops tcpdump. */
    char *argvTimed[] = {
        (char*)"tcpdump", (char*)"-i", (char*)AP_INTERFACE,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-G", (char*)"300", (char*)"-W", (char*)"1",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };
    char *argvPlain[] = {
        (char*)"tcpdump", (char*)"-i", (char*)AP_INTERFACE,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };

    char **argv = useSelfTimeout ? argvPlain : argvTimed;
    ip_log("tcpdump spawn: %s -i %s -B 4096 -s 256 %s-w %s",
           tcpdump, AP_INTERFACE, useSelfTimeout ? "" : "-G 300 -W 1 ",
           [pcapPath UTF8String]);

    int err = posix_spawn(&pid, tcpdump, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("tcpdump posix_spawn FAIL: %s", strerror(err));
        return NO;
    }

    usleep(250000);
    int status = 0;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
        ip_log("tcpdump exited immediately status=%d", status);
        return NO;
    }

    self.tcpdumpPid = pid;
    self.currentTcpdumpPath = pcapPath;
    [[NSUserDefaults standardUserDefaults] setObject:pcapPath forKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("tcpdump running pid=%d path=%s", pid, [pcapPath UTF8String]);
    return YES;
}

- (void)promptInstallTcpdumpIfNeeded {
    if (self.tcpdumpMissingPromptShown) return;
    self.tcpdumpMissingPromptShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:L(@"Network Dump Unavailable")
            message:L(@"tcpdump is not installed. Install the package named tcpdump in Sileo, then reopen Showcase. CarPlay can still run; only the network dump is disabled.")
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"Open Sileo")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                NSURL *u = [NSURL URLWithString:@"sileo://package/tcpdump"];
                [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:L(@"OK")
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *p = self.vc.presentedViewController ?: self.vc;
        [p presentViewController:ac animated:YES completion:nil];
    });
}

- (void)startNetworkDumpCapture {
    if (!self.diagnosticsEnabled) {
        ip_log("tcpdump not started; diagnostics disabled");
        return;
    }
    if (self.tcpdumpPid > 0 && pid_alive(self.tcpdumpPid)) return;

    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) {
        ip_log("tcpdump missing; cannot capture bridge100");
        [self promptInstallTcpdumpIfNeeded];
        return;
    }

    /* tcpdump exits at once on an interface that is not up yet, so wait
     * for the hotspot (up to 15 minutes) instead. */
    if (!is_ap_up()) {
        if (self.tcpdumpWaitTimer) return;
        ip_log("tcpdump waits for %s to come up", AP_INTERFACE);
        __weak typeof(self) weakSelf = self;
        __block int seconds = 0;
        self.tcpdumpWaitTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES
            block:^(NSTimer *timer) {
                if (!is_ap_up() && ++seconds < 900) return;
                [timer invalidate];
                weakSelf.tcpdumpWaitTimer = nil;
                if (is_ap_up()) [weakSelf startNetworkDumpCapture];
                else ip_log("tcpdump not started; %s never came up", AP_INTERFACE);
            }];
        return;
    }

    NSString *stamp = [self timestampStringForFilename];
    NSString *path = [NSString stringWithFormat:@"%s/showcase_bridge100_%@.pcap", TCPDUMP_DIR, stamp];

    /* First try tcpdump's own 5-minute rotation stop, so the child exits even
     * if the app crashes. Older builds that dislike -G/-W fall back to an app
     * timer below. */
    if (![self spawnTcpdumpAtPath:path useSelfTimeout:NO]) {
        ip_log("tcpdump timed mode failed; retrying plain mode with app timer");
        if (![self spawnTcpdumpAtPath:path useSelfTimeout:YES]) {
            ip_log("tcpdump could not start; see tcpdump.log");
            return;
        }
    }

    [self.tcpdumpStopTimer invalidate];
    self.tcpdumpStopTimer = [NSTimer scheduledTimerWithTimeInterval:TCPDUMP_MAX_SECONDS
        target:self selector:@selector(tcpdumpTimedOut) userInfo:nil repeats:NO];
}

- (void)tcpdumpTimedOut {
    [self stopNetworkDumpCaptureWithReason:@"5 minute limit reached"];
}

- (void)stopNetworkDumpCaptureWithReason:(NSString *)reason {
    [self.tcpdumpStopTimer invalidate]; self.tcpdumpStopTimer = nil;
    [self.tcpdumpWaitTimer invalidate]; self.tcpdumpWaitTimer = nil;
    pid_t pid = self.tcpdumpPid;
    if (pid <= 0) return;

    ip_log("stopping tcpdump pid=%d reason=%s", pid, [reason UTF8String]);
    kill(pid, SIGINT); /* lets tcpdump flush pcap footer/stats */
    for (int i = 0; i < 30; i++) {
        int status = 0;
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) {
            ip_log("tcpdump stopped status=%d", status);
            self.tcpdumpPid = 0;
            return;
        }
        usleep(100000);
    }
    kill(pid, SIGTERM);
    usleep(300000);
    if (pid_alive(pid)) kill(pid, SIGKILL);
    int status = 0; waitpid(pid, &status, WNOHANG);
    self.tcpdumpPid = 0;
}

- (void)copyPath:(NSString *)src toDiagnosticsDir:(NSString *)dir name:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return;
    NSString *dst = [dir stringByAppendingPathComponent:name ?: [src lastPathComponent]];
    [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&err]) {
        ip_log("diagnostics copy failed: %s -> %s (%s)",
               [src UTF8String], [dst UTF8String],
               [[err localizedDescription] UTF8String]);
    }
}

- (void)copyLogDirectoryToDiagnosticsDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@LOG_DIR error:nil];
    NSString *logsDir = [dir stringByAppendingPathComponent:@"logs"];
    [fm createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in files) {
        if (![name hasSuffix:@".log"]) continue;
        [self copyPath:[@LOG_DIR stringByAppendingPathComponent:name]
      toDiagnosticsDir:logsDir
                  name:name];
    }
}

- (NSString *)createDiagnosticsArchive {
    if (self.diagnosticsEnabled) {
        enable_btstack_hci_logging();
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Library/Showcase/diagnostics";
    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *work = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ShowcaseDiagnostics-%@", stamp]];
    NSString *archive = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ShowcaseDiagnostics-%@.tar", stamp]];
    [fm removeItemAtPath:work error:nil];
    [fm removeItemAtPath:archive error:nil];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *commandsDir = [work stringByAppendingPathComponent:@"commands"];
    [fm createDirectoryAtPath:commandsDir withIntermediateDirectories:YES attributes:nil error:nil];

    const char *tarPaths[] = {
        "/var/jb/usr/bin/tar", "/var/jb/bin/tar", "/usr/bin/tar", "/bin/tar", NULL
    };
    const char *dpkgPaths[] = {
        "/var/jb/usr/bin/dpkg", "/var/jb/bin/dpkg", "/usr/bin/dpkg", "/bin/dpkg", NULL
    };
    const char *dpkgQueryPaths[] = {
        "/var/jb/usr/bin/dpkg-query", "/var/jb/bin/dpkg-query",
        "/usr/bin/dpkg-query", "/bin/dpkg-query", NULL
    };
    const char *unamePaths[] = {
        "/var/jb/usr/bin/uname", "/usr/bin/uname", "/bin/uname", NULL
    };
    const char *ifconfigPaths[] = {
        "/var/jb/sbin/ifconfig", "/sbin/ifconfig", "/usr/sbin/ifconfig", NULL
    };
    const char *psPaths[] = {
        "/var/jb/bin/ps", "/bin/ps", "/usr/bin/ps", NULL
    };
    const char *lsPaths[] = {
        "/var/jb/bin/ls", "/bin/ls", "/usr/bin/ls", NULL
    };

    const char *tarPath = first_existing_tool(tarPaths);
    const char *launchctl = launchctl_path();
    const char *dpkgPath = first_existing_tool(dpkgPaths);
    const char *dpkgQueryPath = first_existing_tool(dpkgQueryPaths);
    const char *unamePath = first_existing_tool(unamePaths);
    const char *ifconfigPath = first_existing_tool(ifconfigPaths);
    const char *psPath = first_existing_tool(psPaths);
    const char *lsPath = first_existing_tool(lsPaths);

    NSMutableString *env = [NSMutableString string];
    [env appendFormat:@"Showcase diagnostics\n"];
    [env appendFormat:@"version=%s\n", APP_VERSION];
    [env appendFormat:@"package=%@ jailbreak=%@\n", usage_values()[@"package"], usage_values()[@"jailbreak"]];
#ifdef SHOWCASE_ROOTLESS
    [env appendString:@"layout=rootless\n"];
#else
    [env appendString:@"layout=rootful\n"];
#endif
    [env appendFormat:@"uid=%u\n", getuid()];
    [env appendFormat:@"euid=%u\n", geteuid()];
    [env appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundlePath]];
    [env appendFormat:@"state=%ld\n", (long)self.state];
    [env appendFormat:@"selected_car=%@\n", self.cars.selected.name ?: @""];
    [env appendFormat:@"hotspot_ssid=%@\n", self.cars.apSSID ?: @""];
    [env appendFormat:@"launchctl=%s\n", launchctl ?: "(missing)"];
    [env appendFormat:@"tar=%s\n", tarPath ?: "(missing)"];
    [env appendFormat:@"dpkg=%s\n", dpkgPath ?: "(missing)"];
    [env appendFormat:@"dpkg_query=%s\n", dpkgQueryPath ?: "(missing)"];
    [env appendFormat:@"btdaemon=%s\n", BTDAEMON_PATH];
    [env appendFormat:@"btstack_plist=%s\n", BTSTACK_PLIST];
    [env appendFormat:@"btstack_socket=%s exists=%s\n",
                      BTSTACK_SOCKET, access(BTSTACK_SOCKET, F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"hci_dump=/tmp/hci_dump.pklg exists=%s\n",
                      access("/tmp/hci_dump.pklg", F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"tcpdump=%s\n", tcpdump_tool_path() ?: "(missing)"];
    [env appendFormat:@"latest_tcpdump=%@\n", [self latestNetworkDumpPath] ?: @"(none)"];
    [env appendFormat:@"diagnostics_enabled=%@\n", self.diagnosticsEnabled ? @"yes" : @"no"];
    [env appendFormat:@"helpers_full_logging_this_run=%@\n", self.helpersLoggedThisRun ? @"yes" : @"no"];
    [env appendFormat:@"bt_ready_sentinel=%s exists=%s\n",
                      BT_READY_PATH, access(BT_READY_PATH, F_OK) == 0 ? "yes" : "no"];
    [env writeToFile:[work stringByAppendingPathComponent:@"environment.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (!self.helpersLoggedThisRun) {
        NSString *warning = @"Diagnostics were enabled after this run or were disabled when helpers launched. Helper logs may be missing or limited. Reproduce once with diagnostics enabled before pressing Start.\n";
        [warning writeToFile:[work stringByAppendingPathComponent:@"WARNING.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    [self copyLogDirectoryToDiagnosticsDir:work];
    [self copyPath:@"/tmp/hci_dump.pklg" toDiagnosticsDir:work name:@"hci_dump.pklg"];
    [self copyPath:@SHOWCASE_BTSTACK_LOG_PATH toDiagnosticsDir:work name:@"BTstack.log"];
    [self copyPath:@TCPDUMP_LOG toDiagnosticsDir:work name:@"tcpdump.log"];
    /* Share's state and Apple's own Wi-Fi log, when present, explain most hotspot failures. */
    [self copyPath:@"/var/mobile/Library/Share/status.json" toDiagnosticsDir:work name:@"Share-status.json"];
    [self copyPath:@"/var/mobile/Library/Share/radio.json" toDiagnosticsDir:work name:@"Share-radio.json"];
    [self copyPath:@"/var/mobile/Documents/Share-Report.json" toDiagnosticsDir:work name:@"Share-Report.json"];
    [self copyPath:@"/tmp/wifi.log" toDiagnosticsDir:work name:@"wifi.log"];
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PREFS]
  toDiagnosticsDir:work name:@"ch.ringwald.btstack.plist"];
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PLIST]
  toDiagnosticsDir:work name:@"BTstack-launchdaemon.plist"];
    [self copyPath:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"]
  toDiagnosticsDir:work name:@"Showcase-Info.plist"];

    if (unamePath) {
        char *argv[] = { (char*)"uname", (char*)"-a", NULL };
        run_capture(unamePath, argv, [[commandsDir stringByAppendingPathComponent:@"uname-a.txt"] UTF8String]);
    }
    if (ifconfigPath) {
        char *argv[] = { (char*)"ifconfig", (char*)"-a", NULL };
        run_capture(ifconfigPath, argv, [[commandsDir stringByAppendingPathComponent:@"ifconfig-a.txt"] UTF8String]);
    }
    if (psPath) {
        char *argv[] = { (char*)"ps", (char*)"aux", NULL };
        run_capture(psPath, argv, [[commandsDir stringByAppendingPathComponent:@"ps-aux.txt"] UTF8String]);
    }
    if (dpkgPath) {
        char *argv2[] = { (char*)"dpkg", (char*)"-l", NULL };
        run_capture(dpkgPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-l.txt"] UTF8String]);
    }
    if (dpkgQueryPath) {
        char *argv1[] = { (char*)"dpkg-query", (char*)"-s", (char*)"com.rostane.showcase", NULL };
        run_capture(dpkgQueryPath, argv1, [[commandsDir stringByAppendingPathComponent:@"dpkg-showcase.txt"] UTF8String]);
        char *argv2[] = { (char*)"dpkg-query", (char*)"-W", NULL };
        run_capture(dpkgQueryPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-query-W.txt"] UTF8String]);
    }
    if (launchctl) {
        char *argv[] = { (char*)"launchctl", (char*)"list", NULL };
        run_capture(launchctl, argv, [[commandsDir stringByAppendingPathComponent:@"launchctl-list.txt"] UTF8String]);
    }
    if (lsPath) {
        char *argv1[] = { (char*)"ls", (char*)"-la", (char*)"/tmp", NULL };
        run_capture(lsPath, argv1, [[commandsDir stringByAppendingPathComponent:@"ls-tmp.txt"] UTF8String]);
        char *argv2[] = { (char*)"ls", (char*)"-la", (char*)BTDAEMON_PATH, NULL };
        run_capture(lsPath, argv2, [[commandsDir stringByAppendingPathComponent:@"ls-btdaemon.txt"] UTF8String]);
        char *argv3[] = { (char*)"ls", (char*)"-la", (char*)[[[NSBundle mainBundle] bundlePath] UTF8String], NULL };
        run_capture(lsPath, argv3, [[commandsDir stringByAppendingPathComponent:@"ls-app.txt"] UTF8String]);
    }

    if (!tarPath) {
        ip_log("diagnostics export failed: tar not found");
        return nil;
    }

    char *tarArgv[] = {
        (char*)"tar", (char*)"-cf", (char*)[archive UTF8String],
        (char*)"-C", (char*)[work UTF8String], (char*)".", NULL
    };
    int rc = run_blocking(tarPath, tarArgv);
    ip_log("diagnostics tar rc=%d path=%s", rc, [archive UTF8String]);
    return rc == 0 ? archive : nil;
}

/* ─── IPC listener ─────────────────────────────────────────── */

- (BOOL)startIPCListener {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        ip_log("bind: %s", strerror(errno));
        close(fd); return NO;
    }
    chmod(SOCK_PATH, 0777);
    listen(fd, 1);
    self.listenFd = fd;
    ip_log("IPC listening on %s", SOCK_PATH);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ [self ipcAcceptLoop]; });
    return YES;
}

- (void)ipcAcceptLoop {
    while (self.listenFd >= 0) {
        int c = accept(self.listenFd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        int noSigPipe = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSigPipe, sizeof(noSigPipe));
        ip_log("services connected");
        self.clientFd = c;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        g_touch_fd = c;
        [self ipcHandleConnection:c];
        g_touch_fd = -1;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        close(c);
        self.clientFd = -1;
        ip_log("services disconnected");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endAWDLSuppression];
        });
        /* CarPlay services exits when the iPhone ends the session or leaves
         * Wi-Fi, and when it fails while connecting. */
        if (self.state != StateIdle && self.state != StateStopping) {
            BOOL wasActive = self.state == StateActive;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (wasActive) {
                    ip_log("[SESSION] iPhone ended the session; waiting for it again");
                    self.restartAfterStop = YES;
                }
                [self stopFlow];
            });
            break;
        }
    }
}

static bool read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

- (void)ipcHandleConnection:(int)fd {
    CMFormatDescriptionRef fmtDesc = NULL;
    bool gotFirstFrame = false;
    uint64_t receivedFrameCount = 0;
    uint64_t lateFrameCount = 0;      /* slot already passed on arrival */
    uint64_t lateFrameCountAtReport = 0;
    double   latenessSumMs = 0;       /* magnitude is the metric, not count */
    double   latenessMaxMs = 0;
    uint64_t previousSenderTimestamp = 0;
    bool decodeOnlyCatchupActive = false;

    while (1) {
        uint8_t hdr[5];
        if (!read_exact(fd, hdr, 5)) break;
        uint32_t len = hdr[0] | (hdr[1]<<8) | (hdr[2]<<16) | (hdr[3]<<24);
        uint8_t type = hdr[4];
        if (len == 0 || len > 4*1024*1024) break;

        uint8_t *payload = malloc(len);
        if (!read_exact(fd, payload, len)) { free(payload); break; }

        if (type == MSG_VIDEO_CONFIG) {
            if (len < 9) { free(payload); continue; }
            float w, h;
            memcpy(&w, payload, 4); memcpy(&h, payload + 4, 4);
            g_carplay_w = w; g_carplay_h = h;
            ip_log("VideoConfig: %.0fx%.0f", w, h);

            const uint8_t *avcc = payload + 8;
            size_t avccLen = len - 8;
            if (avccLen >= 7) {
                size_t off = 5;
                const uint8_t *ps[2] = {NULL, NULL};
                size_t psSize[2] = {0, 0};
                int nSPS = avcc[off] & 0x1F; off++;
                if (nSPS > 0 && off + 2 <= avccLen) {
                    uint16_t sLen = (avcc[off]<<8) | avcc[off+1]; off += 2;
                    if (off + sLen <= avccLen) { ps[0] = avcc + off; psSize[0] = sLen; off += sLen; }
                }
                if (off < avccLen) {
                    int nPPS = avcc[off]; off++;
                    if (nPPS > 0 && off + 2 <= avccLen) {
                        uint16_t pLen = (avcc[off]<<8) | avcc[off+1]; off += 2;
                        if (off + pLen <= avccLen) { ps[1] = avcc + off; psSize[1] = pLen; }
                    }
                }
                if (ps[0] && ps[1]) {
                    if (fmtDesc) { CFRelease(fmtDesc); fmtDesc = NULL; }
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, psSize, 4, &fmtDesc);
                    /* A new parameter set means a new stream; the previous
                     * sender-timeline offset no longer describes it. */
                    video_clock_reset();
                    dispatch_async(self.videoQueue, ^{
                        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        [layer flush];
                        if (g_video_respect_timestamps)
                            video_install_timebase(layer);
                        else
                            layer.controlTimebase = NULL;
                    });
                    gotFirstFrame = false;
                    g_video_needs_resync = 1;
                    previousSenderTimestamp = 0;
                }
            }
            free(payload);

        } else if (type == MSG_VIDEO_FRAME) {
            if (!fmtDesc || len <= VIDEO_FRAME_METADATA_SIZE) {
                free(payload);
                continue;
            }
            uint64_t senderTimestamp = 0;
            memcpy(&senderTimestamp, payload, sizeof(senderTimestamp));
            BOOL isIDR = payload[8] != 0;
            uint32_t serviceSequence = 0;
            uint64_t serviceArrivalNanos = 0;
            uint32_t arrivalGapMicros = 0;
            uint32_t tcpPendingBytes = 0;
            uint32_t tcpReceiveWindow = 0;
            uint32_t tcpSmoothedRTT = 0;
            uint32_t tcpCurrentRTT = 0;
            uint32_t tcpFlags = 0;
            uint32_t decryptMicros = 0;
            memcpy(&serviceSequence, payload + 12, sizeof(serviceSequence));
            memcpy(&serviceArrivalNanos, payload + 16,
                   sizeof(serviceArrivalNanos));
            memcpy(&arrivalGapMicros, payload + 24,
                   sizeof(arrivalGapMicros));
            memcpy(&tcpPendingBytes, payload + 28,
                   sizeof(tcpPendingBytes));
            memcpy(&tcpReceiveWindow, payload + 32,
                   sizeof(tcpReceiveWindow));
            memcpy(&tcpSmoothedRTT, payload + 36,
                   sizeof(tcpSmoothedRTT));
            memcpy(&tcpCurrentRTT, payload + 40,
                   sizeof(tcpCurrentRTT));
            memcpy(&tcpFlags, payload + 44, sizeof(tcpFlags));
            memcpy(&decryptMicros, payload + 48, sizeof(decryptMicros));
            uint64_t appReadNanos = monotonic_nanos_now();
            double serviceToAppMs = serviceArrivalNanos > 0 &&
                appReadNanos >= serviceArrivalNanos
                ? (double)(appReadNanos - serviceArrivalNanos) / 1000000.0
                : -1.0;
            double senderSeconds =
                (double)senderTimestamp / 4294967296.0;
            double senderDeltaMs = NAN;
            if (previousSenderTimestamp != 0 &&
                senderTimestamp >= previousSenderTimestamp) {
                senderDeltaMs =
                    (double)(senderTimestamp - previousSenderTimestamp) /
                    4294967.296;
            }
            previousSenderTimestamp = senderTimestamp;
            double hostAtRead = video_host_now();
            double presentationAgeMs = NAN;
            if (senderTimestamp != 0 && g_video_timing_offset_valid) {
                presentationAgeMs =
                    (hostAtRead -
                     (senderSeconds + g_video_sender_to_host_offset)) * 1000.0;
            }
            if (arrivalGapMicros > 50000 || serviceSequence % 300 == 0 ||
                serviceToAppMs > 20.0) {
                ip_log("[VIDEO-TL] seq=%u gap=%.1fms serviceToApp=%.2fms "
                       "decrypt=%.2fms pending=%u rcvWnd=%u srtt=%ums "
                       "rtt=%ums tcpFlags=0x%x sender=%.6fs "
                       "senderDelta=%.1fms host=%.6fs ptsAge=%.1fms "
                       "timing=%d idr=%d",
                       serviceSequence,
                       (double)arrivalGapMicros / 1000.0, serviceToAppMs,
                       (double)decryptMicros / 1000.0, tcpPendingBytes,
                       tcpReceiveWindow, tcpSmoothedRTT, tcpCurrentRTT,
                       tcpFlags, senderSeconds, senderDeltaMs, hostAtRead,
                       presentationAgeMs,
                       (int)g_video_timing_offset_valid, isIDR ? 1 : 0);
            }
            const uint8_t *frameBytes =
                payload + VIDEO_FRAME_METADATA_SIZE;
            size_t frameLength = len - VIDEO_FRAME_METADATA_SIZE;

            if (g_video_suspended) {
                free(payload);
                continue;
            }

            if (g_video_needs_resync) {
                if (!isIDR) {
                    free(payload);
                    continue;
                }
                g_video_needs_resync = 0;
                decodeOnlyCatchupActive = false;
                ip_log("video resynchronized on IDR frame age=%.1fms",
                       presentationAgeMs);
            }

            /*
             * TCP preserves the H.264 dependency chain but can release it
             * hundreds of milliseconds late after a missing segment. Do not
             * flush that valid chain or request another large IDR over the
             * same congested path. AVSampleBufferDisplayLayer documents that
             * DoNotDisplay still decodes the sample, so feed stale frames to
             * the decoder without presenting them. The last current image
             * remains visible until the chain catches up.
             */
            double staleThresholdMs =
                MAX(VIDEO_STALE_RECOVERY_MIN_MS,
                    (double)g_video_target_latency_ms * 2.0);
            BOOL decodeOnlyCatchup =
                g_video_timing_offset_valid &&
                isfinite(presentationAgeMs) &&
                presentationAgeMs > staleThresholdMs &&
                isfinite(senderDeltaMs) &&
                senderDeltaMs <= 100.0;
            if (decodeOnlyCatchup && !decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = true;
                ip_log("video decode-only catch-up started seq=%u age=%.1fms "
                       "arrivalGap=%.1fms senderDelta=%.1fms",
                       serviceSequence, presentationAgeMs,
                       (double)arrivalGapMicros / 1000.0, senderDeltaMs);
            } else if (!decodeOnlyCatchup && decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = false;
                ip_log("video decode-only catch-up complete seq=%u age=%.1fms",
                       serviceSequence, presentationAgeMs);
            }

            if (!gotFirstFrame) {
                gotFirstFrame = true;
                [self completeConnectStep:ConnectStepVideo];
                [self transitionTo:StateActive];
                ip_log("first video frame");
                /* Deferred to here on purpose: pairing, iAP2 handoff and the
                 * whole RTSP negotiation have already completed, so radio
                 * suppression cannot influence them. */
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self beginAWDLSuppression];
                });
            }

            CMBlockBufferRef block = NULL;
            OSStatus st = CMBlockBufferCreateWithMemoryBlock(
                NULL, NULL, frameLength, kCFAllocatorDefault, NULL, 0,
                frameLength,
                kCMBlockBufferAssureMemoryNowFlag, &block);
            if (st == noErr) {
                CMBlockBufferReplaceDataBytes(frameBytes, block, 0,
                                              frameLength);
            }
            free(payload); payload = NULL;
            if (st != noErr || !block) continue;

            /* Schedule on the sender's timeline when it says its timestamps are
             * authoritative. A frame whose slot has already passed is still
             * enqueued, just immediately: dropping it would break the H.264
             * reference chain and corrupt every frame up to the next IDR. */
            BOOL scheduled = (g_video_respect_timestamps && senderTimestamp != 0);
            double displayHost = 0.0;
            if (scheduled) {
                bool missedSlot = false;
                double latenessSeconds = 0.0;
                displayHost = video_clock_schedule(senderTimestamp,
                                                   video_host_now(),
                                                   &missedSlot,
                                                   &latenessSeconds);
                if (missedSlot) {
                    lateFrameCount++;
                    double latenessMs = latenessSeconds * 1000.0;
                    latenessSumMs += latenessMs;
                    if (latenessMs > latenessMaxMs) latenessMaxMs = latenessMs;
                }
            }

            CMSampleTimingInfo timing;
            /* Follow the sender's real cadence — it drops to 30 Hz on
             * link-limited receivers, and a hardcoded 1/60 would retire each
             * frame half an interval early. */
            timing.duration = scheduled
                ? CMTimeMakeWithSeconds(g_video_frame_interval, 1000000)
                : CMTimeMake(1, 60);
            timing.presentationTimeStamp = scheduled
                ? CMTimeMakeWithSeconds(displayHost, 1000000)
                : kCMTimeInvalid;
            timing.decodeTimeStamp = kCMTimeInvalid;

            CMSampleBufferRef sample = NULL;
            const size_t sz = frameLength;
            st = CMSampleBufferCreateReady(NULL, block, fmtDesc, 1,
                                           1, &timing, 1, &sz, &sample);
            CFRelease(block);
            if (st != noErr || !sample) continue;

            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, true);
            if (att && CFArrayGetCount(att) > 0) {
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
                CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync,
                                     isIDR ? kCFBooleanFalse : kCFBooleanTrue);
                if (decodeOnlyCatchup)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DoNotDisplay,
                        kCFBooleanTrue);
                /* DisplayImmediately overrides the timebase, so it is only
                 * correct on the unscheduled path. */
                if (!scheduled)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DisplayImmediately,
                        kCFBooleanTrue);
            }

            uint64_t frameNumber = ++receivedFrameCount;
            uint64_t lateSoFar = lateFrameCount;
            uint64_t lateSinceReport = lateFrameCount - lateFrameCountAtReport;
            double lateMeanMs = lateSinceReport
                ? (latenessSumMs / (double)lateSinceReport) : 0.0;
            double lateMaxMs = latenessMaxMs;
            if (frameNumber % 300 == 0) {
                lateFrameCountAtReport = lateFrameCount;
                latenessSumMs = 0;
                latenessMaxMs = 0;
            }
            double clockOffset = g_video_clock_offset;
            double budgetMs = g_video_budget_seconds * 1000.0;
            BOOL scheduledFrame = scheduled;
            CFAbsoluteTime receivedAt = CFAbsoluteTimeGetCurrent();
            dispatch_async(self.videoQueue, ^{
                AVSampleBufferDisplayLayer *layer =
                    (AVSampleBufferDisplayLayer *)self.videoView.layer;
                if (layer.status ==
                    AVQueuedSampleBufferRenderingStatusFailed) {
                    ip_log("video renderer failed: %@",
                           layer.error.localizedDescription ?: @"unknown");
                    g_video_needs_resync = 1;
                    [layer flushAndRemoveImage];
                    send_video_resync_request();
                    CFRelease(sample);
                    return;
                }
                /* The timing message can arrive after the parameter sets, so
                 * confirm the timebase on the first scheduled frame too. */
                if (scheduledFrame && !layer.controlTimebase)
                    video_install_timebase(layer);
                [layer enqueueSampleBuffer:sample];
                if (frameNumber % 300 == 0) {
                    double queueDelayMs =
                        (CFAbsoluteTimeGetCurrent() - receivedAt) * 1000.0;
                    ip_log("video live #%llu: IPC→enqueue %.1fms ready=%d status=%ld "
                           "mode=%s late=%llu(+%llu/300 mean %.1fms max %.1fms) "
                           "budget=%.1fms offset=%.3fs",
                           frameNumber, queueDelayMs,
                           layer.readyForMoreMediaData,
                           (long)layer.status,
                           scheduledFrame ? "scheduled" : "immediate",
                           lateSoFar, lateSinceReport, lateMeanMs, lateMaxMs,
                           budgetMs, clockOffset);
                }
                CFRelease(sample);
            });
            continue;
        } else if (type == MSG_VIDEO_TIMING) {
            if (len >= sizeof(uint32_t)) {
                uint32_t latencyMs = 0;
                memcpy(&latencyMs, payload, sizeof(latencyMs));
                if (latencyMs >= 20 && latencyMs <= 500)
                    g_video_target_latency_ms = latencyMs;

                int32_t respect = g_video_respect_timestamps;
                if (len >= 5) respect = payload[4] ? 1 : 0;
                int32_t offsetValid = 0;
                double senderToHostOffset = 0.0;
                if (len >= 14) {
                    memcpy(&senderToHostOffset, payload + 5,
                           sizeof(senderToHostOffset));
                    offsetValid = payload[13] ? 1 : 0;
                }
                if (offsetValid != g_video_timing_offset_valid ||
                    (offsetValid &&
                     fabs(senderToHostOffset -
                          g_video_sender_to_host_offset) > 0.000001)) {
                    g_video_sender_to_host_offset = senderToHostOffset;
                    g_video_timing_offset_valid = offsetValid;
                    video_clock_reset();
                }
                if (respect != g_video_respect_timestamps) {
                    g_video_respect_timestamps = respect;
                    video_clock_reset();
                    dispatch_async(self.videoQueue, ^{
                        AVSampleBufferDisplayLayer *layer =
                            (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        if (respect) video_install_timebase(layer);
                        else layer.controlTimebase = NULL;
                    });
                }
                ip_log("screen presentation: latency=%u ms respectTimestamps=%d "
                       "timingOffset=%s%.3fms (%s)",
                       g_video_target_latency_ms,
                       (int)g_video_respect_timestamps,
                       g_video_timing_offset_valid ? "" : "unavailable/",
                       g_video_sender_to_host_offset * 1000.0,
                       g_video_respect_timestamps
                           ? (g_video_timing_offset_valid
                               ? "frames scheduled with synchronized NTP"
                               : "frames scheduled with arrival-clock fallback")
                           : "frames displayed on arrival");
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONFIG) {
            if (len >= 20) {
                uint32_t streamType = 0;
                uint64_t formatMask = 0;
                uint32_t framesPerPacket = 0;
                uint32_t latencyMs = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&formatMask, payload + 4, 8);
                memcpy(&framesPerPacket, payload + 12, 4);
                memcpy(&latencyMs, payload + 16, 4);
                NSNumber *key = @(streamType);
                CarPlayAudioPlayer *player = self.audioPlayers[key];
                if (!player) {
                    player = [[CarPlayAudioPlayer alloc]
                        initWithStreamType:streamType];
                    self.audioPlayers[key] = player;
                }
                ip_log("AudioConfig: stream=%u format=0x%llx "
                       "framesPerPacket=%u latency=%ums",
                       streamType, (unsigned long long)formatMask,
                       framesPerPacket, latencyMs);
                [player configureFormat:formatMask
                        framesPerPacket:framesPerPacket
                               latency:latencyMs];
            }
            free(payload);
        } else if (type == MSG_AUDIO_PACKET) {
            if (len > 12) {
                uint32_t streamType = 0;
                uint16_t sequence = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&sequence, payload + 4, 2);
                CarPlayAudioPlayer *player = self.audioPlayers[@(streamType)];
                [player enqueuePacket:payload + 12
                               length:len - 12
                             sequence:sequence];
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONTROL) {
            if (len >= 5) {
                uint32_t streamType = 0;
                memcpy(&streamType, payload, 4);
                uint8_t action = payload[4];
                CarPlayAudioPlayer *player =
                    self.audioPlayers[@(streamType)];
                if (action == AUDIO_CONTROL_PAUSE) {
                    [player setPlaybackPaused:YES];
                } else if (action == AUDIO_CONTROL_RESUME) {
                    [player setPlaybackPaused:NO];
                } else if (action == AUDIO_CONTROL_FLUSH) {
                    [player flushBufferedAudio];
                } else if (action == AUDIO_CONTROL_STOP) {
                    [player stop];
                    [self.audioPlayers removeObjectForKey:@(streamType)];
                    ip_log("audio stream %u stopped by sender teardown",
                           streamType);
                } else {
                    ip_log("audio stream %u unknown control=%u",
                           streamType, action);
                }
            }
            free(payload);
        } else if (type == MSG_BT_HANDOFF) {
            ip_log("[HANDOFF] services requested app-owned Bluetooth teardown");
            [self completeBluetoothHandoff];
            free(payload);
        } else if (type == MSG_STATUS) {
            if (len >= 1) {
                uint8_t code = payload[0];
                ip_log("MSG_STATUS code=0x%02X", code);
                switch (code) {
                    case STATUS_IPHONE_CONNECTED:
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    case STATUS_PAIR_SETUP_STARTED: {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (self.firstTimePairing) return;
                            self.firstTimePairing = YES;
                            if ([self isConnectingState]) [self renderState];
                        });
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    }
                    case STATUS_PAIR_SETUP_COMPLETE:
                    case STATUS_AUTH_COMPLETE:
                        [self completeConnectStep:ConnectStepJoinWiFi];
                        break;
                    case STATUS_PAIR_VERIFY_COMPLETE:
                    case STATUS_SESSION_SETUP:
                        [self completeConnectStep:ConnectStepPairing];
                        break;
                    case STATUS_STREAM_SETUP:
                        [self completeConnectStep:ConnectStepSession];
                        break;
                }
            }
            free(payload);
        } else {
            free(payload);
        }
    }
    if (fmtDesc) CFRelease(fmtDesc);
    for (CarPlayAudioPlayer *player in self.audioPlayers.allValues) {
        [player stop];
    }
    [self.audioPlayers removeAllObjects];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * SettingsViewController: one full-screen settings window
 *
 * Every page lives inside this one controller. Narrow screens push pages
 * with a back button; wide screens (iPad landscape) keep the section list in
 * a sidebar and show the selected page beside it. Nothing is stacked as a
 * second window except system share sheets.
 * ═══════════════════════════════════════════════════════════════ */

typedef void (^ShowcaseAction)(void);

static UIEdgeInsets showcase_safe_insets(UIView *view) {
    SEL selector = NSSelectorFromString(@"safeAreaInsets");
    if (view && [view respondsToSelector:selector]) {
        NSValue *value = [view valueForKey:@"safeAreaInsets"];
        if (value) return [value UIEdgeInsetsValue];
    }
    return UIEdgeInsetsZero;
}

/* Rows are controls, and a scroll view refuses to scroll from a control by
 * default. Allow it for everything except switches, whose thumb drags. */
@interface SettingsScrollView : UIScrollView
@end
@implementation SettingsScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return ![view isKindOfClass:[UISwitch class]];
}
@end

@interface SettingsRow : UIControl
@property (nonatomic, copy) ShowcaseAction action;
@end
@implementation SettingsRow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)fire { if (self.action && self.enabled) self.action(); }
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = (highlighted && self.action && self.enabled)
        ? [UIColor colorWithWhite:1 alpha:0.08] : [UIColor clearColor];
}
@end

@interface SettingsSwitch : UISwitch
@property (nonatomic, copy) void (^changed)(BOOL on);
@end
@implementation SettingsSwitch
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventValueChanged];
    }
    return self;
}
- (void)fire { if (self.changed) self.changed(self.on); }
@end

@interface SettingsSegments : UISegmentedControl
@property (nonatomic, copy) void (^changed)(NSInteger index);
@end
@implementation SettingsSegments
- (instancetype)initWithItems:(NSArray *)items {
    if ((self = [super initWithItems:items])) {
        [self addTarget:self action:@selector(fire)
       forControlEvents:UIControlEventValueChanged];
        if ([self respondsToSelector:@selector(setSelectedSegmentTintColor:)]) {
            [self setValue:[UIColor whiteColor] forKey:@"selectedSegmentTintColor"];
            [self setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]}
                                forState:UIControlStateSelected];
            [self setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]}
                                forState:UIControlStateNormal];
        }
    }
    return self;
}
- (void)fire { if (self.changed) self.changed(self.selectedSegmentIndex); }
@end

/* A rounded group of rows with hairline separators, as in iOS Settings but
 * drawn for Showcase's black canvas. */
@interface SettingsCard : UIView
@property (nonatomic, assign) CGFloat contentHeight;
- (void)addRow:(UIView *)row height:(CGFloat)height;
@end
@implementation SettingsCard
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
        self.layer.cornerRadius = 14;
        self.clipsToBounds = YES;
    }
    return self;
}
- (void)addRow:(UIView *)row height:(CGFloat)height {
    CGFloat W = self.bounds.size.width;
    if (self.contentHeight > 0) {
        CGFloat px = 1.0 / [UIScreen mainScreen].scale;
        UIView *line = [[UIView alloc] initWithFrame:
            CGRectMake(16, self.contentHeight, W - 16, px)];
        line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        [self addSubview:line];
    }
    row.frame = CGRectMake(0, self.contentHeight, W, height);
    [self addSubview:row];
    self.contentHeight += height;
    CGRect f = self.frame;
    f.size.height = self.contentHeight;
    self.frame = f;
}
@end

/* Where CarPlay sound comes out: this device on the left, the CarPlay
 * sender on the right. The active one is bright and carries sound waves.
 * Tapping a device selects it. */
@interface SoundRouteView : UIView
@property (nonatomic, assign) BOOL receiverActive;
@property (nonatomic, copy) void (^selected)(BOOL receiver);
- (void)setReceiverActive:(BOOL)active animated:(BOOL)animated;
@end

@interface SoundRouteView ()
@property (nonatomic, strong) UIView *senderGroup;
@property (nonatomic, strong) UIView *receiverGroup;
@property (nonatomic, strong) UIView *senderWaves;
@property (nonatomic, strong) UIView *receiverWaves;
@end

@implementation SoundRouteView

- (UIView *)deviceOutlineWithSize:(CGSize)size {
    UIView *outline = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, size.width, size.height)];
    outline.layer.borderColor = [UIColor whiteColor].CGColor;
    outline.layer.borderWidth = 2;
    outline.layer.cornerRadius = MIN(size.width, size.height) * 0.18;
    UIView *screen = [[UIView alloc] initWithFrame:
        CGRectInset(outline.bounds, 5, 7)];
    screen.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    screen.layer.cornerRadius = 3;
    [outline addSubview:screen];
    return outline;
}

- (UIView *)wavesView {
    UIView *waves = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 30)];
    for (int i = 0; i < 3; i++) {
        CAShapeLayer *arc = [CAShapeLayer layer];
        CGFloat r = 7 + i * 6;
        arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(0, 15)
            radius:r startAngle:-M_PI / 4 endAngle:M_PI / 4 clockwise:YES].CGPath;
        arc.strokeColor = [UIColor colorWithWhite:1 alpha:1.0 - i * 0.25].CGColor;
        arc.fillColor = [UIColor clearColor].CGColor;
        arc.lineWidth = 2;
        arc.lineCap = kCALineCapRound;
        [waves.layer addSublayer:arc];
    }
    return waves;
}

- (UIView *)groupWithOutline:(CGSize)size title:(NSString *)title
                       waves:(UIView **)wavesOut action:(SEL)action {
    UIView *group = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 140, 124)];
    UIView *outline = [self deviceOutlineWithSize:size];
    outline.frame = CGRectMake((140 - size.width) / 2.0, 92 - size.height,
                               size.width, size.height);
    [group addSubview:outline];
    UIView *waves = [self wavesView];
    waves.frame = CGRectMake(CGRectGetMaxX(outline.frame) + 6,
                             CGRectGetMidY(outline.frame) - 15, 26, 30);
    [group addSubview:waves];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, 140, 22)];
    label.text = title;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [group addSubview:label];
    [group addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:action]];
    group.accessibilityLabel = title;
    group.isAccessibilityElement = YES;
    group.accessibilityTraits = UIAccessibilityTraitButton;
    *wavesOut = waves;
    return group;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        BOOL pad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
        UIView *senderWaves = nil, *receiverWaves = nil;
        self.receiverGroup = [self groupWithOutline:
            (pad ? CGSizeMake(68, 86) : CGSizeMake(34, 62))
            title:[NSString stringWithFormat:L(@"This %@"), showcase_device_noun()]
            waves:&receiverWaves action:@selector(receiverTapped)];
        self.senderGroup = [self groupWithOutline:CGSizeMake(34, 62)
                                            title:L(@"CarPlay sender")
                                            waves:&senderWaves action:@selector(senderTapped)];
        self.senderWaves = senderWaves;
        self.receiverWaves = receiverWaves;
        [self addSubview:self.receiverGroup];
        [self addSubview:self.senderGroup];
        [self applyState];
    }
    return self;
}

- (void)receiverTapped { if (self.selected && !self.receiverActive) self.selected(YES); }
- (void)senderTapped { if (self.selected && self.receiverActive) self.selected(NO); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    CGFloat spacing = MIN(60.0, W / 8.0);
    CGFloat x = (W - (140 * 2 + spacing)) / 2.0;
    self.receiverGroup.frame = CGRectMake(x, 0, 140, 124);
    self.senderGroup.frame = CGRectMake(x + 140 + spacing, 0, 140, 124);
}

- (void)applyState {
    BOOL r = self.receiverActive;
    self.senderGroup.alpha = r ? 0.3 : 1.0;
    self.receiverGroup.alpha = r ? 1.0 : 0.3;
    self.senderWaves.hidden = r;
    self.receiverWaves.hidden = !r;
    self.receiverGroup.accessibilityTraits = UIAccessibilityTraitButton | (r ? UIAccessibilityTraitSelected : 0);
    self.senderGroup.accessibilityTraits = UIAccessibilityTraitButton | (r ? 0 : UIAccessibilityTraitSelected);
}

- (void)setReceiverActive:(BOOL)active animated:(BOOL)animated {
    _receiverActive = active;
    if (!animated) { [self applyState]; return; }
    [UIView transitionWithView:self duration:0.25
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ [self applyState]; } completion:nil];
}

@end

/* Builds one page top to bottom inside a fixed-width column. */
@interface SettingsPageBuilder : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, assign) CGFloat width;
@property (nonatomic, assign) CGFloat y;
@end
@implementation SettingsPageBuilder
- (CGFloat)heightOfText:(NSString *)text font:(UIFont *)font width:(CGFloat)w {
    if (!text.length) return 0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{ NSFontAttributeName: font } context:nil];
    return ceil(r.size.height);
}
- (UILabel *)labelText:(NSString *)text font:(UIFont *)font alpha:(CGFloat)alpha
                 inset:(CGFloat)inset gapAfter:(CGFloat)gap color:(UIColor *)color {
    CGFloat w = self.width - inset * 2;
    CGFloat h = [self heightOfText:text font:font width:w];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(inset, self.y, w, h)];
    l.text = text;
    l.font = font;
    l.numberOfLines = 0;
    l.textColor = color ?: [UIColor colorWithWhite:1 alpha:alpha];
    [self.container addSubview:l];
    self.y += h + gap;
    return l;
}
- (UILabel *)message:(NSString *)text color:(UIColor *)color {
    return [self labelText:text font:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]
                     alpha:1 inset:16 gapAfter:20 color:color];
}
- (SettingsCard *)card:(void (^)(SettingsCard *card))fill {
    SettingsCard *card = [[SettingsCard alloc] initWithFrame:
        CGRectMake(0, self.y, self.width, 0)];
    fill(card);
    [self.container addSubview:card];
    self.y += card.contentHeight + 12;
    return card;
}
- (void)place:(UIView *)view height:(CGFloat)height gapAfter:(CGFloat)gap {
    view.frame = CGRectMake(0, self.y, self.width, height);
    [self.container addSubview:view];
    self.y += height + gap;
}
- (void)gap:(CGFloat)gap { self.y += gap; }
@end

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *stack;
@property (nonatomic, strong) SettingsScrollView *sidebarScroll;
@property (nonatomic, strong) SettingsScrollView *detailScroll;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, assign) BOOL wide;
@property (nonatomic, assign) CGSize renderedSize;
@property (nonatomic, assign) CGFloat keyboardOverlap;
@property (nonatomic, weak) UITextField *activeField;

/* page state */
@property (nonatomic, strong) Car *editingCar;
@property (nonatomic, weak) UITextField *carNameField;
@property (nonatomic, weak) UITextField *ssidField;
@property (nonatomic, weak) UITextField *passwordField;
@property (nonatomic, copy) NSString *pageMessage;
@property (nonatomic, assign) BOOL pageMessageIsError;
@property (nonatomic, assign) BOOL confirmingDestructive;
@property (nonatomic, assign) BOOL preparingLogs;
@property (nonatomic, assign) BOOL passwordVisible;
@property (nonatomic, weak) SoundRouteView *soundRoute;
@property (nonatomic, copy) NSString *draftCarName;
@property (nonatomic, copy) NSString *draftSSID;
@property (nonatomic, copy) NSString *draftPassword;
@property (nonatomic, assign) CGFloat fieldTitleWidth;
@end

static NSDictionary<NSString *, NSString *> *g_settings_hardware_info = nil;
static BOOL g_settings_hardware_loading = NO;

@implementation SettingsViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.stack = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillHide:)
        name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!CGSizeEqualToSize(self.renderedSize, self.view.bounds.size)) {
        BOOL wasEmpty = self.stack.count == 0;
        self.renderedSize = self.view.bounds.size;
        self.wide = self.view.bounds.size.width >= 900 &&
                    self.view.bounds.size.height >= 600;
        if (wasEmpty) {
            if (self.initialPage.length) {
                if (!self.wide) [self.stack addObject:@"root"];
                [self.stack addObject:self.initialPage];
            } else {
                [self.stack addObject:self.wide ? @"cars" : @"root"];
            }
        } else if (self.wide && [self.stack.firstObject isEqualToString:@"root"]) {
            [self.stack removeObjectAtIndex:0];
            if (self.stack.count == 0) [self.stack addObject:@"cars"];
        } else if (!self.wide && ![self.stack.firstObject isEqualToString:@"root"]) {
            [self.stack insertObject:@"root" atIndex:0];
        }
        [self render];
    }
}

- (AppDelegate *)app { return self.appDelegate; }

- (BOOL)sessionRunning {
    ShowcaseState s = self.appDelegate.state;
    return s != StateIdle && s != StateStopping;
}

- (NSString *)titleForPage:(NSString *)page {
    if ([page isEqualToString:@"root"]) return L(@"Settings");
    if ([page isEqualToString:@"cars"]) return L(@"Cars");
    if ([page isEqualToString:@"car"]) return self.editingCar ? L(@"Edit Car") : L(@"New Car");
    if ([page isEqualToString:@"hotspot"]) return L(@"Hotspot");
    if ([page isEqualToString:@"sound"]) return L(@"Sound");
    if ([page isEqualToString:@"display"]) return L(@"Display");
    if ([page isEqualToString:@"resolution"]) return L(@"Resolution");
    if ([page isEqualToString:@"language"]) return L(@"Language");
    if ([page isEqualToString:@"logs"]) return L(@"Troubleshooting");
    if ([page isEqualToString:@"usage"]) return L(@"Anonymous Usage");
    if ([page isEqualToString:@"about"]) return L(@"About");
    return L(@"Settings");
}

/* ─── navigation ─── */

- (void)clearDrafts {
    self.draftCarName = nil;
    self.draftSSID = nil;
    self.draftPassword = nil;
    self.carNameField = nil;
    self.ssidField = nil;
    self.passwordField = nil;
}

- (void)push:(NSString *)page {
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    [self.stack addObject:page];
    [self render];
}

- (void)pop {
    if (self.stack.count <= 1) return;
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    [self.stack removeLastObject];
    [self render];
}

- (void)selectSection:(NSString *)page {
    [self clearDrafts];
    self.pageMessage = nil;
    self.confirmingDestructive = NO;
    [self.view endEditing:YES];
    if (self.wide) {
        [self.stack removeAllObjects];
        [self.stack addObject:page];
        [self render];
    } else {
        [self push:page];
    }
}

- (void)close {
    [self.view endEditing:YES];
    AppDelegate *app = self.appDelegate;
    [self dismissViewControllerAnimated:YES completion:^{
        [app settingsDidClose];
    }];
}

- (void)refresh {
    if (!self.isViewLoaded || self.stack.count == 0) return;
    if (self.activeField.isFirstResponder) return;
    [self render];
}

/* ─── rendering ─── */

- (UIButton *)headerButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)render {
    UIEdgeInsets safe = showcase_safe_insets(self.view);
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    BOOL phone = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
    CGFloat left = MAX(safe.left, phone ? 12 : 20);
    CGFloat right = MAX(safe.right, phone ? 12 : 20);
    CGFloat headerH = phone ? 56 : 68;

    /* Rebuilding replaces every field; keep what the user has typed. */
    if (self.carNameField) self.draftCarName = self.carNameField.text;
    if (self.ssidField) self.draftSSID = self.ssidField.text;
    if (self.passwordField) self.draftPassword = self.passwordField.text;
    CGPoint previousOffset = self.detailScroll.contentOffset;
    NSString *previousPage = objc_getAssociatedObject(self.detailScroll, "page");
    [self.header removeFromSuperview];
    [self.sidebarScroll removeFromSuperview];
    [self.detailScroll removeFromSuperview];
    self.sidebarScroll = nil;

    NSString *page = self.stack.lastObject;
    CGFloat sidebarW = self.wide ? 320 : 0;
    self.fieldTitleWidth = 0;

    /* Header */
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, safe.top, W, headerH)];
    [self.view addSubview:self.header];

    CGFloat closeSz = phone ? 34 : 40;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - right - closeSz, (headerH - closeSz) / 2.0, closeSz, closeSz);
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    close.layer.cornerRadius = closeSz / 2.0;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
    close.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    close.accessibilityLabel = L(@"Close");
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:close];

    CGFloat detailX = self.wide ? left + sidebarW : 0;
    CGFloat detailW = W - detailX;
    UILabel *title = [[UILabel alloc] initWithFrame:
        CGRectMake(detailX + 90, 0, detailW - 180, headerH)];
    title.text = [self titleForPage:page];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.header addSubview:title];

    if (self.wide) {
        UILabel *settingsTitle = [[UILabel alloc] initWithFrame:
            CGRectMake(left + 16, 0, sidebarW - 16, headerH)];
        settingsTitle.text = L(@"Settings");
        settingsTitle.textColor = [UIColor whiteColor];
        settingsTitle.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
        [self.header addSubview:settingsTitle];
    }
    if (self.stack.count > 1) {
        NSString *previous = [self titleForPage:self.stack[self.stack.count - 2]];
        UIButton *back = [self headerButtonWithTitle:
            [NSString stringWithFormat:@"‹  %@", previous] action:@selector(pop)];
        back.frame = CGRectMake((self.wide ? detailX + 8 : left), 0, 150, headerH);
        back.titleLabel.adjustsFontSizeToFitWidth = YES;
        back.titleLabel.minimumScaleFactor = 0.7;
        [self.header addSubview:back];
    }

    CGFloat top = safe.top + headerH;
    CGFloat bottomPad = MAX(safe.bottom, 16);

    /* Sidebar */
    if (self.wide) {
        self.sidebarScroll = [[SettingsScrollView alloc] initWithFrame:
            CGRectMake(left, top, sidebarW, H - top)];
        self.sidebarScroll.delaysContentTouches = NO;
        self.sidebarScroll.alwaysBounceVertical = YES;
        self.sidebarScroll.showsVerticalScrollIndicator = NO;
        [self.view addSubview:self.sidebarScroll];
        SettingsPageBuilder *b = [[SettingsPageBuilder alloc] init];
        b.container = self.sidebarScroll;
        b.width = sidebarW - 16;
        b.y = 12;
        [self buildRoot:b selected:self.stack.firstObject];
        self.sidebarScroll.contentSize = CGSizeMake(sidebarW, b.y + bottomPad);
    }

    /* Detail */
    self.detailScroll = [[SettingsScrollView alloc] initWithFrame:
        CGRectMake(detailX, top, detailW, H - top)];
    self.detailScroll.delaysContentTouches = NO;
    self.detailScroll.alwaysBounceVertical = YES;
    self.detailScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.detailScroll];

    CGFloat innerLeft = self.wide ? 24 : left;
    CGFloat innerRight = right;
    CGFloat colW = MIN(detailW - innerLeft - innerRight, 600);
    UIView *column = [[UIView alloc] initWithFrame:
        CGRectMake(innerLeft + floor((detailW - innerLeft - innerRight - colW) / 2.0), 0, colW, 0)];
    [self.detailScroll addSubview:column];

    SettingsPageBuilder *b = [[SettingsPageBuilder alloc] init];
    b.container = column;
    b.width = colW;
    b.y = 12;
    if ([page isEqualToString:@"root"]) [self buildRoot:b selected:nil];
    else if ([page isEqualToString:@"cars"]) [self buildCars:b];
    else if ([page isEqualToString:@"car"]) [self buildCar:b];
    else if ([page isEqualToString:@"hotspot"]) [self buildHotspot:b];
    else if ([page isEqualToString:@"sound"]) [self buildSound:b];
    else if ([page isEqualToString:@"display"]) [self buildDisplay:b];
    else if ([page isEqualToString:@"resolution"]) [self buildResolution:b];
    else if ([page isEqualToString:@"language"]) [self buildLanguage:b];
    else if ([page isEqualToString:@"logs"]) [self buildLogs:b];
    else if ([page isEqualToString:@"usage"]) [self buildUsage:b];
    else if ([page isEqualToString:@"about"]) [self buildAbout:b];
    CGRect cf = column.frame;
    cf.size.height = b.y;
    column.frame = cf;
    self.detailScroll.contentSize = CGSizeMake(detailW, b.y + bottomPad);
    self.detailScroll.contentInset = UIEdgeInsetsMake(0, 0, self.keyboardOverlap, 0);
    objc_setAssociatedObject(self.detailScroll, "page", page, OBJC_ASSOCIATION_COPY);
    if ([previousPage isEqualToString:page]) {
        CGFloat maxY = MAX(0, self.detailScroll.contentSize.height -
                              self.detailScroll.bounds.size.height + self.keyboardOverlap);
        self.detailScroll.contentOffset = CGPointMake(0, MIN(previousOffset.y, maxY));
    }
}

/* ─── row factories ─── */

- (UILabel *)rowTitle:(NSString *)text frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    return l;
}

- (SettingsRow *)navRow:(NSString *)title value:(NSString *)value
                  width:(CGFloat)w selected:(BOOL)selected
                 action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    if (selected) {
        UIView *bg = [[UIView alloc] initWithFrame:row.bounds];
        bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        bg.userInteractionEnabled = NO;
        [row addSubview:bg];
    }
    /* The title keeps its full width; the value takes what is left. */
    UILabel *titleLabel = [self rowTitle:title frame:CGRectZero];
    CGFloat titleW = MIN(ceil([titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 52)].width),
                         w - 16 - 34 - 40);
    titleLabel.frame = CGRectMake(16, 0, titleW, 52);
    [row addSubview:titleLabel];
    CGFloat valueX = 16 + titleW + 12;
    CGFloat valueW = MAX(0, w - 30 - valueX);
    UILabel *v = [[UILabel alloc] initWithFrame:
        CGRectMake(valueX, 0, valueW, 52)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:v];
    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(w - 26, 0, 14, 52)];
    chevron.text = @"›";
    chevron.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    chevron.font = [UIFont systemFontOfSize:24 weight:UIFontWeightLight];
    [row addSubview:chevron];
    return row;
}

- (SettingsRow *)actionRow:(NSString *)title color:(UIColor *)color
                     width:(CGFloat)w enabled:(BOOL)enabled
                    action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    row.enabled = enabled;
    UILabel *l = [self rowTitle:title frame:CGRectMake(16, 0, w - 32, 52)];
    l.textColor = enabled ? (color ?: [UIColor whiteColor])
                          : [UIColor colorWithWhite:1 alpha:0.3];
    [row addSubview:l];
    return row;
}

- (UIView *)valueRow:(NSString *)title value:(NSString *)value width:(CGFloat)w {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 48)];
    [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, w * 0.45, 48)]];
    UILabel *v = [[UILabel alloc] initWithFrame:
        CGRectMake(w * 0.45, 0, w * 0.55 - 16, 48)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    v.adjustsFontSizeToFitWidth = YES;
    v.minimumScaleFactor = 0.75;
    [row addSubview:v];
    return row;
}

- (CGFloat)switchRowHeightWithSubtitle:(NSString *)subtitle width:(CGFloat)w {
    if (!subtitle.length) return 52;
    CGRect r = [subtitle boundingRectWithSize:CGSizeMake(w - 16 - 84, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13] }
        context:nil];
    return 40 + ceil(r.size.height) + 12;
}

- (UIView *)switchRow:(NSString *)title subtitle:(NSString *)subtitle
                   on:(BOOL)on width:(CGFloat)w
              changed:(void (^)(BOOL on))changed {
    CGFloat h = [self switchRowHeightWithSubtitle:subtitle width:w];
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    CGFloat textW = w - 16 - 84;
    [row addSubview:[self rowTitle:title
        frame:CGRectMake(16, subtitle.length ? 10 : 0, textW, subtitle.length ? 26 : h)]];
    if (subtitle.length) {
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 38, textW, h - 50)];
        s.text = subtitle;
        s.numberOfLines = 0;
        s.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        s.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        [row addSubview:s];
    }
    SettingsSwitch *sw = [[SettingsSwitch alloc] init];
    sw.on = on;
    sw.changed = changed;
    CGSize ss = sw.intrinsicContentSize;
    if (ss.width <= 0) ss = CGSizeMake(51, 31);
    sw.frame = CGRectMake(w - 16 - ss.width,
        subtitle.length ? 13 : (h - ss.height) / 2.0, ss.width, ss.height);
    [row addSubview:sw];
    return row;
}

- (SettingsRow *)choiceRow:(NSString *)title value:(NSString *)value checked:(BOOL)checked
                     width:(CGFloat)w action:(ShowcaseAction)action {
    SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    row.action = action;
    [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, w * 0.5, 52)]];
    UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(w * 0.5, 0, w * 0.5 - 52, 52)];
    v.text = value;
    v.textAlignment = NSTextAlignmentRight;
    v.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    v.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    [row addSubview:v];
    UILabel *check = [[UILabel alloc] initWithFrame:CGRectMake(w - 40, 0, 24, 52)];
    check.text = checked ? @"✓" : @"";
    check.textColor = [UIColor whiteColor];
    check.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [row addSubview:check];
    if (checked) row.accessibilityTraits |= UIAccessibilityTraitSelected;
    return row;
}

- (UIView *)segmentRow:(NSString *)title items:(NSArray<NSString *> *)items selected:(NSInteger)selected
                 width:(CGFloat)w enabled:(BOOL)enabled changed:(void (^)(NSInteger index))changed {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, w * 0.5, 52)]];
    SettingsSegments *segments = [[SettingsSegments alloc] initWithItems:items];
    segments.selectedSegmentIndex = MIN(selected, (NSInteger)items.count - 1);
    segments.tintColor = [UIColor whiteColor];
    segments.enabled = enabled;
    segments.changed = changed;
    CGFloat segmentW = 56.0 * items.count;
    segments.frame = CGRectMake(w - 16 - segmentW, 11, segmentW, 30);
    [row addSubview:segments];
    row.alpha = enabled ? 1 : 0.35;
    return row;
}

/* Field titles share one column: the widest title, at least 100 points. */
- (CGFloat)titleWidthFor:(NSArray<NSString *> *)titles {
    CGFloat widest = 100;
    UIFont *font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    for (NSString *title in titles)
        widest = MAX(widest, ceil([title sizeWithAttributes:@{NSFontAttributeName: font}].width) + 8);
    return widest;
}

- (UITextField *)fieldRowInCard:(SettingsCard *)card title:(NSString *)title
                           text:(NSString *)text placeholder:(NSString *)placeholder
                         secure:(BOOL)secure trailing:(UIView *)trailing {
    CGFloat w = card.bounds.size.width;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    CGFloat fieldX = 16;
    if (title.length) {
        CGFloat titleW = self.fieldTitleWidth ?: [self titleWidthFor:@[title]];
        [row addSubview:[self rowTitle:title frame:CGRectMake(16, 0, titleW, 52)]];
        fieldX = 16 + titleW + 4;
    }
    CGFloat trailingW = trailing ? trailing.bounds.size.width + 8 : 0;
    UITextField *field = [[UITextField alloc] initWithFrame:
        CGRectMake(fieldX, 0, w - fieldX - 16 - trailingW, 52)];
    field.text = text;
    field.textColor = [UIColor whiteColor];
    field.tintColor = [UIColor whiteColor];
    field.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    field.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:placeholder ?: @""
            attributes:@{ NSForegroundColorAttributeName:
                              [UIColor colorWithWhite:1 alpha:0.3] }];
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    [row addSubview:field];
    if (trailing) {
        trailing.frame = CGRectMake(w - 16 - trailing.bounds.size.width,
            (52 - trailing.bounds.size.height) / 2.0,
            trailing.bounds.size.width, trailing.bounds.size.height);
        [row addSubview:trailing];
    }
    [card addRow:row height:52];
    return field;
}

- (UIButton *)pillButton:(NSString *)title action:(SEL)action width:(CGFloat)w {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, w, 50);
    b.backgroundColor = [UIColor whiteColor];
    b.layer.cornerRadius = 25;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)placePill:(UIButton *)pill builder:(SettingsPageBuilder *)b {
    UIView *holder = [[UIView alloc] init];
    [b place:holder height:50 gapAfter:20];
    pill.frame = CGRectMake(0, 0, b.width, 50);
    [holder addSubview:pill];
}

- (void)showPageMessage:(SettingsPageBuilder *)b {
    if (!self.pageMessage.length) return;
    [b message:self.pageMessage
         color:self.pageMessageIsError
            ? [UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1]
            : [UIColor colorWithRed:0.45 green:0.86 blue:0.55 alpha:1]];
}

- (void)setMessage:(NSString *)message error:(BOOL)error {
    self.pageMessage = message;
    self.pageMessageIsError = error;
    [self render];
}

- (UIColor *)destructiveColor {
    return [UIColor colorWithRed:1.0 green:0.38 blue:0.35 alpha:1];
}

- (void)armDestructiveConfirmation {
    self.confirmingDestructive = YES;
    [self render];
    __weak SettingsViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!weakSelf.confirmingDestructive) return;
        weakSelf.confirmingDestructive = NO;
        [weakSelf render];
    });
}

/* ─── pages ─── */

- (void)buildRoot:(SettingsPageBuilder *)b selected:(NSString *)selected {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL receiverAudio = [d boolForKey:RECEIVER_AUDIO_KEY];

    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Cars") value:app.cars.selected.name ?: @""
            width:w selected:[selected isEqualToString:@"cars"]
            action:^{ [weakSelf selectSection:@"cars"]; }] height:52];
        [card addRow:[self navRow:L(@"Hotspot")
            value:app.cars.apSSID.length ? app.cars.apSSID : L(@"Not set")
            width:w selected:[selected isEqualToString:@"hotspot"]
            action:^{ [weakSelf selectSection:@"hotspot"]; }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Sound")
            value:receiverAudio
                ? [NSString stringWithFormat:L(@"This %@"), showcase_device_noun()]
                : L(@"CarPlay sender")
            width:w selected:[selected isEqualToString:@"sound"]
            action:^{ [weakSelf selectSection:@"sound"]; }] height:52];
        [card addRow:[self navRow:L(@"Display") value:@""
            width:w selected:[selected isEqualToString:@"display"]
            action:^{ [weakSelf selectSection:@"display"]; }] height:52];
        [card addRow:[self navRow:L(@"Language") value:showcase_language_name(showcase_language())
            width:w selected:[selected isEqualToString:@"language"]
            action:^{ [weakSelf selectSection:@"language"]; }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self navRow:L(@"Troubleshooting")
            value:app.diagnosticsEnabled ? L(@"Logging on") : @""
            width:w selected:[selected isEqualToString:@"logs"]
            action:^{ [weakSelf selectSection:@"logs"]; }] height:52];
        [card addRow:[self navRow:L(@"Anonymous Usage")
            value:[[NSUserDefaults standardUserDefaults] boolForKey:USAGE_KEY] ? L(@"On") : L(@"Off")
            width:w selected:[selected isEqualToString:@"usage"]
            action:^{ [weakSelf selectSection:@"usage"]; }] height:52];
        [card addRow:[self navRow:L(@"About") value:@""
            width:w selected:[selected isEqualToString:@"about"]
            action:^{ [weakSelf selectSection:@"about"]; }] height:52];
    }];
    if (self.sessionRunning) {
        [b card:^(SettingsCard *card) {
            [card addRow:[self actionRow:L(@"Stop CarPlay") color:[self destructiveColor]
                width:w enabled:YES action:^{
                    AppDelegate *strongApp = weakSelf.appDelegate;
                    [weakSelf close];
                    [strongApp stopFlow];
                }] height:52];
        }];
    }
}

- (void)buildCars:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    [b card:^(SettingsCard *card) {
        for (Car *car in app.cars.cars) {
            BOOL isSelected = car == app.cars.selected;
            SettingsRow *row = [[SettingsRow alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
            row.action = ^{
                [app.cars selectCar:car];
                [app renderState];
                [weakSelf render];
            };
            [row addSubview:[self rowTitle:car.name frame:CGRectMake(16, 0, w - 130, 52)]];
            if (isSelected) {
                UIView *check = showcase_check_badge(22, [UIColor whiteColor], [UIColor blackColor]);
                check.frame = CGRectMake(w - 104, 15, 22, 22);
                [row addSubview:check];
            }
            UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
            edit.frame = CGRectMake(w - 70, 8, 60, 36);
            [edit setTitle:L(@"Edit") forState:UIControlStateNormal];
            edit.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
            edit.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            objc_setAssociatedObject(edit, "car", car, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [edit addTarget:self action:@selector(editCarTapped:)
           forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:edit];
            [card addRow:row height:52];
        }
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:L(@"Add Car") color:nil width:w enabled:YES action:^{
            weakSelf.editingCar = nil;
            [weakSelf push:@"car"];
        }] height:52];
    }];
}

- (void)editCarTapped:(UIButton *)sender {
    self.editingCar = objc_getAssociatedObject(sender, "car");
    [self push:@"car"];
}

- (void)buildCar:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    Car *car = self.editingCar;
    [b card:^(SettingsCard *card) {
        self.carNameField = [self fieldRowInCard:card title:L(@"Name")
            text:self.draftCarName ?: car.name placeholder:@"Miata"
            secure:NO trailing:nil];
        self.carNameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
        self.carNameField.returnKeyType = UIReturnKeyDone;
    }];
    [b gap:8];
    [self showPageMessage:b];
    [self placePill:[self pillButton:L(@"Save") action:@selector(saveCar) width:w] builder:b];

    if (car && car != app.cars.selected) {
        [b card:^(SettingsCard *card) {
            [card addRow:[self actionRow:L(@"Use This Car") color:nil width:w enabled:YES action:^{
                [app.cars selectCar:car];
                [app renderState];
                [weakSelf pop];
            }] height:52];
        }];
    }
    if (car && app.cars.cars.count > 1) {
        [b card:^(SettingsCard *card) {
            [card addRow:[self actionRow:
                self.confirmingDestructive ? L(@"Tap Again to Delete") : L(@"Delete Car")
                color:[self destructiveColor] width:w enabled:YES action:^{
                    if (!weakSelf.confirmingDestructive) {
                        [weakSelf armDestructiveConfirmation];
                        return;
                    }
                    weakSelf.confirmingDestructive = NO;
                    NSInteger index = [app.cars.cars indexOfObject:car];
                    if (index != NSNotFound) [app.cars deleteCarAtIndex:index];
                    [app renderState];
                    [weakSelf pop];
                }] height:52];
        }];
    }
}

- (void)saveCar {
    AppDelegate *app = self.appDelegate;
    NSString *name = [self.carNameField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *error = nil;
    if (name.length == 0) error = L(@"Enter a name for the car.");
    else if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 31)
        error = L(@"Use a shorter name. CarPlay allows up to 31 characters.");
    else {
        for (Car *other in app.cars.cars) {
            if (other != self.editingCar &&
                [other.name caseInsensitiveCompare:name] == NSOrderedSame) {
                error = L(@"Another car already uses this name.");
                break;
            }
        }
    }
    if (error) { [self setMessage:error error:YES]; return; }
    [self.view endEditing:YES];
    if (self.editingCar) {
        BOOL wasSelected = self.editingCar == app.cars.selected;
        self.editingCar.name = name;
        if (wasSelected) [app.cars selectCar:self.editingCar];
        else [app.cars save];
    } else {
        Car *car = [[Car alloc] init];
        car.name = name;
        [app.cars addCar:car];
        [app.cars selectCar:car];
    }
    [app renderState];
    [self pop];
}

- (void)buildHotspot:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    UIButton *show = [UIButton buttonWithType:UIButtonTypeSystem];
    [show setTitle:self.passwordVisible ? L(@"Hide") : L(@"Show") forState:UIControlStateNormal];
    show.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    show.titleLabel.font = [UIFont systemFontOfSize:15];
    /* Wide enough for either word, so the field does not move on toggle. */
    NSDictionary *font = @{NSFontAttributeName: show.titleLabel.font};
    CGFloat showW = MAX([L(@"Hide") sizeWithAttributes:font].width, [L(@"Show") sizeWithAttributes:font].width);
    show.frame = CGRectMake(0, 0, MAX(52, ceil(showW) + 12), 32);
    self.fieldTitleWidth = [self titleWidthFor:@[L(@"Name"), L(@"Password")]];
    [show addTarget:self action:@selector(togglePasswordVisible)
   forControlEvents:UIControlEventTouchUpInside];
    NSString *ssid = self.draftSSID ?: app.cars.apSSID;
    NSString *password = self.draftPassword ?: app.cars.apPassword;
    [b card:^(SettingsCard *card) {
        self.ssidField = [self fieldRowInCard:card title:L(@"Name") text:ssid
            placeholder:@"Carplay-Receiver" secure:NO trailing:nil];
        self.ssidField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.ssidField.returnKeyType = UIReturnKeyNext;
        self.passwordField = [self fieldRowInCard:card title:L(@"Password") text:password
            placeholder:L(@"8 characters or more") secure:!self.passwordVisible trailing:show];
        self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.passwordField.returnKeyType = UIReturnKeyDone;
    }];
    [b gap:8];
    [self showPageMessage:b];
    [self placePill:[self pillButton:L(@"Save") action:@selector(saveHotspot) width:w] builder:b];

    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:[NSString stringWithFormat:L(@"Rename This %@"), showcase_device_noun()]
            color:nil width:w enabled:YES action:^{
            NSURL *u = [NSURL URLWithString:@"App-Prefs:root=General&path=About"];
            UIApplication *a = [UIApplication sharedApplication];
            if (![a canOpenURL:u]) u = [NSURL URLWithString:@"prefs:root=General&path=About"];
            [a openURL:u options:@{} completionHandler:nil];
        }] height:52];
    }];
}

- (void)togglePasswordVisible {
    self.passwordVisible = !self.passwordVisible;
    [self render];
}

- (void)saveHotspot {
    AppDelegate *app = self.appDelegate;
    NSString *ssid = [self.ssidField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *pass = self.passwordField.text ?: @"";
    NSString *error = validateSSID(ssid);
    if (!error && pass.length < 8)
        error = L(@"Hotspot passwords must be at least 8 characters.");
    [self.view endEditing:YES];
    if (error) { [self setMessage:error error:YES]; return; }
    [app.cars setAPSSID:ssid password:pass];
    [app renderState];
    NSString *deviceName = hotspot_name();
    if (deviceName && ![deviceName isEqualToString:ssid]) {
        [self setMessage:[NSString stringWithFormat:
            L(@"Saved, but this iPad's hotspot is called \u201c%@\u201d. Your iPhone can't join until the names match."),
            deviceName] error:YES];
        return;
    }
    [self setMessage:L(@"Saved.") error:NO];
}

- (void)buildSound:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    BOOL receiverAudio = [[NSUserDefaults standardUserDefaults] boolForKey:RECEIVER_AUDIO_KEY];
    void (^choose)(BOOL) = ^(BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:RECEIVER_AUDIO_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ip_log("settings: receiver audio %s", on ? "on" : "off");
        [weakSelf.soundRoute setReceiverActive:on animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf render]; });
    };

    [b gap:16];
    SoundRouteView *route = [[SoundRouteView alloc] initWithFrame:CGRectMake(0, 0, w, 124)];
    [route setReceiverActive:receiverAudio animated:NO];
    route.selected = choose;
    [b place:route height:124 gapAfter:28];
    self.soundRoute = route;

    [b card:^(SettingsCard *card) {
        UIView *row = [self switchRow:[NSString stringWithFormat:L(@"Play Sound on This %@"), showcase_device_noun()]
            subtitle:nil on:receiverAudio width:w changed:choose];
        [card addRow:row height:row.bounds.size.height];
    }];
}

- (NSString *)sizeText:(CarPlayVideoSize)size {
    return [NSString stringWithFormat:@"%u × %u", size.width, size.height];
}

- (NSString *)videoDescription {
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    return [NSString stringWithFormat:L(@"%u × %u at %u fps"),
        profile.width, profile.height, profile.framesPerSecond];
}

- (void)buildDisplay:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __weak SettingsViewController *weakSelf = self;
    void (^setter)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ip_log("settings: %s=%d", key.UTF8String, on ? 1 : 0);
    };
    /* At most one priority is on; either one sets resolution and rate. */
    void (^prioritize)(NSString *, NSString *, BOOL) = ^(NSString *key, NSString *other, BOOL on) {
        setter(key, on);
        if (on) setter(other, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf render]; });
    };
    CarPlayVideoPriority priority = carplay_video_priority();
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    BOOL custom = priority == CarPlayVideoCustom;
    CarPlayDisplayHardware hardware = carplay_display_hardware();

    [b card:^(SettingsCard *card) {
        UIView *dock = [self switchRow:L(@"Dock on the Right") subtitle:nil
            on:[d boolForKey:RIGHT_HAND_DRIVE_KEY] width:w
            changed:^(BOOL on) { setter(RIGHT_HAND_DRIVE_KEY, on); }];
        [card addRow:dock height:dock.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        UIView *quality = [self switchRow:L(@"Prioritize Quality") subtitle:nil
            on:priority == CarPlayVideoQuality width:w
            changed:^(BOOL on) { prioritize(QUALITY_VIDEO_KEY, SMOOTH_VIDEO_KEY, on); }];
        [card addRow:quality height:quality.bounds.size.height];
        UIView *performance = [self switchRow:L(@"Prioritize Performance") subtitle:nil
            on:priority == CarPlayVideoPerformance width:w
            changed:^(BOOL on) { prioritize(SMOOTH_VIDEO_KEY, QUALITY_VIDEO_KEY, on); }];
        [card addRow:performance height:performance.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        CarPlayVideoSize size = {profile.width, profile.height};
        SettingsRow *resolution = [self navRow:L(@"Resolution") value:[self sizeText:size]
            width:w selected:NO action:^{ [weakSelf push:@"resolution"]; }];
        resolution.enabled = custom;
        resolution.alpha = custom ? 1 : 0.35;
        [card addRow:resolution height:52];
        NSArray *rates = hardware.screenFPS >= 60 ? @[@"30", @"60"] : @[@"30"];
        UIView *rate = [self segmentRow:L(@"Frame Rate") items:rates
            selected:profile.framesPerSecond >= 60 ? 1 : 0 width:w enabled:custom
            changed:^(NSInteger index) {
                [[NSUserDefaults standardUserDefaults] setInteger:index ? 60 : 30 forKey:VIDEO_FPS_KEY];
                [[NSUserDefaults standardUserDefaults] synchronize];
                ip_log("settings: %s=%d", VIDEO_FPS_KEY.UTF8String, index ? 60 : 30);
            }];
        [card addRow:rate height:52];
    }];
    [b card:^(SettingsCard *card) {
        UIView *radio = [self switchRow:L(@"Dedicate Wi-Fi to CarPlay") subtitle:nil
            on:[d boolForKey:DEDICATED_RADIO_KEY] width:w
            changed:^(BOOL on) { setter(DEDICATED_RADIO_KEY, on); }];
        [card addRow:radio height:radio.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        UIView *autoStart = [self switchRow:L(@"Start CarPlay Automatically") subtitle:nil
            on:[d boolForKey:AUTO_START_KEY] width:w
            changed:^(BOOL on) { setter(AUTO_START_KEY, on); }];
        [card addRow:autoStart height:autoStart.bounds.size.height];
    }];
}

/* Each item shows the value Showcase would send next to its switch. */
- (void)buildUsage:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    __weak SettingsViewController *weakSelf = self;
    BOOL enabled = [d boolForKey:USAGE_KEY];
    void (^set)(NSString *, BOOL) = ^(NSString *key, BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ send_anonymous_usage(); });
    };
    [b card:^(SettingsCard *card) {
        UIView *row = [self switchRow:L(@"Share Anonymous Usage") subtitle:nil on:enabled width:w
            changed:^(BOOL on) {
                set(USAGE_KEY, on);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [weakSelf render]; });
            }];
        [card addRow:row height:row.bounds.size.height];
    }];
    NSDictionary *values = usage_values();
    NSDictionary *titles = @{@"model": L(@"Device Model"), @"ios": L(@"iOS Version"),
        @"jailbreak": L(@"Jailbreak"), @"version": L(@"Showcase Version"), @"package": L(@"Package"),
        @"language": L(@"Language"), @"country": L(@"Country")};
    [b card:^(SettingsCard *card) {
        for (NSArray<NSString *> *item in usage_items()) {
            NSString *key = item[0], *field = item[1];
            UIView *row = [self switchRow:titles[field] subtitle:nil on:[d boolForKey:key] width:w
                changed:^(BOOL on) { set(key, on); }];
            NSString *value = [field isEqualToString:@"language"] ? showcase_language_name(values[field])
                : [values[field] isKindOfClass:[NSString class]] ? values[field] : @"";
            /* The title keeps its width; the value takes the rest before the switch. */
            UILabel *title = row.subviews.firstObject;
            CGFloat titleW = ceil([title sizeThatFits:CGSizeMake(CGFLOAT_MAX, 52)].width);
            CGFloat valueX = 16 + titleW + 12;
            UILabel *label = [[UILabel alloc] initWithFrame:
                CGRectMake(valueX, 0, MAX(0, w - 16 - 51 - 12 - valueX), 52)];
            label.text = value;
            label.textAlignment = NSTextAlignmentRight;
            label.textColor = [UIColor colorWithWhite:1 alpha:0.45];
            label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.75;
            [row addSubview:label];
            row.userInteractionEnabled = enabled;
            row.alpha = enabled ? 1 : 0.35;
            [card addRow:row height:row.bounds.size.height];
        }
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:L(@"View Source") color:nil width:w enabled:YES action:^{
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:
                GITHUB_URL @"/blob/main/telemetry/worker.js"] options:@{} completionHandler:nil];
        }] height:52];
    }];
}

- (void)buildResolution:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    CarPlayVideoSize options[CARPLAY_MAX_OPTIONS], fallback;
    unsigned count = carplay_offered_resolutions(options, &fallback);
    CarPlayDisplayProfile profile = preferred_carplay_display_profile();
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        [sizes addObject:[NSValue valueWithBytes:&options[i] objCType:@encode(CarPlayVideoSize)]];
    [b card:^(SettingsCard *card) {
        for (NSValue *value in sizes) {
            CarPlayVideoSize size;
            [value getValue:&size];
            BOOL isDefault = size.width == fallback.width && size.height == fallback.height;
            BOOL checked = size.width == profile.width && size.height == profile.height;
            [card addRow:[self choiceRow:[self sizeText:size] value:isDefault ? L(@"Default") : @""
                checked:checked width:w action:^{
                    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
                    /* The default follows the hardware; only another size is kept. */
                    if (isDefault) {
                        [d removeObjectForKey:VIDEO_WIDTH_KEY];
                        [d removeObjectForKey:VIDEO_HEIGHT_KEY];
                    } else {
                        [d setInteger:size.width forKey:VIDEO_WIDTH_KEY];
                        [d setInteger:size.height forKey:VIDEO_HEIGHT_KEY];
                    }
                    [d synchronize];
                    ip_log("settings: resolution=%ux%u", size.width, size.height);
                    [weakSelf pop];
                }] height:52];
        }
    }];
}

- (void)buildLanguage:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    NSString *chosen = showcase_chosen_language();
    void (^choose)(NSString *) = ^(NSString *language) {
        showcase_set_language(language);
        ip_log("settings: language=%s", language ? language.UTF8String : "device");
        [weakSelf.appDelegate renderState];
        [weakSelf render];
    };
    [b card:^(SettingsCard *card) {
        [card addRow:[self choiceRow:L(@"Device Language") value:showcase_language_name(showcase_device_language())
            checked:chosen == nil width:w action:^{ choose(nil); }] height:52];
    }];
    [b card:^(SettingsCard *card) {
        for (NSString *language in showcase_languages())
            [card addRow:[self choiceRow:showcase_language_name(language) value:@""
                checked:[chosen isEqualToString:language] width:w
                action:^{ choose(language); }] height:52];
    }];
}

- (void)buildLogs:(SettingsPageBuilder *)b {
    AppDelegate *app = self.appDelegate;
    CGFloat w = b.width;
    __weak SettingsViewController *weakSelf = self;
    BOOL logging = app.diagnosticsEnabled;
    BOOL capturing = app.tcpdumpWaitTimer || (app.tcpdumpPid > 0 && pid_alive(app.tcpdumpPid));
    BOOL haveTcpdump = tcpdump_tool_path() != NULL;
    NSString *lastCapture = capturing ? nil : [app latestNetworkDumpPath];

    [b card:^(SettingsCard *card) {
        UIView *row = [self switchRow:L(@"Detailed Logging") subtitle:nil
            on:logging width:w changed:^(BOOL on) {
                [app applyDiagnosticsEnabled:on];
                weakSelf.pageMessage = nil;
                [weakSelf render];
            }];
        [card addRow:row height:row.bounds.size.height];
    }];
    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:self.preparingLogs ? L(@"Preparing Logs…") : L(@"Send Logs")
            color:nil width:w enabled:!self.preparingLogs action:^{
                [weakSelf sendLogs];
            }] height:52];
        if (!haveTcpdump) {
            [card addRow:[self actionRow:L(@"Install tcpdump")
                color:nil width:w enabled:YES action:^{
                    NSURL *u = [NSURL URLWithString:@"sileo://package/tcpdump"];
                    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
                }] height:52];
        } else if (capturing) {
            [card addRow:[self actionRow:L(@"Stop and Send Network Capture")
                color:nil width:w enabled:YES action:^{
                    [app stopNetworkDumpCaptureWithReason:@"user requested export"];
                    NSString *dump = [app latestNetworkDumpPath];
                    weakSelf.pageMessage = nil;
                    [weakSelf render];
                    if (dump) [app presentShareForURL:[NSURL fileURLWithPath:dump]];
                }] height:52];
        } else {
            [card addRow:[self actionRow:L(@"Start Network Capture")
                color:nil width:w enabled:logging action:^{
                    [app startNetworkDumpCapture];
                    [weakSelf setMessage:L(@"Capturing") error:NO];
                }] height:52];
            if (lastCapture) {
                [card addRow:[self actionRow:L(@"Send Last Network Capture")
                    color:nil width:w enabled:YES action:^{
                        [app presentShareForURL:[NSURL fileURLWithPath:lastCapture]];
                    }] height:52];
            }
        }
    }];
    [self showPageMessage:b];

    [b card:^(SettingsCard *card) {
        [card addRow:[self actionRow:
            self.confirmingDestructive ? L(@"Tap Again to Clear") : L(@"Clear Logs and Captures")
            color:[self destructiveColor] width:w enabled:YES action:^{
                if (!weakSelf.confirmingDestructive) {
                    [weakSelf armDestructiveConfirmation];
                    return;
                }
                weakSelf.confirmingDestructive = NO;
                [app clearLogsAndDumps];
                [weakSelf setMessage:L(@"Cleared") error:NO];
            }] height:52];
    }];
}

- (void)sendLogs {
    AppDelegate *app = self.appDelegate;
    self.preparingLogs = YES;
    self.pageMessage = nil;
    [self render];
    __weak SettingsViewController *weakSelf = self;
    dispatch_async(app.bgQueue, ^{
        NSString *archive = [app createDiagnosticsArchive];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.preparingLogs = NO;
            if (!archive) {
                [weakSelf setMessage:L(@"Could not create the log archive") error:YES];
                return;
            }
            [weakSelf render];
            [app presentShareForURL:[NSURL fileURLWithPath:archive]];
        });
    });
}

- (void)loadHardwareInfo {
    if (g_settings_hardware_info || g_settings_hardware_loading) return;
    g_settings_hardware_loading = YES;
    __weak SettingsViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BluetoothRegistryProbeState bt = bluetooth_registry_probe();
        CarPlayDisplayHardware hardware = carplay_display_hardware();
        NSString *bluetooth = bt == BluetoothRegistryProbeSkywalk ? @"Skywalk"
            : (bt == BluetoothRegistryProbeLegacyUART ? @"UART"
               : (bt == BluetoothRegistryProbeMissing ? L(@"Not supported") : L(@"Unknown")));
        NSString *wifi = hardware.wlanAttachment == CarPlayWLANAttachmentHSIC ? @"HSIC"
            : (hardware.wlanAttachment == CarPlayWLANAttachmentPCIe ? @"PCIe" : L(@"Unknown"));
        NSDictionary *info = @{ @"bluetooth": bluetooth, @"wifi": wifi };
        dispatch_async(dispatch_get_main_queue(), ^{
            g_settings_hardware_info = info;
            g_settings_hardware_loading = NO;
            if ([weakSelf.stack.lastObject isEqualToString:@"about"]) [weakSelf render];
        });
    });
}

- (void)buildAbout:(SettingsPageBuilder *)b {
    CGFloat w = b.width;
    [b gap:8];
    UILabel *mark = [[UILabel alloc] init];
    mark.text = @APP_NAME;
    mark.textAlignment = NSTextAlignmentCenter;
    mark.textColor = [UIColor whiteColor];
    mark.font = [UIFont systemFontOfSize:44 weight:UIFontWeightUltraLight];
    [b place:mark height:54 gapAfter:2];
    UILabel *by = [[UILabel alloc] init];
    by.text = [NSString stringWithFormat:L(@"by %s\u2003\u2003%s"), APP_AUTHOR, APP_VERSION];
    by.textAlignment = NSTextAlignmentCenter;
    by.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    by.font = [UIFont systemFontOfSize:14];
    [b place:by height:20 gapAfter:24];

    [self loadHardwareInfo];
    NSDictionary *hw = g_settings_hardware_info;
    NSString *checking = L(@"Checking…");
#ifdef SHOWCASE_ROOTLESS
    NSString *package = @"Rootless";
#else
    NSString *package = @"Rootful";
#endif
    [b card:^(SettingsCard *card) {
        [card addRow:[self valueRow:L(@"Model") value:hardware_machine_identifier() width:w] height:48];
        [card addRow:[self valueRow:@"iOS" value:[UIDevice currentDevice].systemVersion width:w] height:48];
        [card addRow:[self valueRow:L(@"Package") value:package width:w] height:48];
        [card addRow:[self valueRow:@"Bluetooth" value:hw[@"bluetooth"] ?: checking width:w] height:48];
        [card addRow:[self valueRow:L(@"Wi-Fi Bus") value:hw[@"wifi"] ?: checking width:w] height:48];
        [card addRow:[self valueRow:L(@"CarPlay Video") value:hw ? [self videoDescription] : checking width:w] height:48];
    }];
}

/* ─── keyboard ─── */

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.ssidField) {
        [self.passwordField becomeFirstResponder];
        return NO;
    }
    [textField resignFirstResponder];
    if (textField == self.carNameField) [self saveCar];
    else if (textField == self.passwordField) [self saveHotspot];
    return NO;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeField = textField;
    [self revealActiveField];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.activeField == textField) self.activeField = nil;
}

- (void)revealActiveField {
    if (!self.activeField || !self.detailScroll) return;
    CGRect r = [self.activeField convertRect:self.activeField.bounds toView:self.detailScroll];
    [self.detailScroll scrollRectToVisible:CGRectInset(r, 0, -24) animated:YES];
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    self.keyboardOverlap = overlap;
    self.detailScroll.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    self.detailScroll.scrollIndicatorInsets = self.detailScroll.contentInset;
    [self revealActiveField];
}

- (void)keyboardWillHide:(NSNotification *)note {
    (void)note;
    self.keyboardOverlap = 0;
    self.detailScroll.contentInset = UIEdgeInsetsZero;
    self.detailScroll.scrollIndicatorInsets = UIEdgeInsetsZero;
}

@end

/* ═══════════════════════════════════════════════════════════════
 * WifiSetupViewController — sleek two-step setup modal
 *
 * Step 1: rename the device (the hotspot carries its name), with a name
 *         to copy and a link to Settings › General › About.
 * Step 2: enter the hotspot details.
 * ═══════════════════════════════════════════════════════════════ */

@interface WifiSetupViewController ()
@property (nonatomic, weak) UILabel *pillHintLabel;
@property (nonatomic, weak) UIView  *pillView;
@property (nonatomic, strong) UIView *contentView;
@end

@implementation WifiSetupViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildUI];
}

- (void)buildUI {
    UIView *root = self.contentView ?: self.view;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    BOOL phone = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone);

    /* ── Close button (top-right) ── */
    CGFloat closeSz = phone ? 34 : 40;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - closeSz - (phone ? 14 : 22),
                             phone ? 14 : 22, closeSz, closeSz);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    close.layer.cornerRadius = closeSz / 2.0;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
    close.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:close];

    UIScrollView *scroll = nil;
    if (phone) {
        scroll = [[UIScrollView alloc] initWithFrame:root.bounds];
        scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scroll.backgroundColor = [UIColor blackColor];
        scroll.alwaysBounceVertical = YES;
        scroll.showsVerticalScrollIndicator = NO;
        [root insertSubview:scroll belowSubview:close];
        root = scroll;
    }

    UILabel *title = [[UILabel alloc] init];
    title.text = L(@"Wi-Fi Setup");
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:(phone ? 34 : 44) weight:UIFontWeightUltraLight];
    title.frame = CGRectMake(0, phone ? 28 : 72, W, phone ? 44 : 56);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:title];

    CGFloat colW = phone ? MIN(560, W - 56) : MIN(620, W - 120);
    CGFloat colX = (W - colW) / 2.0;
    CGFloat y = phone ? 104 : 168;

    /* Step 1: the hotspot is named after the device. */
    [root addSubview:[self headlineLabel:[NSString stringWithFormat:L(@"1.  Rename This %@"), showcase_device_noun()]
                                    rect:CGRectMake(colX, y, colW, 30)]];
    y += 46;
    [root addSubview:[self buildCopyPillWithText:@"Carplay-Receiver" rect:CGRectMake(colX, y, colW, 56)]];
    y += 72;
    [root addSubview:[self primaryButton:L(@"Open Settings") rect:CGRectMake(colX, y, colW, 50)
                                  action:@selector(openSettingsTapped)]];
    y += 82;

    /* Step 2 */
    [root addSubview:[self headlineLabel:L(@"2.  Enter Hotspot Details") rect:CGRectMake(colX, y, colW, 30)]];
    y += 46;
    [root addSubview:[self primaryButton:L(@"Enter Details") rect:CGRectMake(colX, y, colW, 50)
                                  action:@selector(credsTapped)]];

    if (scroll) {
        scroll.contentSize = CGSizeMake(W, y + 74);
    }
}

/* ─── helpers ─── */

- (UILabel *)headlineLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    return l;
}

- (UIButton *)primaryButton:(NSString *)title rect:(CGRect)rect action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = rect;
    b.backgroundColor = [UIColor whiteColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0 alpha:0.45] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = rect.size.height / 2.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)buildCopyPillWithText:(NSString *)text rect:(CGRect)rect {
    UIView *container = [[UIView alloc] initWithFrame:rect];
    container.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    container.layer.cornerRadius = 14;
    container.layer.borderWidth = 1;
    container.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;

    UILabel *txt = [[UILabel alloc] init];
    txt.text = text;
    txt.textColor = [UIColor whiteColor];
    UIFont *mono = [UIFont fontWithName:@"Menlo-Regular" size:18];
    if (!mono) mono = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    txt.font = mono;
    txt.frame = CGRectMake(20, 0, rect.size.width - 130, rect.size.height);
    [container addSubview:txt];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = L(@"Copy");
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    hint.textAlignment = NSTextAlignmentRight;
    hint.frame = CGRectMake(rect.size.width - 110, 0, 90, rect.size.height);
    [container addSubview:hint];
    self.pillHintLabel = hint;
    self.pillView = container;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyExampleTapped:)];
    [container addGestureRecognizer:tap];

    return container;
}

- (void)copyExampleTapped:(UITapGestureRecognizer *)gr {
    [UIPasteboard generalPasteboard].string = @"Carplay-Receiver";
    self.pillHintLabel.text = L(@"Copied");
    UIView *pill = self.pillView;
    [UIView animateWithDuration:0.12 animations:^{
        pill.transform = CGAffineTransformMakeScale(1.02, 1.02);
        pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    } completion:^(BOOL d) {
        [UIView animateWithDuration:0.18 animations:^{
            pill.transform = CGAffineTransformIdentity;
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.pillHintLabel.text isEqualToString:L(@"Copied")]) {
            self.pillHintLabel.text = L(@"Copy");
            [UIView animateWithDuration:0.25 animations:^{
                pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            }];
        }
    });
}

- (void)openSettingsTapped {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=General&path=About"];
    UIApplication *app = [UIApplication sharedApplication];
    if (![app canOpenURL:u]) u = [NSURL URLWithString:@"prefs:root=General&path=About"];
    [app openURL:u options:@{} completionHandler:nil];
}

- (void)credsTapped {
    [self.appDelegate promptForCredentialsFromController:self];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [self.appDelegate renderState];
    }];
}

@end

/* ═══════════════════════════════════════════════════════════════ */

/* On some setups (#38: Dopamine on iOS 15.0.2) settings are gone after a
 * relaunch. Showcase keeps its own copy and restores it when the system copy
 * loses them; the Quality migration key is always set after a first launch. */
#define SETTINGS_BACKUP_PATH "/var/mobile/Library/Showcase/settings.plist"

static void restore_settings_backup(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *domain = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *current = [d persistentDomainForName:domain] ?: @{};
    NSDictionary *backup = [NSDictionary dictionaryWithContentsOfFile:@SETTINGS_BACKUP_PATH];
    if (backup.count == 0 || [current[QUALITY_DEFAULT_SET_KEY] boolValue]) return;
    NSMutableDictionary *merged = [backup mutableCopy];
    [merged addEntriesFromDictionary:current];
    [d setPersistentDomain:merged forName:domain];
    [d synchronize];
    ip_log("settings restored from %s (%lu keys); the system copy had %lu",
           SETTINGS_BACKUP_PATH, (unsigned long)backup.count, (unsigned long)current.count);
}

static void keep_settings_backup(void) {
    static dispatch_source_t pending;
    pending = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(pending, ^{
        NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
            persistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
        if (domain.count) [domain writeToFile:@SETTINGS_BACKUP_PATH atomically:YES];
    });
    dispatch_resume(pending);
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_source_merge_data(pending, 1);
        }];
    dispatch_source_merge_data(pending, 1);
}

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);

    /* Privilege escalation (binary is chmod 4755 root) */
    setuid(0); setgid(0);

    ip_log_open();
    ip_log("main: ruid=%u euid=%u argc=%d", getuid(), geteuid(), argc);
    ip_log("bundle: %s", [[[NSBundle mainBundle] bundlePath] UTF8String]);
#ifdef SHOWCASE_ROOTLESS
    ip_log("build: %s rootless", APP_VERSION);
#else
    ip_log("build: %s rootful", APP_VERSION);
#endif

    @autoreleasepool {
        restore_settings_backup();
        keep_settings_backup();
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}
