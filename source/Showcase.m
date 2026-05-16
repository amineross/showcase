/*
 * Showcase.m — Wireless CarPlay receiver for iPad
 *
 * Self-contained orchestrator app with state machine, car management,
 * AP credentials persistence, and full Apple-style UI.
 *
 * Compile (on-device):
 *   clang -fobjc-arc -isysroot /tmp/iPhoneOS10.3.sdk \
 *         -o Showcase Showcase.m \
 *         -framework UIKit -framework AVFoundation \
 *         -framework CoreMedia -framework Foundation \
 *         -Wl,-undefined,dynamic_lookup
 */

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

/* ═══════════════════════════════════════════════════════════════
 * Application logger
 * ═══════════════════════════════════════════════════════════════ */

#define LOG_DIR     "/var/mobile/Library/Showcase/logs"
#define APP_LOG     LOG_DIR "/app.log"
static FILE *g_logfile = NULL;

static void ip_log(const char *fmt, ...) {
    if (!g_logfile) return;
    char ts[32];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    fprintf(g_logfile, "[%s] ", ts);
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
#define APP_VERSION       "1.0 beta 2-7"
#define APP_AUTHOR        "Amine Rostane"
#define SOCK_PATH         "/tmp/ipadplay.sock"   /* IPC socket — kept for compat with carplay_services */
#define BLUETOOTHD_PLIST  "/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
#ifdef SHOWCASE_ROOTLESS
#define JB_PREFIX         "/var/jb"
#define BLUETOOL_PLIST    "/System/Library/LaunchDaemons/com.apple.BlueTool.plist"
#define BTSTACK_PLIST     JB_PATH("/Library/LaunchDaemons/ch.ringwald.BTstack.plist")
#define BTSTACK_SOCKET    "/tmp/BTstack"
#else
#define JB_PREFIX         ""
#define BTSTACK_PLIST     "/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
#define BTSTACK_SOCKET    "/tmp/BTstack"
#endif
#define JB_PATH(path)     JB_PREFIX path
#define BTDAEMON_PATH     JB_PATH("/usr/bin/BTdaemon")
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

#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04

#define TOUCH_DOWN  0
#define TOUCH_MOVE  1
#define TOUCH_UP    2

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

/* ═══════════════════════════════════════════════════════════════
 * Globals
 * ═══════════════════════════════════════════════════════════════ */

static volatile int g_touch_fd = -1;
static volatile float g_carplay_w = 0;
static volatile float g_carplay_h = 0;

/* ═══════════════════════════════════════════════════════════════
 * Touch IPC
 * ═══════════════════════════════════════════════════════════════ */

static void send_touch(uint8_t phase, uint16_t x, uint16_t y) {
    int fd = g_touch_fd;
    if (fd < 0) return;
    uint8_t msg[10];
    msg[0]=5; msg[1]=0; msg[2]=0; msg[3]=0;
    msg[4]=MSG_TOUCH;
    msg[5]=phase;
    msg[6]=x & 0xFF; msg[7]=x >> 8;
    msg[8]=y & 0xFF; msg[9]=y >> 8;
    write(fd, msg, 10);
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

static const char *first_existing_tool(const char *const paths[]) {
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
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

static BOOL pid_alive(pid_t pid) { return pid > 0 && kill(pid, 0) == 0; }

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
    int status; waitpid(pid, &status, WNOHANG);
}

static void signal_processes_named(const char *name, int sig) {
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
        if (pid <= 0 || pid == self) continue;
        if (strcmp(comm, name) != 0) continue;
        ip_log("reap stale helper: kill -%d %s pid=%d", sig, name, pid);
        kill(pid, sig);
    }
    free(procs);
}

static void reap_stale_helpers(void) {
    const char *names[] = {
        "carplay_services",
        "carplay_bt",
        "CarDisplaySim",
        "CarPlay Simulator",
        "CarPlay Simulato",
        "BTdaemon"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGTERM);
    usleep(700000);
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGKILL);
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
    if (ssid.length == 0) return @"Wi-Fi network is required.";
    if (ssid.length < 6) {
        return @"Wi-Fi name must be at least 6 characters. iOS rejects shorter names for CarPlay.";
    }
    NSString *lower = [ssid lowercaseString];
    NSArray *forbidden = @[@"ipad", @"iphone", @"ipod"];
    for (NSString *bad in forbidden) {
        if ([lower rangeOfString:bad].location != NSNotFound) {
            return [NSString stringWithFormat:
                @"Wi-Fi name cannot contain \"%@\". Rename your iPad in Settings › General › About › Name.",
                bad];
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
 * RootViewController — landscape-only, both directions, touch routing
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
    return UIInterfaceOrientationMaskLandscape;  /* both Left and Right */
}
- (BOOL)shouldAutorotate { return YES; }

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
- (void)handleTouches:(NSSet<UITouch *> *)t phase:(uint8_t)p {
    UITouch *touch = [t anyObject];
    uint16_t x, y;
    if ([self mapTouch:touch toX:&x y:&y]) send_touch(p, x, y);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self handleTouches:t phase:TOUCH_DOWN]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self handleTouches:t phase:TOUCH_MOVE]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self handleTouches:t phase:TOUCH_UP]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self handleTouches:t phase:TOUCH_UP]; }
@end

/* ═══════════════════════════════════════════════════════════════
 * AppDelegate — state machine, UI, IPC
 * ═══════════════════════════════════════════════════════════════ */

@class CarsViewController;

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) RootViewController *vc;
@property (nonatomic, strong) VideoView *videoView;

/* Setup overlay */
@property (nonatomic, strong) UIView   *setupOverlay;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *headlineLabel;
@property (nonatomic, strong) UILabel  *subtitleLabel;
@property (nonatomic, strong) UILabel  *carHintLabel;       /* "Currently using: Miata" */
@property (nonatomic, strong) UIButton *primaryButton;     /* Start CarPlay / Open Settings */
@property (nonatomic, strong) UIButton *secondaryButton;   /* My Cars / Cancel */
@property (nonatomic, strong) UIButton *tertiaryButton;    /* Wi-Fi (idle only) */
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

/* Floating chrome */
@property (nonatomic, strong) UIButton *closeButton;       /* top-right, only ACTIVE */
@property (nonatomic, strong) UIButton *infoButton;        /* top-left, always (iPad); pinch-revealed (iPhone Active) */
@property (nonatomic, strong) NSTimer  *chromeHideTimer;

/* iPhone Active: fullscreen video + pinch to reveal chrome */
@property (nonatomic, strong) UIPinchGestureRecognizer *phonePinch;
@property (nonatomic, assign) BOOL phoneChromeRevealed;
@property (nonatomic, assign) BOOL phonePinchValid;

/* Lifecycle */
@property (nonatomic, strong) NSTimer *backgroundStopTimer;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;

/* State */
@property (nonatomic, assign) ShowcaseState state;

/* Children */
@property (nonatomic, assign) pid_t btdaemonPid;
@property (nonatomic, assign) pid_t carplayBtPid;
@property (nonatomic, assign) pid_t carplayServicesPid;

/* Networking */
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) int clientFd;
@property (nonatomic, strong) dispatch_queue_t bgQueue;

/* AP polling */
@property (nonatomic, strong) NSTimer *apPollTimer;

/* Cars */
@property (nonatomic, strong) CarStore *cars;
@end

/* Forward — defined later */
@interface CarsViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@interface WifiSetupViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@implementation AppDelegate

- (UIView *)rootContentView {
    return self.vc.contentView ?: self.vc.view;
}

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {

    self.bgQueue = dispatch_queue_create("com.reng.showcase.bg", DISPATCH_QUEUE_SERIAL);
    self.state = StateIdle;
    self.listenFd = -1;
    self.clientFd = -1;
    self.bgTask = UIBackgroundTaskInvalid;
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

    [self transitionTo:StateIdle];
    return YES;
}

- (void)handleBackground {
    if (self.state != StateIdle && self.state != StateStopping) {
        ip_log("backgrounded — deferring stop");
        [self.backgroundStopTimer invalidate];
        self.backgroundStopTimer = nil;
        UIApplication *app = [UIApplication sharedApplication];
        if (self.bgTask == UIBackgroundTaskInvalid) {
            self.bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
                ip_log("background task expired");
                [self endBackgroundTask];
            }];
        }
        self.backgroundStopTimer = [NSTimer scheduledTimerWithTimeInterval:90.0
            target:self selector:@selector(backgroundStopExpired) userInfo:nil repeats:NO];
    }
}

- (void)handleForeground {
    [self.backgroundStopTimer invalidate];
    self.backgroundStopTimer = nil;
    [self endBackgroundTask];
    ip_log("foregrounded — continuing state=%ld", (long)self.state);
    if (self.state == StateAwaitingAP) [self pollAP];
    [self renderState];
}

- (void)backgroundStopExpired {
    self.backgroundStopTimer = nil;
    if (self.state != StateIdle && self.state != StateStopping) {
        ip_log("background grace expired — stopping");
        [self stopFlow];
    }
    [self endBackgroundTask];
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
    [self.setupOverlay addSubview:self.headlineLabel];

    /* Subtitle */
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.subtitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
    self.subtitleLabel.numberOfLines = 3;
    [self.setupOverlay addSubview:self.subtitleLabel];

    /* Spinner */
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spinner.hidesWhenStopped = YES;
    [self.setupOverlay addSubview:self.spinner];

    /* Primary button */
    self.primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.primaryButton.backgroundColor = [UIColor whiteColor];
    [self.primaryButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [self.primaryButton setTitleColor:[UIColor colorWithWhite:0 alpha:0.4] forState:UIControlStateHighlighted];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.primaryButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.primaryButton];

    /* Secondary button (Wi-Fi) */
    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.3] forState:UIControlStateHighlighted];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.secondaryButton addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.secondaryButton];

    /* Tertiary button (My Cars — only shown on idle) */
    self.tertiaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.tertiaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    [self.tertiaryButton setTitleColor:[UIColor colorWithWhite:1 alpha:0.3] forState:UIControlStateHighlighted];
    self.tertiaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.tertiaryButton addTarget:self action:@selector(tertiaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.setupOverlay addSubview:self.tertiaryButton];

    /* Hint at very bottom — current car + AP status */
    self.carHintLabel = [[UILabel alloc] init];
    self.carHintLabel.textAlignment = NSTextAlignmentCenter;
    self.carHintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    self.carHintLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.carHintLabel.numberOfLines = 2;
    [self.setupOverlay addSubview:self.carHintLabel];

    [self layoutSetupOverlay];
}

- (void)layoutSetupOverlay {
    CGSize s = [self rootContentView].bounds.size;
    CGFloat W = s.width, H = s.height, cx = W / 2.0;
    BOOL phone = [self isPhone];

    self.titleLabel.font = [UIFont systemFontOfSize:(phone ? 44 : 64) weight:UIFontWeightUltraLight];
    self.headlineLabel.font = [UIFont systemFontOfSize:(phone ? 20 : 24) weight:UIFontWeightRegular];
    self.subtitleLabel.font = [UIFont systemFontOfSize:(phone ? 14 : 16) weight:UIFontWeightRegular];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 16 : 18) weight:UIFontWeightSemibold];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 14 : 15) weight:UIFontWeightRegular];
    self.tertiaryButton.titleLabel.font = [UIFont systemFontOfSize:(phone ? 14 : 15) weight:UIFontWeightRegular];

    CGFloat titleY = phone ? H * 0.10 : H * 0.20;
    CGFloat side = phone ? 24 : 40;
    CGFloat titleH = phone ? 58 : 80;

    CGFloat headlineY = H * 0.42;
    CGFloat subtitleY = headlineY + 44;
    CGFloat spinnerY = headlineY - 50;
    CGFloat primaryY = H * 0.66;
    CGFloat subtitleH = phone ? 64 : 60;

    if (phone) {
        BOOL loading = (self.state == StatePreparingBT ||
                        self.state == StatePreparingNet ||
                        self.state == StateAwaitingPhone);
        BOOL buttonState = (self.state == StateIdle ||
                            self.state == StateAwaitingAP);

        if (loading) {
            spinnerY = H * 0.32;
            headlineY = spinnerY + 60;
            subtitleY = headlineY + 42;
            primaryY = H * 0.72;
        } else if (buttonState) {
            headlineY = H * 0.34;
            subtitleY = headlineY + 42;
            primaryY = subtitleY + 88;
        }
    }

    self.titleLabel.frame    = CGRectMake(0, titleY, W, titleH);
    self.headlineLabel.frame = CGRectMake(side, headlineY, W - side * 2, 34);
    self.subtitleLabel.frame = CGRectMake(side, subtitleY, W - side * 2, subtitleH);
    self.spinner.frame       = CGRectMake(cx - 18, spinnerY, 36, 36);

    CGFloat btnW = phone ? MIN(240, W - 80) : 240;
    CGFloat btnH = phone ? 46 : 52;
    self.primaryButton.frame   = CGRectMake(cx - btnW/2, primaryY, btnW, btnH);
    self.primaryButton.layer.cornerRadius = btnH / 2.0;

    CGFloat gap = phone ? 10 : 18;
    CGFloat rowH = phone ? 24 : 26;
    self.secondaryButton.frame = CGRectMake(cx - btnW/2, primaryY + btnH + gap, btnW, rowH);
    self.tertiaryButton.frame  = CGRectMake(cx - btnW/2, primaryY + btnH + gap + rowH, btnW, rowH);
    self.carHintLabel.frame    = CGRectMake(20, H - (phone ? 38 : 52), W - 40, 36);
}

- (void)buildChrome {
    UIView *content = [self rootContentView];
    CGFloat sz = 44;
    CGFloat margin = 18;
    CGSize bs = content.bounds.size;

    /* Close button — top-right, hidden by default */
    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.frame = CGRectMake(bs.width - sz - margin, margin, sz, sz);
    self.closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.closeButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.closeButton.layer.cornerRadius = sz / 2.0;
    [self.closeButton setTitle:@"×" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
    self.closeButton.titleEdgeInsets = UIEdgeInsetsMake(-3, 0, 0, 0);
    self.closeButton.hidden = YES;
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.closeButton];

    /* Info button — top-left, always shown */
    self.infoButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.infoButton.frame = CGRectMake(margin, margin, sz, sz);
    self.infoButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    self.infoButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.infoButton.layer.cornerRadius = sz / 2.0;
    [self.infoButton setTitle:@"i" forState:UIControlStateNormal];
    [self.infoButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.infoButton.titleLabel.font = [UIFont fontWithName:@"Georgia-Italic" size:22];
    if (!self.infoButton.titleLabel.font) {
        self.infoButton.titleLabel.font = [UIFont italicSystemFontOfSize:22];
    }
    [self.infoButton addTarget:self action:@selector(infoTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.infoButton];

    /* Tap recognizer — used during ACTIVE to wake chrome (iPad) */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(revealChrome)];
    tap.cancelsTouchesInView = NO;
    [content addGestureRecognizer:tap];

    /* iPhone Active uses a different model: video is fullscreen, chrome hidden;
     * pinch-in dezooms the video and shows the buttons; pinch-out hides. */
    if ([self isPhone]) {
        self.phonePinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePhonePinch:)];
        self.phonePinch.cancelsTouchesInView = NO;
        self.phonePinch.delaysTouchesBegan = NO;
        self.phonePinch.delaysTouchesEnded = NO;
        self.phonePinch.enabled = NO; /* enabled only in Active */
        [self.vc.view addGestureRecognizer:self.phonePinch];
    }
}

- (BOOL)isPhone {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
}

- (void)handlePhonePinch:(UIPinchGestureRecognizer *)g {
    if (self.state != StateActive) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            self.phonePinchValid = (g.numberOfTouches >= 2);
            break;
        case UIGestureRecognizerStateChanged:
            if (g.numberOfTouches >= 2) self.phonePinchValid = YES;
            break;
        case UIGestureRecognizerStateEnded:
            if (!self.phonePinchValid) break;
            if (g.scale < 0.85 && !self.phoneChromeRevealed) {
                [self setPhoneChromeRevealed:YES animated:YES];
            } else if (g.scale > 1.15 && self.phoneChromeRevealed) {
                [self setPhoneChromeRevealed:NO animated:YES];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            self.phonePinchValid = NO;
            break;
        default: break;
    }
}

- (void)setPhoneChromeRevealed:(BOOL)revealed animated:(BOOL)animated {
    self.phoneChromeRevealed = revealed;
    [self.chromeHideTimer invalidate]; self.chromeHideTimer = nil;
    CGAffineTransform target = revealed
        ? CGAffineTransformMakeScale(0.78, 0.78)
        : CGAffineTransformIdentity;
    void (^apply)(void) = ^{
        self.videoView.transform = target;
        self.infoButton.alpha = revealed ? 1.0 : 0.0;
        self.closeButton.alpha = revealed ? 1.0 : 0.0;
    };
    self.infoButton.hidden = NO;
    self.closeButton.hidden = NO;
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:apply completion:^(BOOL ok){
            if (!revealed) {
                self.infoButton.hidden = YES;
                self.closeButton.hidden = YES;
            }
        }];
    } else {
        apply();
        if (!revealed) { self.infoButton.hidden = YES; self.closeButton.hidden = YES; }
    }
}

/* ─── State machine ────────────────────────────────────────── */

- (void)transitionTo:(ShowcaseState)s {
    self.state = s;
    dispatch_async(dispatch_get_main_queue(), ^{ [self renderState]; });
}

- (void)renderState {
    [self layoutSetupOverlay];

    self.setupOverlay.hidden = NO;
    self.closeButton.hidden = YES;
    if ([self isPhone] && self.state != StateActive) {
        /* Restore the 1024x768 canvas in every non-Active state. */
        if (self.vc.fullscreenMode) {
            self.vc.fullscreenMode = NO;
            [self.vc.view setNeedsLayout];
        }
        self.videoView.transform = CGAffineTransformIdentity;
        self.phonePinch.enabled = NO;
        self.phoneChromeRevealed = NO;
        self.infoButton.hidden = NO;
        self.infoButton.alpha = 1.0;
        self.closeButton.alpha = 1.0;
    }
    self.spinner.hidden = YES; [self.spinner stopAnimating];
    self.primaryButton.hidden = YES;
    self.primaryButton.enabled = YES;
    self.primaryButton.alpha = 1.0;
    self.secondaryButton.hidden = YES;
    self.tertiaryButton.hidden = YES;
    self.carHintLabel.hidden = YES;

    Car *sel = self.cars.selected;

    switch (self.state) {
        case StateIdle: {
            BOOL apReady = [self.cars apReady];
            self.primaryButton.hidden = NO;
            self.primaryButton.enabled = YES;
            self.primaryButton.alpha = 1.0;

            if (!apReady) {
                /* First-run: Wi-Fi setup is the headline CTA. */
                self.headlineLabel.text = @"Welcome";
                self.subtitleLabel.text = @"Before connecting your iPhone, we need to know\nyour iPad's hotspot details.";

                [self.primaryButton setTitle:@"Set Up Wi-Fi" forState:UIControlStateNormal];

                [self.tertiaryButton setTitle:@"My Cars  ›" forState:UIControlStateNormal];
                self.tertiaryButton.hidden = NO;

                self.carHintLabel.text = @"";
                self.carHintLabel.hidden = YES;
            } else {
                /* Configured: classic view, Start CarPlay is the headline CTA. */
                self.headlineLabel.text = @"Wireless CarPlay for iPad";
                self.subtitleLabel.text = @"Connect your iPhone wirelessly\nto your iPad as a CarPlay screen.";

                [self.primaryButton setTitle:@"Start CarPlay" forState:UIControlStateNormal];

                NSString *wifiTitle = [NSString stringWithFormat:@"Wi-Fi: %@", self.cars.apSSID];
                [self.secondaryButton setTitle:wifiTitle forState:UIControlStateNormal];
                self.secondaryButton.hidden = NO;

                [self.tertiaryButton setTitle:@"My Cars  ›" forState:UIControlStateNormal];
                self.tertiaryButton.hidden = NO;

                self.carHintLabel.text = sel
                    ? [NSString stringWithFormat:@"Currently using: %@", sel.name]
                    : @"";
                self.carHintLabel.hidden = NO;
            }
            break;
        }

        case StateAwaitingAP:
            self.headlineLabel.text = @"Turn on Personal Hotspot";
            self.subtitleLabel.text = @"Settings › Personal Hotspot\nAllow Others to Join";
            [self.primaryButton setTitle:@"Open Settings" forState:UIControlStateNormal];
            self.primaryButton.hidden = NO;
            [self.secondaryButton setTitle:@"Cancel" forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StatePreparingBT:
            self.headlineLabel.text = @"Preparing Bluetooth";
            self.subtitleLabel.text = @"Starting Bluetooth daemon…";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;

        case StatePreparingNet:
            self.headlineLabel.text = @"Starting CarPlay services";
            self.subtitleLabel.text = @"Almost ready…";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;

        case StateAwaitingPhone:
            self.headlineLabel.text = @"Connect from your iPhone";
            /* subtitleLabel.text is updated dynamically by status messages */
            if (self.subtitleLabel.text.length == 0 ||
                ![self.subtitleLabel.text containsString:@"\n"]) {
                self.subtitleLabel.text = sel
                    ? [NSString stringWithFormat:@"Settings › General › CarPlay\nSelect %@", sel.name]
                    : @"Settings › General › CarPlay";
            }
            self.spinner.hidden = NO; [self.spinner startAnimating];
            [self.secondaryButton setTitle:@"Cancel" forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StateActive:
            self.setupOverlay.hidden = YES;
            if ([self isPhone]) {
                /* Fullscreen video, no chrome by default. Pinch-in reveals it. */
                self.vc.fullscreenMode = YES;
                [self.vc.view setNeedsLayout];
                self.phoneChromeRevealed = NO;
                self.phonePinchValid = NO;
                self.phonePinch.enabled = YES;
                self.videoView.transform = CGAffineTransformIdentity;
                self.infoButton.hidden = YES;
                self.closeButton.hidden = YES;
            } else {
                self.closeButton.hidden = NO;
                [self scheduleChromeHide];
            }
            break;

        case StateStopping:
            self.headlineLabel.text = @"Stopping";
            self.subtitleLabel.text = @"";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;
    }
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
    if (self.state == StateIdle) {
        [self showWifiSetup];
    } else if (self.state != StateStopping) {
        [self stopFlow];
    }
}
- (void)tertiaryTapped {
    if (self.state == StateIdle) [self showCars];
}

- (void)closeTapped { [self stopFlow]; }
- (void)infoTapped  { [self showAbout]; }

- (void)revealChrome {
    if (self.state != StateActive) return;
    if ([self isPhone]) return; /* iPhone Active uses pinch, not tap, to control chrome */
    self.closeButton.hidden = NO;
    self.closeButton.alpha = 1;
    [self scheduleChromeHide];
}

- (void)scheduleChromeHide {
    [self.chromeHideTimer invalidate];
    self.chromeHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
        target:self selector:@selector(hideChrome) userInfo:nil repeats:NO];
}
- (void)hideChrome {
    [UIView animateWithDuration:0.3 animations:^{
        self.closeButton.alpha = 0;
    } completion:^(BOOL d) {
        if (self.state == StateActive) self.closeButton.hidden = YES;
    }];
}

/* ─── Action helpers ───────────────────────────────────────── */

- (void)attemptStart {
    /* Should never be reachable when AP not ready (button is disabled) — defensive */
    if (![self.cars apReady]) { [self showWifiSetup]; return; }
    if (self.cars.cars.count == 0) return;
    [self startFlow];
}

- (void)startFlow {
    ip_log("startFlow: car='%s' ssid='%s'",
           [self.cars.selected.name UTF8String],
           [self.cars.apSSID UTF8String]);
    [self transitionTo:StateAwaitingAP];
    [self.apPollTimer invalidate];
    self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
        target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
    [self pollAP];
}

- (void)pollAP {
    if (self.state != StateAwaitingAP) {
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        return;
    }
    if (is_ap_up()) {
        ip_log("AP detected — advancing");
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
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

    if (geteuid() != 0) {
        [self failWith:@"App is not running as root (must be chmod 4755)"];
        return;
    }

    enable_btstack_hci_logging();

    reap_stale_helpers();

    /* 1. Unload bluetoothd */
    const char *launchctl = launchctl_path();
    if (!launchctl) {
        [self failWith:@"launchctl not found"];
        return;
    }
    ip_log("launchctl path: %s", launchctl);
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
    sleep(2);

#ifdef SHOWCASE_ROOTLESS
    /* 2. Start bundled BTstack through launchd so the advertised socket exists. */
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    unlink(BTSTACK_SOCKET);

    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    rc = run_blocking(launchctl, loadBTstackArgv);
    if (rc != 0) {
        [self failWith:@"BTstack launch daemon failed to load"];
        return;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failWith:@"BTstack socket not available"];
        return;
    }
    self.btdaemonPid = 0;
#else
    /* 2. Spawn BTdaemon */
    char *btdArgv[] = { (char*)"BTdaemon", NULL };
    self.btdaemonPid = spawn_daemon(BTDAEMON_PATH, btdArgv, LOG_DIR "/btdaemon.log");
    if (self.btdaemonPid <= 0) { [self failWith:@"BTdaemon failed to start"]; return; }
    sleep(3);
    if (!pid_alive(self.btdaemonPid)) { [self failWith:@"BTdaemon exited early"]; return; }
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
    self.carplayBtPid = spawn_daemon([btPath UTF8String], btArgv, LOG_DIR "/carplay_bt.log");
    if (self.carplayBtPid <= 0) { [self failWith:@"carplay_bt failed to start"]; return; }
    if (!wait_for_pid_alive(self.carplayBtPid, 8, "carplay_bt")) {
        [self failWith:@"carplay_bt exited during setup"];
        return;
    }

    [self transitionTo:StatePreparingNet];
    [self bgPrepareNet];
}

- (void)bgPrepareNet {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *svcPath = [bundlePath stringByAppendingPathComponent:@SVC_HELPER_NAME];
    Car *sel = self.cars.selected;
    ip_log("bgPrepareNet");

    if (![self startIPCListener]) { [self failWith:@"IPC listener failed"]; return; }

    char nameBuf[64];
    snprintf(nameBuf, sizeof(nameBuf), "%s", [sel.name UTF8String]);
    char *svcArgv[] = {
        (char*)SVC_HELPER_NAME,
        (char*)"--name", nameBuf,
        NULL
    };
    self.carplayServicesPid = spawn_daemon([svcPath UTF8String], svcArgv, LOG_DIR "/carplay_services.log");
    if (self.carplayServicesPid <= 0) { [self failWith:@"carplay_services failed to start"]; return; }
    if (!wait_for_pid_alive(self.carplayServicesPid, 4, "carplay_services")) {
        [self failWith:@"carplay_services exited during setup"];
        return;
    }

    [self transitionTo:StateAwaitingPhone];
}

- (void)stopFlow {
    [self.backgroundStopTimer invalidate]; self.backgroundStopTimer = nil;
    [self endBackgroundTask];
    [self.apPollTimer invalidate]; self.apPollTimer = nil;
    [self transitionTo:StateStopping];
    dispatch_async(self.bgQueue, ^{
        if (self.clientFd >= 0) { close(self.clientFd); self.clientFd = -1; }
        if (self.listenFd >= 0) { close(self.listenFd); self.listenFd = -1; }
        unlink(SOCK_PATH);
        g_touch_fd = -1;
        g_carplay_w = 0; g_carplay_h = 0;

        kill_pid(self.carplayServicesPid); self.carplayServicesPid = 0;
        kill_pid(self.carplayBtPid);       self.carplayBtPid = 0;
#ifdef SHOWCASE_ROOTLESS
        self.btdaemonPid = 0;
#else
        kill_pid(self.btdaemonPid);        self.btdaemonPid = 0;
#endif

        const char *launchctl = launchctl_path();
        if (launchctl) {
#ifdef SHOWCASE_ROOTLESS
            char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                          (char*)BTSTACK_PLIST, NULL };
            run_blocking(launchctl, unloadBTstackArgv);
            unlink(BTSTACK_SOCKET);
#endif
            char *loadArgv[] = { (char*)"launchctl", (char*)"load",
                                 (char*)BLUETOOTHD_PLIST, NULL };
            run_blocking(launchctl, loadArgv);
#ifdef SHOWCASE_ROOTLESS
            char *loadBlueToolArgv[] = { (char*)"launchctl", (char*)"load",
                                         (char*)BLUETOOL_PLIST, NULL };
            run_blocking(launchctl, loadBlueToolArgv);
#endif
        } else {
            ip_log("WARNING: launchctl not found while restoring bluetoothd");
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });

        [self transitionTo:StateIdle];
    });
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

/* ─── Cars + About ─────────────────────────────────────────── */

- (void)showCars {
    CarsViewController *vc = [[CarsViewController alloc] init];
    vc.appDelegate = self;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self.vc presentViewController:vc animated:YES completion:nil];
}

- (void)editCar:(Car *)existing completion:(void (^)(Car *saved))completion {
    NSString *title = existing ? @"Rename Car" : @"New Car";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:@"This is the name iPhone will show in CarPlay settings."
        preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Car name (e.g. Miata)";
        tf.text = existing.name ?: @"";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            Car *c = existing ?: [[Car alloc] init];
            NSString *newName = ac.textFields[0].text;
            c.name = newName.length ? newName : @"My Car";
            if (!existing) {
                [self.cars addCar:c];
                [self.cars selectCar:c];
            } else {
                [self.cars save];
            }
            [self renderState];
            if (completion) completion(c);
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_a) {
            if (completion) completion(nil);
        }]];

    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:ac animated:YES completion:nil];
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

/* Called by WifiSetupViewController when the user taps "Set credentials".
 * This is a focused alert prompt for SSID + password. */
- (void)promptForCredentialsFromController:(UIViewController *)host {
    NSString *currentSSID = self.cars.apSSID ?: @"";
    NSString *currentPass = self.cars.apPassword ?: @"";

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Hotspot Credentials"
                         message:@"Enter your iPad's name and the Personal Hotspot password."
                  preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"iPad name (Wi-Fi network)";
        tf.text = currentSSID;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Hotspot password";
        tf.text = currentPass;
        tf.secureTextEntry = YES;
    }];

    __weak UIViewController *weakHost = host;
    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            NSString *ssid = ac.textFields[0].text ?: @"";
            NSString *pass = ac.textFields[1].text ?: @"";
            NSString *err = validateSSID(ssid);
            if (!err && pass.length < 8) {
                err = @"Hotspot passwords must be at least 8 characters.";
            }
            if (err) {
                UIAlertController *e = [UIAlertController
                    alertControllerWithTitle:@"Try Again"
                                     message:err
                              preferredStyle:UIAlertControllerStyleAlert];
                [e addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *_b) {
                        [self promptForCredentialsFromController:weakHost];
                    }]];
                [weakHost presentViewController:e animated:YES completion:nil];
                return;
            }
            [self.cars setAPSSID:ssid password:pass];
            [weakHost dismissViewControllerAnimated:YES completion:^{
                [self renderState];
            }];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    [host presentViewController:ac animated:YES completion:nil];
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
    enable_btstack_hci_logging();

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
    const char *unamePath = first_existing_tool(unamePaths);
    const char *ifconfigPath = first_existing_tool(ifconfigPaths);
    const char *psPath = first_existing_tool(psPaths);
    const char *lsPath = first_existing_tool(lsPaths);

    NSMutableString *env = [NSMutableString string];
    [env appendFormat:@"Showcase diagnostics\n"];
    [env appendFormat:@"version=%s\n", APP_VERSION];
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
    [env appendFormat:@"btdaemon=%s\n", BTDAEMON_PATH];
    [env appendFormat:@"btstack_plist=%s\n", BTSTACK_PLIST];
    [env appendFormat:@"btstack_socket=%s exists=%s\n",
                      BTSTACK_SOCKET, access(BTSTACK_SOCKET, F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"hci_dump=/tmp/hci_dump.pklg exists=%s\n",
                      access("/tmp/hci_dump.pklg", F_OK) == 0 ? "yes" : "no"];
    [env writeToFile:[work stringByAppendingPathComponent:@"environment.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [self copyLogDirectoryToDiagnosticsDir:work];
    [self copyPath:@"/tmp/hci_dump.pklg" toDiagnosticsDir:work name:@"hci_dump.pklg"];
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
        char *argv1[] = { (char*)"dpkg", (char*)"-s", (char*)"com.rostane.showcase", NULL };
        run_capture(dpkgPath, argv1, [[commandsDir stringByAppendingPathComponent:@"dpkg-showcase.txt"] UTF8String]);
        char *argv2[] = { (char*)"dpkg", (char*)"-l", NULL };
        run_capture(dpkgPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-l.txt"] UTF8String]);
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

- (void)exportDiagnostics {
    UIAlertController *busy = [UIAlertController
        alertControllerWithTitle:@"Preparing Logs"
        message:@"Collecting Showcase diagnostics..."
        preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:busy animated:YES completion:nil];

    dispatch_async(self.bgQueue, ^{
        NSString *archive = [self createDiagnosticsArchive];
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (!archive) {
                    UIAlertController *err = [UIAlertController
                        alertControllerWithTitle:@"Could Not Export Logs"
                        message:@"tar was not available or the archive could not be created."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [err addAction:[UIAlertAction actionWithTitle:@"OK"
                        style:UIAlertActionStyleDefault handler:nil]];
                    [self.vc presentViewController:err animated:YES completion:nil];
                    return;
                }
                NSURL *url = [NSURL fileURLWithPath:archive];
                UIActivityViewController *avc =
                    [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                      applicationActivities:nil];
                if (avc.popoverPresentationController) {
                    avc.popoverPresentationController.sourceView = self.infoButton ?: self.vc.view;
                    avc.popoverPresentationController.sourceRect =
                        self.infoButton ? self.infoButton.bounds : self.vc.view.bounds;
                }
                [self.vc presentViewController:avc animated:YES completion:nil];
            }];
        });
    });
}

- (void)showAbout {
    NSString *msg = [NSString stringWithFormat:@"Version %s\nby %s",
                     APP_VERSION, APP_AUTHOR];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@APP_NAME
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Send Log"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self exportDiagnostics];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *p = self.vc.presentedViewController ?: self.vc;
    [p presentViewController:ac animated:YES completion:nil];
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
        ip_log("services connected");
        self.clientFd = c;
        g_touch_fd = c;
        [self ipcHandleConnection:c];
        g_touch_fd = -1;
        close(c);
        self.clientFd = -1;
        ip_log("services disconnected");
        if (self.state == StateActive || self.state == StateAwaitingPhone) {
            [self stopFlow]; break;
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
                    dispatch_async(dispatch_get_main_queue(), ^{
                        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        [layer flush];
                    });
                    gotFirstFrame = false;
                }
            }
            free(payload);

        } else if (type == MSG_VIDEO_FRAME) {
            if (!fmtDesc) { free(payload); continue; }
            if (!gotFirstFrame) {
                gotFirstFrame = true;
                [self transitionTo:StateActive];
                ip_log("first video frame");
            }

            CMBlockBufferRef block = NULL;
            OSStatus st = CMBlockBufferCreateWithMemoryBlock(
                NULL, NULL, len, kCFAllocatorDefault, NULL, 0, len,
                kCMBlockBufferAssureMemoryNowFlag, &block);
            if (st == noErr) CMBlockBufferReplaceDataBytes(payload, block, 0, len);
            free(payload); payload = NULL;
            if (st != noErr || !block) continue;

            CMSampleBufferRef sample = NULL;
            const size_t sz = len;
            st = CMSampleBufferCreateReady(NULL, block, fmtDesc, 1, 0, NULL, 1, &sz, &sample);
            CFRelease(block);
            if (st != noErr || !sample) continue;

            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, true);
            if (att && CFArrayGetCount(att) > 0) {
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
                CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            }

            AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
            if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
            [layer enqueueSampleBuffer:sample];
            CFRelease(sample);
            continue;
        } else if (type == MSG_STATUS) {
            if (len >= 1) {
                uint8_t code = payload[0];
                ip_log("MSG_STATUS code=0x%02X", code);
                NSString *text = nil;
                switch (code) {
                    case STATUS_IPHONE_CONNECTED:
                        text = @"iPhone connected\nPairing…";
                        break;
                    case STATUS_PAIR_SETUP_COMPLETE:
                        text = @"Pairing…\nVerifying…";
                        break;
                    case STATUS_PAIR_VERIFY_COMPLETE:
                        text = @"Authenticated ✓\nPreparing stream…";
                        break;
                    case STATUS_STREAM_SETUP:
                        text = @"Stream ready ✓\nReceiving video…";
                        break;
                }
                if (text) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.state == StateAwaitingPhone) {
                            self.subtitleLabel.text = text;
                        }
                    });
                }
            }
            free(payload);
        } else {
            free(payload);
        }
    }
    if (fmtDesc) CFRelease(fmtDesc);
}

@end

/* ═══════════════════════════════════════════════════════════════
 * CarsViewController — modal sheet listing/managing cars
 * ═══════════════════════════════════════════════════════════════ */

@interface CarsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation CarsViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    CGFloat W = self.view.bounds.size.width;

    /* Top bar: Done + title + Add */
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 64)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor blackColor];
    [self.view addSubview:bar];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(20, 16, 80, 32);
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.tintColor = [UIColor whiteColor];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, W, 32)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"My Cars";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [bar addSubview:title];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W - 60, 16, 40, 32);
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"+" forState:UIControlStateNormal];
    add.tintColor = [UIColor whiteColor];
    add.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
    [add addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:add];

    /* Table */
    self.table = [[UITableView alloc] initWithFrame:
        CGRectMake(0, 64, W, self.view.bounds.size.height - 64)
        style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [UIColor blackColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.rowHeight = 70;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [self.appDelegate renderState];
    }];
}
- (void)addTapped {
    [self.appDelegate editCar:nil completion:^(Car *saved) {
        [self.table reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return self.appDelegate.cars.cars.count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *kID = @"car";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kID];
        cell.backgroundColor = [UIColor blackColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        cell.selectedBackgroundView = sel;
    }
    Car *car = self.appDelegate.cars.cars[ip.row];
    cell.textLabel.text = car.name;
    cell.detailTextLabel.text = (car == self.appDelegate.cars.selected)
        ? @"Active"
        : @"";
    cell.accessoryType = (car == self.appDelegate.cars.selected)
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor whiteColor];
    return cell;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    Car *car = self.appDelegate.cars.cars[ip.row];
    BOOL isSelected = (car == self.appDelegate.cars.selected);
    BOOL canDelete = self.appDelegate.cars.cars.count > 1;

    NSString *subtitle = isSelected ? @"Currently active" : @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:car.name
                         message:subtitle
                  preferredStyle:UIAlertControllerStyleAlert];

    if (!isSelected) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Use This Car"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *_a) {
                [self.appDelegate.cars selectCar:car];
                [t reloadData];
            }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Edit Car"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            [self.appDelegate editCar:car completion:^(Car *saved) {
                [t reloadData];
            }];
        }]];

    if (canDelete) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Delete Car"
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *_a) {
                NSInteger row = [self.appDelegate.cars.cars indexOfObject:car];
                if (row == NSNotFound) return;
                /* Confirm before destroying */
                UIAlertController *confirm = [UIAlertController
                    alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", car.name]
                                     message:@"This will remove the car and its Wi-Fi credentials."
                              preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                    style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *_b) {
                        [self.appDelegate.cars deleteCarAtIndex:row];
                        [t reloadData];
                    }]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                    style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:confirm animated:YES completion:nil];
            }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip {
    /* Swipe-to-delete remains as a power-user shortcut, only when >1 cars */
    return self.appDelegate.cars.cars.count > 1;
}
- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)t
    editActionsForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewRowAction *del = [UITableViewRowAction
        rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Delete"
        handler:^(UITableViewRowAction *a, NSIndexPath *p) {
            [self.appDelegate.cars deleteCarAtIndex:p.row];
            [t reloadData];
        }];
    return @[del];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * WifiSetupViewController — sleek two-step setup modal
 *
 * Step 1: Rename your iPad. Body explains why, shows a tappable
 *         example name that copies to the clipboard, plus a button
 *         that deep-links to Settings › General › About.
 *
 * Step 2: Enter hotspot details. Tap opens a focused alert prompt.
 *
 * Layout: single centered column, plenty of breathing room. Designed
 * to feel like a focused Apple onboarding screen.
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
    return UIInterfaceOrientationMaskLandscape;
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

    /* ── Header ── */
    UILabel *eyebrow = [[UILabel alloc] init];
    eyebrow.text = @"SHOWCASE";
    eyebrow.textAlignment = NSTextAlignmentCenter;
    eyebrow.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    eyebrow.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    eyebrow.frame = CGRectMake(0, phone ? 20 : 56, W, 16);
    eyebrow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    /* letterspacing simulated via attributed string */
    eyebrow.attributedText = [[NSAttributedString alloc]
        initWithString:@"SHOWCASE"
            attributes:@{ NSKernAttributeName: @(3.0),
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35],
                          NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] }];
    [root addSubview:eyebrow];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Wi-Fi Setup";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:(phone ? 34 : 44) weight:UIFontWeightUltraLight];
    title.frame = CGRectMake(0, phone ? 40 : 80, W, phone ? 44 : 56);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:title];

    /* ── Single centered column ── */
    CGFloat colW = phone ? MIN(560, W - 56) : MIN(620, W - 120);
    CGFloat colX = (W - colW) / 2.0;
    CGFloat y = phone ? 100 : 168;

    /* ─────── STEP 1 ─────── */
    [root addSubview:[self stepEyebrowAt:CGRectMake(colX, y, colW, 14) text:@"STEP 1"]];
    y += 22;

    UILabel *step1H = [self headlineLabel:@"Rename your iPad"
                                     rect:CGRectMake(colX, y, colW, 30)];
    [root addSubview:step1H];
    y += 38;

    NSString *step1Body = @"iOS uses your iPad's name as the Personal Hotspot network. CarPlay needs this name to be at least 6 characters and to not contain words like iPad, iPhone, or iPod. You can change it in the iPad Settings app.";
    CGFloat body1H = [self heightForText:step1Body width:colW
                                    font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]];
    UILabel *body1 = [self bodyLabel:step1Body
                                rect:CGRectMake(colX, y, colW, body1H)];
    [root addSubview:body1];
    y += body1H + 22;

    /* Tappable example name pill */
    UILabel *exampleEyebrow = [[UILabel alloc] init];
    exampleEyebrow.attributedText = [[NSAttributedString alloc]
        initWithString:@"SUGGESTED NAME"
            attributes:@{ NSKernAttributeName: @(2.0),
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4],
                          NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] }];
    exampleEyebrow.frame = CGRectMake(colX, y, colW, 14);
    [root addSubview:exampleEyebrow];
    y += 20;

    UIView *pill = [self buildCopyPillWithText:@"Carplay-Receiver"
                                          rect:CGRectMake(colX, y, colW, 56)];
    [root addSubview:pill];
    y += 72;

    /* Open Settings button */
    UIButton *openBtn = [self primaryButton:@"Open Settings"
                                        rect:CGRectMake(colX, y, colW, 50)
                                      action:@selector(openSettingsTapped)];
    [root addSubview:openBtn];
    y += 70;

    /* Divider */
    UIView *div = [[UIView alloc] init];
    div.frame = CGRectMake(colX, y, colW, 1);
    div.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [root addSubview:div];
    y += 32;

    /* ─────── STEP 2 ─────── */
    [root addSubview:[self stepEyebrowAt:CGRectMake(colX, y, colW, 14) text:@"STEP 2"]];
    y += 22;

    UILabel *step2H = [self headlineLabel:@"Set your credentials"
                                     rect:CGRectMake(colX, y, colW, 30)];
    [root addSubview:step2H];
    y += 38;

    NSString *step2Body = @"After renaming your iPad and turning on Personal Hotspot, enter the hotspot name and password here. Showcase saves them and reuses them for every car.";
    CGFloat body2H = [self heightForText:step2Body width:colW
                                    font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]];
    UILabel *body2 = [self bodyLabel:step2Body
                                rect:CGRectMake(colX, y, colW, body2H)];
    [root addSubview:body2];
    y += body2H + 22;

    UIButton *credsBtn = [self primaryButton:@"Set Credentials"
                                        rect:CGRectMake(colX, y, colW, 50)
                                      action:@selector(credsTapped)];
    [root addSubview:credsBtn];

    if (scroll) {
        scroll.contentSize = CGSizeMake(W, y + 74);
    }
}

/* ─── helpers ─── */

- (UILabel *)stepEyebrowAt:(CGRect)rect text:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.attributedText = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{ NSKernAttributeName: @(2.5),
                          NSForegroundColorAttributeName: [UIColor whiteColor],
                          NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] }];
    return l;
}

- (UILabel *)headlineLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    return l;
}

- (UILabel *)bodyLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    l.numberOfLines = 0;
    return l;
}

- (CGFloat)heightForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font {
    CGSize bound = CGSizeMake(width, CGFLOAT_MAX);
    CGRect r = [text boundingRectWithSize:bound
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: font}
                                  context:nil];
    return ceilf(r.size.height);
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
    hint.text = @"Tap to copy";
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    hint.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
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
    self.pillHintLabel.text = @"Copied ✓";
    self.pillHintLabel.textColor = [UIColor whiteColor];
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
        if ([self.pillHintLabel.text isEqualToString:@"Copied ✓"]) {
            self.pillHintLabel.text = @"Tap to copy";
            self.pillHintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
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
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}
