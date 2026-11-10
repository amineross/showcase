/*
 * carplay_services.m - Wireless CarPlay protocol service for Showcase
 *
 * Provides mDNS, AirPlay RTSP, pairing, BAA authentication, timing, video,
 * audio, event commands, and HID transport.
 */

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <dns_sd.h>
#include <dispatch/dispatch.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonCrypto.h>
#include <Security/Security.h>
#include <sys/un.h>
#include <sys/sysctl.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <time.h>
#include <float.h>
#include <stdarg.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include "carplay_pair.h"
#include "baa_broker.h"
#include "vendor/monocypher/monocypher.h"

/*
 * Prefix every service log line with a monotonic timestamp.  The line-state
 * tracking matters because several packet dumps are emitted by many short
 * printf calls.
 */
static pthread_mutex_t g_service_log_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_service_log_at_line_start = true;

int showcase_service_log_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copied;
    va_copy(copied, args);
    int length = vsnprintf(NULL, 0, format, copied);
    va_end(copied);
    if (length < 0) {
        va_end(args);
        return length;
    }

    char *rendered = malloc((size_t)length + 1);
    if (!rendered) {
        va_end(args);
        return -1;
    }
    vsnprintf(rendered, (size_t)length + 1, format, args);
    va_end(args);

    pthread_mutex_lock(&g_service_log_lock);
    const char *cursor = rendered;
    const char *end = rendered + length;
    while (cursor < end) {
        if (g_service_log_at_line_start) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            fprintf(stdout, "[%lld.%06lld] ",
                    (long long)now.tv_sec,
                    (long long)(now.tv_nsec / 1000));
            g_service_log_at_line_start = false;
        }
        const char *newline = memchr(cursor, '\n', (size_t)(end - cursor));
        size_t chunk = newline ? (size_t)(newline - cursor + 1)
                               : (size_t)(end - cursor);
        fwrite(cursor, 1, chunk, stdout);
        cursor += chunk;
        if (newline) g_service_log_at_line_start = true;
    }
    pthread_mutex_unlock(&g_service_log_lock);
    free(rendered);
    return length;
}

#define printf showcase_service_log_printf

/* ── Forward declarations for IPC status events
 * (defined fully below near the IPC machinery, but used earlier in
 * pair-setup / pair-verify handlers). ── */
#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04
#define STATUS_PAIR_SETUP_STARTED   0x05   /* first pairing with this iPhone */
#define STATUS_AUTH_COMPLETE        0x06   /* accessory certificate accepted */
#define STATUS_SESSION_SETUP        0x07   /* control session negotiated     */
static void app_send_status(uint8_t code);

#define MSG_AUDIO_CONFIG 0x08
#define MSG_AUDIO_PACKET 0x09
#define MSG_BT_HANDOFF 0x0A
#define MSG_AUDIO_RENDER 0x0B
#define MSG_AUDIO_CONTROL 0x0C

#define AUDIO_CONTROL_PAUSE  0
#define AUDIO_CONTROL_RESUME 1
#define AUDIO_CONTROL_FLUSH  2
#define AUDIO_CONTROL_STOP   3

/* ── Configuration ── */
#define AIRPLAY_PORT 7000
#define DEVICE_ID    "90:B9:31:AC:86:A0"
#define DEVICE_ID_RAW "90B931AC86A0"        /* no colons, for _raop._tcp name */
#define DEVICE_ID_INT "159125076739744"     /* 0x90B931AC86A0 as decimal — for HTTP headers */
#define MODEL_NAME   "AirPlayGeneric1,1"    /* Apple SDK default for CarPlay receivers */

/* Runtime-configurable display name (the "car name" — what shows up in
 * Settings → General → CarPlay on the iPhone). Set via --name argv. */
static char g_instance_name[32] = "RoadLink";
static char g_raop_name[64]     = DEVICE_ID_RAW "@" "RoadLink";
static uint16_t g_display_width = 800;
static uint16_t g_display_height = 480;
static uint16_t g_display_fps = 60;
static int g_screen_receive_buffer = 176 * 1024;
static bool g_baa_broker_mode = false;
/* false: leave CarPlay audio on the sender (its speaker or its own car
 * Bluetooth), which is the Showcase default. true: claim MainAudio and play
 * the negotiated buffered/low-latency streams on this receiver. */
static bool g_receiver_audio = false;
/* Places CarPlay's dock on the right edge, for right-hand-drive cars and for
 * displays mounted to the driver's right. */
static bool g_right_hand_drive = false;

static void parse_args(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) &&
            i + 1 < argc) {
            strncpy(g_instance_name, argv[i+1], sizeof(g_instance_name) - 1);
            g_instance_name[sizeof(g_instance_name) - 1] = '\0';
            snprintf(g_raop_name, sizeof(g_raop_name),
                     "%s@%s", DEVICE_ID_RAW, g_instance_name);
            i++;
        } else if (!strcmp(argv[i], "--width") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 640 && value <= UINT16_MAX)
                g_display_width = (uint16_t)value;
        } else if (!strcmp(argv[i], "--height") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 360 && value <= UINT16_MAX)
                g_display_height = (uint16_t)value;
        } else if (!strcmp(argv[i], "--fps") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 30 && value <= 60)
                g_display_fps = (uint16_t)value;
        } else if (!strcmp(argv[i], "--screen-rcvbuf") && i + 1 < argc) {
            long value = strtol(argv[++i], NULL, 10);
            if (value >= 64 * 1024 && value <= 4 * 1024 * 1024)
                g_screen_receive_buffer = (int)value;
        } else if (!strcmp(argv[i], "--right-hand-drive")) {
            g_right_hand_drive = true;
        } else if (!strcmp(argv[i], "--audio") && i + 1 < argc) {
            g_receiver_audio = strcmp(argv[++i], "receiver") == 0;
        } else if (!strcmp(argv[i], "--baa-broker")) {
            g_baa_broker_mode = true;
        }
    }
}
/* SRV hostname: NULL = use iPad's real hostname (RoadLink-CarPlay.local.)
 * which already has A/AAAA records. Using a custom hostname like
 * "RoadLink.local." fails because mDNSResponder doesn't auto-create
 * A/AAAA records for it, so the iPhone can't resolve it. */
#define SRV_HOSTNAME  NULL
#define SOURCE_VERSION "509.0"
#define CTRL_CONNECT_ATTEMPTS 3   /* attempts per resolved port */
#define CTRL_RESOLVE_ROUNDS   10  /* how many times to re-resolve */
#define CTRL_RETRY_SEC 2
#define MDNS_REANNOUNCE_SECONDS 300
#define MDNS_REANNOUNCE_INTERVAL 3

/* Ed25519 keypair — REAL key generated via PyNaCl.
 * pk = 32-byte Ed25519 public key, hex-encoded for TXT record.
 * sk = 32-byte Ed25519 private seed, stored for pair-setup/verify. */
#define HK_PK "1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f"
#define HK_PI "29f0a5dc-2c2a-4b3e-9e5d-1a6c85f201a3"   /* UUID format, not MAC */

/* Ed25519 private key seed (32 bytes) — needed for pair-verify signatures */
static const uint8_t ed25519_sk[32] = {
    0x95, 0x74, 0xdb, 0x39, 0x5b, 0x64, 0x5e, 0xae,
    0x89, 0xd1, 0xfa, 0x7d, 0x01, 0xb7, 0xa4, 0x6b,
    0x20, 0xa4, 0x45, 0x80, 0x19, 0xd7, 0x8e, 0x56,
    0x69, 0x25, 0xe5, 0x42, 0xed, 0x6a, 0xf3, 0x06
};
static const uint8_t ed25519_pk[32] = {
    0x1b, 0x15, 0xf0, 0xad, 0x62, 0xc8, 0x94, 0x72,
    0x1c, 0x40, 0x97, 0x65, 0x18, 0x01, 0xe6, 0x28,
    0x45, 0x45, 0x1a, 0x18, 0x3c, 0x8d, 0xf8, 0xaf,
    0x7d, 0x6b, 0x20, 0x43, 0x08, 0x23, 0x58, 0x6f
};

/* Features bitmask — UxPlay base + MFi bit 26 restored for CarPlay:
 * Lower 32 = 0x5E7FFEE6:
 *   Bits 1-2:  Video/Photo
 *   Bit 5:     VideoFairPlayFP
 *   Bits 6-13: Volume/HTTP/Screen/ScreenRotate/Audio/etc.
 *   Bit 14:    FPSAPv2pt5_AES_GCM (FairPlay software auth)
 *   Bits 15-25: various audio/video capabilities
 *   Bit 26:    MFi-SAP auth (REQUIRED for CarPlay — iPhone won't connect without it)
 *              TomSignalius has it, wiomoc has it. Auth will need stubbing later.
 *   Bit 27,29-30: other capabilities
 * Upper 32 with HK = 0x61:
 *   Bit 0: Car (CarPlay capability)
 *   Bit 5: CarPlayControl
 *   Bit 6: HKPairingAndEncrypt
 * Upper 32 without HK = 0x21:
 *   Bit 0: Car
 *   Bit 5: CarPlayControl
 *
 * Bit 26 (0x04000000) = MFi-SAP v1 auth (auth-setup with raw 33-byte format).
 * Bit 22 (0x00400000) = AudioUnencrypted. */
/*
 * Match Apple's CarPlay Simulator advertisement exactly. Codec support is
 * negotiated through /info audioFormats; bit 20 is not an AAC-LC flag.
 */
#define FEATURES_WITH_HK   "0x4040280,0x61"
#define FEATURES_NO_HK     "0x4040280,0x21"

/* HK ON — bit 38 (HKPairingAndEncrypt). The newer Apple SDK unconditionally
 * sets this bit. iOS 18 may require it for CarPlay connections.
 * Without it, the iPhone may refuse to connect to port 7000. */
static bool g_useHK = true;

/* Global pairing context — initialized in main(), used by pair handlers */
static pair_ctx_t *g_pair = NULL;
#define PAIRING_STORE_DIR  "/var/mobile/Library/Showcase"
#define PAIRING_STORE_PATH PAIRING_STORE_DIR "/paired-controllers.plist"
#define BT_ID_PATH "/tmp/showcase_bt_id"

static bool ensure_pair_context(void) {
    if (g_pair) return true;
    g_pair = pair_ctx_create(ed25519_sk, ed25519_pk, NULL);
    if (!g_pair) return false;

    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:@PAIRING_STORE_PATH];
        if (!data) {
            printf("[PAIR] No saved controller registry yet\n");
            return true;
        }
        NSError *error = nil;
        id value = [NSPropertyListSerialization
            propertyListWithData:data
                         options:NSPropertyListImmutable
                          format:NULL
                           error:&error];
        if (![value isKindOfClass:[NSArray class]]) {
            printf("[PAIR] Saved controller registry is invalid: %s\n",
                   error.localizedDescription.UTF8String ?: "unexpected root");
            return true;
        }
        for (id entry in (NSArray *)value) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSData *identifier = entry[@"identifier"];
            NSData *publicKey = entry[@"publicKey"];
            if (![identifier isKindOfClass:[NSData class]] ||
                ![publicKey isKindOfClass:[NSData class]] ||
                publicKey.length != 32)
                continue;
            pair_ctx_add_peer(g_pair, identifier.bytes, identifier.length,
                              publicKey.bytes);
        }
        printf("[PAIR] Restored %zu paired controller(s)\n",
               pair_ctx_peer_count(g_pair));
    }
    return true;
}

static void save_pairing_registry(void) {
    if (!g_pair) return;
    @autoreleasepool {
        NSMutableArray *entries = [NSMutableArray array];
        size_t count = pair_ctx_peer_count(g_pair);
        for (size_t i = 0; i < count; i++) {
            uint8_t identifier[128], publicKey[32];
            size_t identifierLength = 0;
            if (pair_ctx_get_peer(g_pair, i, identifier, sizeof(identifier),
                                  &identifierLength, publicKey) != 0)
                continue;
            [entries addObject:@{
                @"identifier": [NSData dataWithBytes:identifier
                                               length:identifierLength],
                @"publicKey": [NSData dataWithBytes:publicKey length:32]
            }];
        }
        NSError *error = nil;
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:entries
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&error];
        mkdir("/var/mobile/Library", 0755);
        mkdir(PAIRING_STORE_DIR, 0755);
        if (!plist || ![plist writeToFile:@PAIRING_STORE_PATH
                                  options:NSDataWritingAtomic
                                    error:&error]) {
            printf("[PAIR] ERROR: Could not persist controller registry: %s\n",
                   error.localizedDescription.UTF8String ?: "serialization failed");
            return;
        }
        chmod(PAIRING_STORE_PATH, 0600);
        chown(PAIRING_STORE_PATH, 501, 501);
        printf("[PAIR] Persisted %zu paired controller(s)\n", entries.count);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * BAA Certificate (for auth-setup MFi-SAP response)
 * ═══════════════════════════════════════════════════════════════ */
static uint8_t   *g_baa_leaf_der = NULL;
static int        g_baa_leaf_len = 0;
static uint8_t   *g_baa_inter_der = NULL;
static int        g_baa_inter_len = 0;
static bool       g_baa_ready = false;
static SecKeyRef  g_baa_broker_key = NULL;

static void load_baa_from_broker(void) {
    printf("[BAA] Loading preheated certificate from Showcase...\n");
    int rc = -1;
    for (int attempt = 0; attempt < 30 && rc != 0; attempt++) {
        rc = baa_broker_get_certs(&g_baa_leaf_der, &g_baa_leaf_len,
                                  &g_baa_inter_der, &g_baa_inter_len);
        if (rc != 0) usleep(100000);
    }
    if (rc == 0) {
        g_baa_ready = true;
        printf("[BAA] Leaf=%d Inter=%d — preheated and ready\n",
               g_baa_leaf_len, g_baa_inter_len);
    } else {
        printf("[BAA] Could not retrieve preheated certificate (rc=%d)\n", rc);
    }
}

/* Apple issues the certificate for as long as Showcase asks, up to a year,
 * where the default is about two days. The key stays in the Secure Enclave;
 * its wrapped handle, saved next to the certificate, only works on this
 * device and lets a new broker start without internet. */
#define BAA_VALIDITY_SECONDS     (365 * 24 * 3600)
#define BAA_RENEW_SECONDS        (30 * 24 * 3600)
#define BAA_MIN_LEFT_SECONDS     3600
#define BAA_IDENTITY_PATH        PAIRING_STORE_DIR "/identity.plist"

static CFAbsoluteTime g_baa_not_after = 0;

static CFAbsoluteTime baa_certificate_not_after(SecCertificateRef certificate) {
    typedef CFAbsoluteTime (*NotAfterFunc)(SecCertificateRef);
    static NotAfterFunc notAfter;
    if (!notAfter) notAfter = (NotAfterFunc)dlsym(RTLD_DEFAULT, "SecCertificateNotValidAfter");
    return notAfter && certificate ? notAfter(certificate) : 0;
}

static bool baa_key_matches_leaf(SecKeyRef key, NSData *leaf) {
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)leaf);
    if (!certificate) return false;
    SecKeyRef certificateKey = SecCertificateCopyPublicKey(certificate);
    SecKeyRef ownKey = SecKeyCopyPublicKey(key);
    NSData *a = certificateKey ? (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(certificateKey, NULL) : nil;
    NSData *b = ownKey ? (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(ownKey, NULL) : nil;
    if (certificateKey) CFRelease(certificateKey);
    if (ownKey) CFRelease(ownKey);
    CFRelease(certificate);
    return a && [a isEqualToData:b];
}

static CFAbsoluteTime baa_leaf_not_after(NSData *leaf) {
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)leaf);
    CFAbsoluteTime notAfter = baa_certificate_not_after(certificate);
    if (certificate) CFRelease(certificate);
    return notAfter;
}

static bool baa_broker_key_usable(void);

/* An identity is @{ "key": SecKeyRef, "leaf": NSData, "intermediate": NSData }. */
static bool use_baa_identity(NSDictionary *identity) {
    NSData *leaf = identity[@"leaf"], *intermediate = identity[@"intermediate"];
    uint8_t *leafCopy = malloc(leaf.length), *intermediateCopy = malloc(intermediate.length);
    if (!leafCopy || !intermediateCopy) {
        free(leafCopy);
        free(intermediateCopy);
        return false;
    }
    memcpy(leafCopy, leaf.bytes, leaf.length);
    memcpy(intermediateCopy, intermediate.bytes, intermediate.length);
    free(g_baa_leaf_der);
    free(g_baa_inter_der);
    g_baa_leaf_der = leafCopy;
    g_baa_inter_der = intermediateCopy;
    g_baa_leaf_len = (int)leaf.length;
    g_baa_inter_len = (int)intermediate.length;
    if (g_baa_broker_key) CFRelease(g_baa_broker_key);
    g_baa_broker_key = (SecKeyRef)CFRetain((__bridge CFTypeRef)identity[@"key"]);
    g_baa_not_after = baa_leaf_not_after(leaf);
    g_baa_ready = true;
    return true;
}

static NSDictionary *load_saved_baa_identity(void) {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:@BAA_IDENTITY_PATH];
    NSData *handle = saved[@"key"], *leaf = saved[@"leaf"], *intermediate = saved[@"intermediate"];
    NSString *token = saved[@"token"];
    if (![handle isKindOfClass:[NSData class]] || ![leaf isKindOfClass:[NSData class]] ||
        ![intermediate isKindOfClass:[NSData class]] || ![token isKindOfClass:[NSString class]])
        return nil;
    if (baa_leaf_not_after(leaf) - CFAbsoluteTimeGetCurrent() < BAA_MIN_LEFT_SECONDS) return nil;

    /* Without "toid" in the attributes, the token makes a new key instead. */
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)handle, (__bridge CFDictionaryRef)@{
        (id)kSecAttrTokenID: token,
        @"toid": handle,
        (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate,
    }, &error);
    if (error) CFRelease(error);
    if (!key) return nil;
    if (!baa_key_matches_leaf(key, leaf)) {
        printf("[BAA] Saved key no longer matches its certificate\n");
        CFRelease(key);
        return nil;
    }
    return @{ @"key": (__bridge_transfer id)key, @"leaf": leaf, @"intermediate": intermediate };
}

static void save_baa_identity(NSDictionary *identity) {
    NSDictionary *attributes = (__bridge_transfer NSDictionary *)
        SecKeyCopyAttributes((__bridge SecKeyRef)identity[@"key"]);
    NSData *handle = attributes[@"toid"];
    NSString *token = attributes[(id)kSecAttrTokenID];
    if (![handle isKindOfClass:[NSData class]] || ![token isKindOfClass:[NSString class]]) return;
    NSData *plist = [NSPropertyListSerialization
        dataWithPropertyList:@{ @"key": handle, @"token": token,
                                @"leaf": identity[@"leaf"],
                                @"intermediate": identity[@"intermediate"] }
                      format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    mkdir("/var/mobile/Library", 0755);
    mkdir(PAIRING_STORE_DIR, 0755);
    char temporary[] = PAIRING_STORE_DIR "/.identity.XXXXXX";
    int fd = mkstemp(temporary); /* created 0600, owner root */
    if (fd < 0) return;
    bool written = plist && write(fd, plist.bytes, plist.length) == (ssize_t)plist.length;
    close(fd);
    if (written && rename(temporary, BAA_IDENTITY_PATH) == 0)
        printf("[BAA] Certificate saved for offline starts\n");
    else
        unlink(temporary);
}

static NSDictionary *request_baa(NSDictionary *options, NSError **failure) {
    void *framework = dlopen(
        "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
        RTLD_NOW);
    if (!framework) {
        framework = dlopen(
            "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
            RTLD_NOW);
    }
    if (!framework) {
        printf("[BAA] Cannot load DeviceIdentity framework\n");
        return nil;
    }

    typedef void (^DIBlock)(id, id, id);
    typedef void (*DIFunc)(id, id, DIBlock);
    DIFunc issue = (DIFunc)dlsym(
        framework, "DeviceIdentityIssueClientCertificateWithCompletion");
    if (!issue) {
        printf("[BAA] DeviceIdentity issuance function unavailable\n");
        return nil;
    }

    __block NSDictionary *identity = nil;
    __block NSError *issueError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    issue(nil, options, ^(id key, id certificates, id error) {
        NSArray *chain = (NSArray *)certificates;
        if (error) {
            NSLog(@"[BAA] Preheat error: %@", error);
            issueError = error;
        } else if (!key || [chain count] < 2) {
            printf("[BAA] Preheat returned an incomplete certificate chain\n");
        } else {
            identity = @{
                @"key": key,
                @"leaf": (__bridge_transfer NSData *)SecCertificateCopyData(
                    (__bridge SecCertificateRef)chain[0]),
                @"intermediate": (__bridge_transfer NSData *)SecCertificateCopyData(
                    (__bridge SecCertificateRef)chain[1]),
            };
        }
        dispatch_semaphore_signal(semaphore);
    });

    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 45LL * NSEC_PER_SEC)) != 0) {
        printf("[BAA] Preheat timed out\n");
        return nil;
    }
    if (failure) *failure = issueError;
    return identity;
}

static NSDictionary *issue_baa_identity(void) {
    NSError *error = nil;
    NSDictionary *identity = request_baa(@{ @"Validity": @(BAA_VALIDITY_SECONDS) }, &error);
    /* An iOS that rejects the option still issues the default certificate. */
    if (!identity && error) identity = request_baa(@{}, NULL);
    if (identity) save_baa_identity(identity);
    return identity;
}

static NSDictionary *g_baa_renewed = nil;

static bool issue_baa_for_broker(void) {
    NSDictionary *saved = load_saved_baa_identity();
    if (saved && use_baa_identity(saved) && baa_broker_key_usable()) {
        printf("[BAA] Saved certificate loaded, valid %.0f more hours\n",
               (g_baa_not_after - CFAbsoluteTimeGetCurrent()) / 3600.0);
        /* Renew a month ahead in the background; offline, the saved one keeps working. */
        if (g_baa_not_after - CFAbsoluteTimeGetCurrent() < BAA_RENEW_SECONDS) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSDictionary *renewed = issue_baa_identity();
                @synchronized ([NSDictionary class]) { g_baa_renewed = renewed; }
            });
        }
        return true;
    }

    printf("[BAA] Preheating DeviceIdentity certificate before hotspot...\n");
    NSDictionary *identity = issue_baa_identity();
    if (!identity || !use_baa_identity(identity)) return false;
    printf("[BAA] Preheated: leaf=%d intermediate=%d, valid %.0f hours\n",
           g_baa_leaf_len, g_baa_inter_len,
           g_baa_not_after > 0 ? (g_baa_not_after - CFAbsoluteTimeGetCurrent()) / 3600.0 : -1.0);
    return true;
}

static void baa_broker_handle_client(int client) {
    uint8_t header[BAA_BROKER_HEADER_SIZE];
    if (!baa_read_exact(client, header, sizeof(header)) ||
        memcmp(header, BAA_BROKER_MAGIC, 4) != 0) return;
    uint8_t opcode = header[4];
    uint32_t requestLength = baa_read_le32(header + 8);
    if (requestLength > BAA_BROKER_MAX_PAYLOAD) return;

    uint8_t *request = NULL;
    if (requestLength > 0) {
        request = malloc(requestLength);
        if (!request || !baa_read_exact(client, request, requestLength)) {
            free(request);
            return;
        }
    }

    uint8_t status = BAA_STATUS_BAD_REQUEST;
    uint8_t *response = NULL;
    uint32_t responseLength = 0;
    if (!g_baa_ready || !g_baa_broker_key) {
        status = BAA_STATUS_NOT_READY;
    } else if (opcode == BAA_OP_GET_CERTS && requestLength == 0) {
        responseLength = 8U + (uint32_t)g_baa_leaf_len +
                         (uint32_t)g_baa_inter_len;
        response = malloc(responseLength);
        if (response) {
            baa_write_le32(response, (uint32_t)g_baa_leaf_len);
            baa_write_le32(response + 4, (uint32_t)g_baa_inter_len);
            memcpy(response + 8, g_baa_leaf_der, g_baa_leaf_len);
            memcpy(response + 8 + g_baa_leaf_len,
                   g_baa_inter_der, g_baa_inter_len);
            status = BAA_STATUS_OK;
        }
    } else if (opcode == BAA_OP_SIGN &&
               requestLength > 0 && requestLength <= 4096) {
        NSData *message = [NSData dataWithBytes:request length:requestLength];
        CFErrorRef error = NULL;
        CFDataRef signature = SecKeyCreateSignature(
            g_baa_broker_key,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)message, &error);
        if (signature) {
            responseLength = (uint32_t)CFDataGetLength(signature);
            response = malloc(responseLength);
            if (response) {
                memcpy(response, CFDataGetBytePtr(signature), responseLength);
                status = BAA_STATUS_OK;
            }
            CFRelease(signature);
        } else {
            status = BAA_STATUS_SIGN_FAILED;
            if (error) {
                NSLog(@"[BAA] Broker sign failed: %@", error);
                CFRelease(error);
            }
        }
    }
    free(request);

    baa_make_header(header, opcode, status, responseLength);
    baa_write_exact(client, header, sizeof(header));
    if (responseLength > 0)
        baa_write_exact(client, response, responseLength);
    free(response);
}

/* The key lives behind a token daemon connection that iOS drops when it sits
 * idle, after which signing fails. Signing every 30 s keeps it open; a broker
 * that can no longer sign exits so Showcase starts a fresh one. */
static bool baa_broker_key_usable(void) {
    static const uint8_t probe[] = "Showcase BAA keepalive";
    CFErrorRef error = NULL;
    CFDataRef signature = SecKeyCreateSignature(
        g_baa_broker_key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        (__bridge CFDataRef)[NSData dataWithBytes:probe length:sizeof(probe) - 1], &error);
    if (signature) CFRelease(signature);
    if (error) {
        NSLog(@"[BAA] Broker keepalive failed: %@", error);
        CFRelease(error);
    }
    return signature != NULL;
}

static int run_baa_broker(void) {
    if (!issue_baa_for_broker()) return 1;

    unlink(BAA_BROKER_PATH);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, BAA_BROKER_PATH,
            sizeof(address.sun_path) - 1);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        listen(server, 4) < 0) {
        printf("[BAA] Broker socket failed: %s\n", strerror(errno));
        close(server);
        return 1;
    }
    chmod(BAA_BROKER_PATH, 0600);
    printf("[BAA] Broker ready on %s\n", BAA_BROKER_PATH);

    while (1) {
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(server, &ready);
        struct timeval wait = { .tv_sec = 30, .tv_usec = 0 };
        int count = select(server + 1, &ready, NULL, NULL, &wait);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) break;
        NSDictionary *renewed = nil;
        @synchronized ([NSDictionary class]) { renewed = g_baa_renewed; g_baa_renewed = nil; }
        if (renewed && use_baa_identity(renewed))
            printf("[BAA] Switched to the renewed certificate\n");
        if (count == 0) {
            bool usable;
            @autoreleasepool { usable = baa_broker_key_usable(); }
            if (!usable) break;
            /* Exit before the certificate expires so Showcase starts a broker that renews it. */
            if (g_baa_not_after > 0 &&
                g_baa_not_after - CFAbsoluteTimeGetCurrent() < BAA_MIN_LEFT_SECONDS)
                break;
            continue;
        }
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        @autoreleasepool {
            baa_broker_handle_client(client);
        }
        close(client);
    }
    close(server);
    unlink(BAA_BROKER_PATH);
    printf("[BAA] Broker exiting\n");
    return 0;
}

/* ═══════════════════════════════════════════════════════════════
 * Encrypted Transport (ChaCha20-Poly1305) after pair-verify
 *
 * Frame format: [2-byte LE length][ciphertext][16-byte auth tag]
 * - The 2-byte length header is used as AAD
 * - 8-byte nonce counter (LE), starts at 0, increments per message
 * - Apple's transport reads records up to 16 KiB but emits 1 KiB records
 * ═══════════════════════════════════════════════════════════════ */

#define ENCRYPTED_MAX_READ_SIZE  (16 * 1024)
#define ENCRYPTED_MAX_WRITE_SIZE 1024

typedef struct {
    uint8_t readKey[32];
    uint8_t writeKey[32];
    uint64_t readNonce;
    uint64_t writeNonce;
    bool active;
} encrypted_ctx_t;

static encrypted_ctx_t g_enc = {0};
static encrypted_ctx_t g_event_enc = {0};
static dispatch_semaphore_t g_event_send_lock = NULL;
static bool process_event_command_frame(const uint8_t *bytes, size_t length);

/* Decrypt one encrypted frame from the socket.
 * Returns plaintext length, -2 on idle timeout, or -1 on error.
 * Caller provides outBuf (at least 16*1024 bytes). */
static int enc_recv_frame(int sock, encrypted_ctx_t *enc, uint8_t *outBuf, size_t outBufSize) {
    /* Read 2-byte LE length header */
    uint8_t hdr[2];
    size_t hdrRead = 0;
    while (hdrRead < 2) {
        ssize_t n = recv(sock, hdr + hdrRead, 2 - hdrRead, 0);
        if (n == 0) return -1;
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                if (hdrRead == 0) return -2;
                continue;
            }
            return -1;
        }
        hdrRead += n;
    }
    uint16_t ptLen = hdr[0] | ((uint16_t)hdr[1] << 8);
    if (ptLen == 0 || ptLen > outBufSize) {
        printf("[ENC] Bad frame length: %u\n", ptLen);
        return -1;
    }

    /* Read ciphertext + 16-byte auth tag */
    size_t totalRead = ptLen + 16;
    uint8_t *frame = malloc(totalRead);
    if (!frame) return -1;
    size_t frameRead = 0;
    while (frameRead < totalRead) {
        ssize_t n = recv(sock, frame + frameRead, totalRead - frameRead, 0);
        if (n == 0) { free(frame); return -1; }
        if (n < 0) {
            int saved = errno;
            if (saved == EAGAIN || saved == EWOULDBLOCK) {
                if (frameRead == 0) { free(frame); return -2; }
                continue;
            }
            free(frame);
            return -1;
        }
        frameRead += n;
    }

    /* Build 12-byte nonce: 4 zero bytes + 8-byte LE counter */
    uint8_t nonce12[12] = {0};
    memcpy(nonce12 + 4, &enc->readNonce, 8);  /* LE on LE system */

    /* Decrypt with ChaCha20-Poly1305 */
    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, enc->readKey, nonce12);
    int ret = crypto_aead_read(&ctx, outBuf, frame + ptLen,
                               hdr, sizeof(hdr), frame, ptLen);
    crypto_wipe(&ctx, sizeof(ctx));
    free(frame);

    if (ret != 0) {
        printf("[ENC] ChaCha20-Poly1305 decrypt FAILED (nonce=%llu)\n", enc->readNonce);
        return -1;
    }
    enc->readNonce++;
    return ptLen;
}

/* Encrypt and send one frame.
 * Returns 0 on success, -1 on error. */
static int enc_send_frame(int sock, encrypted_ctx_t *enc, const uint8_t *data, size_t dataLen) {
    if (dataLen == 0 || dataLen > ENCRYPTED_MAX_WRITE_SIZE) {
        printf("[ENC] Frame too large: %zu\n", dataLen);
        return -1;
    }

    /* 2-byte LE length header (AAD) */
    uint8_t hdr[2];
    hdr[0] = dataLen & 0xFF;
    hdr[1] = (dataLen >> 8) & 0xFF;

    /* Build 12-byte nonce */
    uint8_t nonce12[12] = {0};
    memcpy(nonce12 + 4, &enc->writeNonce, 8);

    /* Encrypt */
    uint8_t *ct = malloc(dataLen);
    uint8_t tag[16];
    if (!ct) return -1;

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, enc->writeKey, nonce12);
    crypto_aead_write(&ctx, ct, tag, hdr, sizeof(hdr),
                      data, dataLen);
    crypto_wipe(&ctx, sizeof(ctx));

    /* Send: header + ciphertext + tag */
    size_t totalLen = 2 + dataLen + 16;
    uint8_t *out = malloc(totalLen);
    if (!out) { free(ct); return -1; }
    memcpy(out, hdr, 2);
    memcpy(out + 2, ct, dataLen);
    memcpy(out + 2 + dataLen, tag, 16);
    free(ct);

    size_t sent = 0;
    while (sent < totalLen) {
        ssize_t n = send(sock, out + sent, totalLen - sent, 0);
        if (n <= 0) { free(out); return -1; }
        sent += n;
    }
    free(out);
    enc->writeNonce++;
    return 0;
}

/*
 * Encrypt a plaintext byte stream using the same segmentation as Apple's
 * NetTransportChaCha20Poly1305 writer. HTTP headers and bodies remain one
 * continuous plaintext stream; only the authenticated transport records are
 * split. This is required for /info responses containing OEM icon data.
 */
static int enc_send_stream(int sock, encrypted_ctx_t *enc,
                           const uint8_t *data, size_t dataLen) {
    size_t offset = 0;
    while (offset < dataLen) {
        size_t chunk = dataLen - offset;
        if (chunk > ENCRYPTED_MAX_WRITE_SIZE)
            chunk = ENCRYPTED_MAX_WRITE_SIZE;
        if (enc_send_frame(sock, enc, data + offset, chunk) < 0)
            return -1;
        offset += chunk;
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════
 * HTTP Request Parser
 * ═══════════════════════════════════════════════════════════════ */

typedef struct {
    char method[32];
    char path[512];
    char protocol[16];
    const uint8_t *headerStart;
    size_t headerLen;
    const uint8_t *body;
    size_t bodyLen;
    size_t contentLength;
    int cseq;
    char contentType[128];
    char xAppleHKP[32];
    char xApplePD[16];
    char xAppleAT[16];
} HTTPReq;

static bool parse_http(const uint8_t *buf, size_t len, HTTPReq *r) {
    memset(r, 0, sizeof(*r));
    if (len < 10) return false;

    /* Request line: METHOD SP PATH SP PROTOCOL CRLF */
    const char *s = (const char *)buf;
    const char *end = s + len;
    const char *lineEnd = memmem(s, len, "\r\n", 2);
    if (!lineEnd) return false;

    /* Method */
    const char *sp1 = memchr(s, ' ', lineEnd - s);
    if (!sp1) return false;
    size_t n = sp1 - s;
    if (n >= sizeof(r->method)) n = sizeof(r->method) - 1;
    memcpy(r->method, s, n);

    /* Path */
    const char *sp2 = memchr(sp1 + 1, ' ', lineEnd - sp1 - 1);
    if (!sp2) return false;
    n = sp2 - (sp1 + 1);
    if (n >= sizeof(r->path)) n = sizeof(r->path) - 1;
    memcpy(r->path, sp1 + 1, n);

    /* Protocol */
    n = lineEnd - (sp2 + 1);
    if (n >= sizeof(r->protocol)) n = sizeof(r->protocol) - 1;
    memcpy(r->protocol, sp2 + 1, n);

    /* Headers */
    r->headerStart = (const uint8_t *)(lineEnd + 2);
    const char *bodyMark = memmem(lineEnd, end - lineEnd, "\r\n\r\n", 4);
    if (bodyMark) {
        /* bodyMark == lineEnd means a request without headers. */
        r->headerLen = bodyMark > lineEnd ? bodyMark - (const char *)r->headerStart : 0;
        r->body = (const uint8_t *)(bodyMark + 4);
        r->bodyLen = (buf + len) - r->body;
    } else {
        r->headerLen = (buf + len) - (const uint8_t *)r->headerStart;
    }

    /* Parse key headers */
    const char *hp = (const char *)r->headerStart;
    const char *hend = hp + r->headerLen;
    while (hp < hend) {
        const char *le = memmem(hp, end - hp, "\r\n", 2);
        if (!le || le > hend) break;
        const char *colon = memchr(hp, ':', le - hp);
        if (colon) {
            size_t nameLen = colon - hp;
            const char *val = colon + 1;
            while (val < le && *val == ' ') val++;
            size_t valLen = le - val;

            if (nameLen == 14 && strncasecmp(hp, "Content-Length", 14) == 0) {
                /* Larger than any buffer here; the request is dropped. */
                unsigned long length = strtoul(val, NULL, 10);
                r->contentLength = length > 1048576 ? 1048576 : (size_t)length;
            } else if (nameLen == 12 && strncasecmp(hp, "Content-Type", 12) == 0) {
                if (valLen < sizeof(r->contentType))
                    memcpy(r->contentType, val, valLen);
            } else if (nameLen == 12 && strncasecmp(hp, "X-Apple-HKP", 11) == 0 && nameLen >= 11) {
                if (valLen < sizeof(r->xAppleHKP))
                    memcpy(r->xAppleHKP, val, valLen);
            } else if (nameLen == 10 && strncasecmp(hp, "X-Apple-PD", 10) == 0) {
                if (valLen < sizeof(r->xApplePD))
                    memcpy(r->xApplePD, val, valLen);
            } else if (nameLen == 10 && strncasecmp(hp, "X-Apple-AT", 10) == 0) {
                if (valLen < sizeof(r->xAppleAT))
                    memcpy(r->xAppleAT, val, valLen);
            } else if (nameLen == 4 && strncasecmp(hp, "CSeq", 4) == 0) {
                r->cseq = atoi(val);
            }
        }
        hp = le + 2;
    }
    return r->method[0] != '\0';
}

/* BEGIN request framing */
typedef enum { REQUEST_INCOMPLETE, REQUEST_READY, REQUEST_INVALID } RequestState;

/* Looks for one whole request at the start of buf. READY and INVALID set
 * *length to the bytes to remove; INVALID with the whole buffer means drop it. */
static RequestState take_request(const uint8_t *buf, size_t used, size_t capacity,
                                 HTTPReq *r, size_t *length) {
    *length = 0;
    if (!parse_http(buf, used, r) || !r->body) {
        const uint8_t *headerEnd = memmem(buf, used, "\r\n\r\n", 4);
        if (!headerEnd) {
            if (used < capacity) return REQUEST_INCOMPLETE;
            *length = used;
            return REQUEST_INVALID;
        }
        *length = (size_t)(headerEnd + 4 - buf);
        return REQUEST_INVALID;
    }
    size_t headerSize = (size_t)(r->body - buf);
    if (r->contentLength > capacity - headerSize) {
        *length = used;
        return REQUEST_INVALID;
    }
    if (used - headerSize < r->contentLength) return REQUEST_INCOMPLETE;
    r->bodyLen = r->contentLength;
    *length = headerSize + r->contentLength;
    return REQUEST_READY;
}
/* END request framing */

/* ═══════════════════════════════════════════════════════════════
 * HTTP Response Helper
 * ═══════════════════════════════════════════════════════════════ */

static void send_response(int sock, const char *proto, int status,
                          const char *statusText, const char *contentType,
                          const uint8_t *body, size_t bodyLen, int cseq) {
    @autoreleasepool {
        NSMutableString *hdr = [NSMutableString string];
        [hdr appendFormat:@"%s %d %s\r\n", proto, status, statusText];
        [hdr appendFormat:@"Server: AirTunes/%s\r\n", SOURCE_VERSION];
        if (cseq > 0)
            [hdr appendFormat:@"CSeq: %d\r\n", cseq];
        if (contentType)
            [hdr appendFormat:@"Content-Type: %s\r\n", contentType];
        [hdr appendFormat:@"Content-Length: %zu\r\n", bodyLen];
        [hdr appendString:@"\r\n"];

        const char *h = hdr.UTF8String;
        size_t hLen = strlen(h);

        if (g_enc.active) {
            /* Encrypted mode: build one HTTP byte stream, then segment it
             * into Apple's 1 KiB authenticated transport records. */
            size_t totalPt = hLen + bodyLen;
            uint8_t *ptBuf = malloc(totalPt);
            if (ptBuf) {
                memcpy(ptBuf, h, hLen);
                if (body && bodyLen > 0) memcpy(ptBuf + hLen, body, bodyLen);
                size_t recordCount =
                    (totalPt + ENCRYPTED_MAX_WRITE_SIZE - 1) /
                    ENCRYPTED_MAX_WRITE_SIZE;
                printf("[ENC] Encrypting response: %zu bytes in %zu "
                       "record(s) (first nonce=%llu)\n",
                       totalPt, recordCount, g_enc.writeNonce);
                if (enc_send_stream(sock, &g_enc, ptBuf, totalPt) < 0) {
                    printf("[ENC] ERROR: Failed to send encrypted response\n");
                }
                free(ptBuf);
            }
        } else {
            /* Plaintext mode */
            send(sock, h, hLen, 0);
            if (body && bodyLen > 0)
                send(sock, body, bodyLen, 0);
        }
    }
}

static void send_ok(int sock, const HTTPReq *r) {
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    send_response(sock, rtsp ? "RTSP/1.0" : "HTTP/1.1",
                  200, "OK", NULL, NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * TLV8 Parser (for HomeKit pair-setup/verify)
 * ═══════════════════════════════════════════════════════════════ */

static void dump_tlv8(const uint8_t *data, size_t len) {
    const char *typeNames[] = {
        "Method", "Identifier", "Salt", "PublicKey", "Proof",
        "EncryptedData", "State", "Error", "RetryDelay",
        "Certificate", "Signature", "Permissions", "FragmentData", "FragmentLast"
    };
    size_t i = 0;
    while (i + 2 <= len) {
        uint8_t type = data[i];
        uint8_t tlen = data[i + 1];
        if (i + 2 + tlen > len) break;
        const char *name = (type < 14) ? typeNames[type] : "Unknown";
        printf("    TLV type=%d(%s) len=%d", type, name, tlen);
        if (tlen <= 16) {
            printf(" val=");
            for (int j = 0; j < tlen; j++) printf("%02x", data[i + 2 + j]);
        }
        printf("\n");
        i += 2 + tlen;
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: GET /info
 * ═══════════════════════════════════════════════════════════════ */

static NSData *hex_to_data(const char *hex) {
    size_t len = strlen(hex) / 2;
    NSMutableData *d = [NSMutableData dataWithLength:len];
    uint8_t *bytes = d.mutableBytes;
    for (size_t i = 0; i < len; i++) {
        unsigned int val;
        sscanf(hex + i * 2, "%2x", &val);
        bytes[i] = (uint8_t)val;
    }
    return d;
}

static void handle_info(int sock, const HTTPReq *r) {
    @autoreleasepool {
        printf("[AP] -> GET /info (CSeq=%d, proto=%s)\n", r->cseq, r->protocol);

        bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
        const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

        uint64_t features = g_useHK ? 0x6104040280ULL : 0x2104040280ULL;

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"deviceID"] = @DEVICE_ID;
        info[@"macAddress"] = @DEVICE_ID;
        info[@"features"] = @(features);
        info[@"model"] = @MODEL_NAME;
        info[@"name"] = [NSString stringWithUTF8String:g_instance_name];
        info[@"manufacturer"] = @"iPadPlay";
        info[@"sourceVersion"] = @SOURCE_VERSION;
        info[@"protocolVersion"] = @"1.1";

        /* statusFlags: bit 2 (0x4) = AudioLink (always set in reference).
         * Zero flags may signal "not ready" to iPhone. */
        info[@"statusFlags"] = @(0x4);
        NSString *bluetoothID = [NSString stringWithContentsOfFile:@BT_ID_PATH
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
        bluetoothID = [bluetoothID stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bluetoothID.length == 17) {
            info[@"bluetoothIDs"] = @[bluetoothID];
            printf("[AP] Bluetooth transport identity: %s\n",
                   bluetoothID.UTF8String);
        } else {
            printf("[AP] WARN: Bluetooth transport identity unavailable\n");
        }

        info[@"keepAliveLowPower"] = @YES;
        info[@"keepAliveSendStatsAsBody"] = @YES;
        info[@"pi"] = @HK_PI;
        info[@"pk"] = hex_to_data(HK_PK);

        info[@"firmwareRevision"] = @"1.0.0";
        info[@"hardwareRevision"] = @"1.0";
        info[@"OSInfo"] = @"iPadOS 12.5.8";
        info[@"nightMode"] = @NO;
        info[@"rightHandDrive"] = @(g_right_hand_drive);
        info[@"extendedFeatures"] = @[@"vocoderInfo"];
        /*
         * Apple's receiver advertises this dictionary when buffered main
         * audio is enabled. The dictionary is intentionally empty: the
         * presence of the key is the capability signal. Sender-audio mode
         * omits it so the sender has no buffered media route to this device.
         */
        if (g_receiver_audio)
            info[@"mainBufferedInfo"] = @{};
        printf("[AUDIO] output route: %s\n",
               g_receiver_audio ? "receiver (MainAudio advertised)"
                                : "sender (MainAudio left on the iPhone)");
        /*
         * ElectronicTollCollection is an installed-capability declaration,
         * not a generic inactive vehicle state. Advertising it with
         * active=false produces the grey "ETC" item in CarPlay, so omit the
         * capability entirely on receivers that do not implement it.
         *
         * Publish the legacy 104-point icon for compatibility and the
         * structured, pre-rendered icon form used by Apple's receiver sample.
         * The latter tells CarPlay that the supplied Showcase artwork is
         * already a finished app icon and must not be composited as a raw
         * vehicle glyph.
         */
        NSArray<NSString *> *oemIconPaths = @[
            [[NSBundle mainBundle] pathForResource:@"Icon-OEM-104"
                                            ofType:@"png"] ?: @"",
            @"/Applications/Showcase.app/Icon-OEM-104.png",
            @"/var/jb/Applications/Showcase.app/Icon-OEM-104.png"
        ];
        NSData *oemIcon = nil;
        for (NSString *path in oemIconPaths) {
            if (path.length == 0) continue;
            oemIcon = [NSData dataWithContentsOfFile:path];
            if (oemIcon.length > 0) {
                printf("[AP] OEM vehicle icon: %s (%lu bytes)\n",
                       path.UTF8String, (unsigned long)oemIcon.length);
                break;
            }
        }
        if (oemIcon.length > 0) {
            info[@"oemIcon"] = oemIcon;
            info[@"oemIconLabel"] =
                [NSString stringWithUTF8String:g_instance_name];
            info[@"oemIconVisible"] = @YES;
        } else {
            printf("[AP] WARN: OEM vehicle icon unavailable\n");
        }
        NSArray<NSString *> *oemRenderedIconPaths = @[
            [[NSBundle mainBundle] pathForResource:@"Icon-OEM-120"
                                            ofType:@"png"] ?: @"",
            @"/Applications/Showcase.app/Icon-OEM-120.png",
            @"/var/jb/Applications/Showcase.app/Icon-OEM-120.png"
        ];
        NSData *oemRenderedIcon = nil;
        for (NSString *path in oemRenderedIconPaths) {
            if (path.length == 0) continue;
            oemRenderedIcon = [NSData dataWithContentsOfFile:path];
            if (oemRenderedIcon.length > 0) {
                printf("[AP] OEM pre-rendered icon: %s (%lu bytes)\n",
                       path.UTF8String,
                       (unsigned long)oemRenderedIcon.length);
                break;
            }
        }
        if (oemRenderedIcon.length > 0) {
            info[@"oemIcons"] = @[
                @{
                    @"widthPixels": @(120),
                    @"heightPixels": @(120),
                    @"prerendered": @YES,
                    @"imageData": oemRenderedIcon
                }
            ];
        } else {
            printf("[AP] WARN: OEM pre-rendered icon unavailable\n");
        }
        info[@"limitedUI"] = @NO;

        /*
         * Initial resource ownership must include MainAudio. A clean,
         * first-pair run against Apple's CarPlay Simulator proves the
         * required transition:
         *
         *   MainAudio accessory/permanent accessory
         *       -> controller/permanent accessory -> type 100 SETUP
         *       -> controller/permanent controller -> type 103 SETUP
         *
         * Omitting resource 2 made iOS begin at controller/controller. That
         * skipped both audio setup transitions and left audio on the phone.
         *
         * CarPlay Simulator's Config decoder encodes MainScreen at
         * UserInitiated priority (500), but MainAudio at NiceToHave priority
         * (100). Advertising MainAudio at 500 prevents the sender's ordinary
         * temporary controller/accessory transition that precedes type 100.
         *
         * Sender-audio mode restores the beta 2 advertisement exactly:
         * MainAudio at UserInitiated priority (500) with the legacy format
         * rows below. The sender never issued an audio SETUP for that
         * description, so music, prompts, and calls stayed on the iPhone and
         * its own Bluetooth route.
         */
        info[@"modes"] = @{
            @"resources": @[
                @{  @"resourceID": @(1),       /* MainScreen */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(500), /* UserInitiated */
                    @"takeConstraint": @(100),   /* Anytime */
                    @"borrowConstraint": @(100)
                },
                @{  @"resourceID": @(2),       /* MainAudio */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(g_receiver_audio ? 100 : 500),
                    @"takeConstraint": @(100),
                    @"borrowConstraint": @(100)
                }
            ]
        };

        /* Display capabilities — CarPlay touchscreen */
        NSMutableDictionary *display = [NSMutableDictionary dictionary];
        display[@"uuid"] = @"e0ff8a27-6738-3d56-8a16-cc53ce1299b4";
        display[@"widthPixels"] = @(g_display_width);
        display[@"heightPixels"] = @(g_display_height);
        display[@"widthPhysical"] = @0;
        display[@"heightPhysical"] = @0;
        display[@"maxFPS"] = @(g_display_fps);
        /* Advertise only the implemented capacitive touchscreen. Knob and
         * touchpad bits are behavioral contracts, not cosmetic profile data. */
        display[@"features"] = @(0x08);
        display[@"primaryInputDevice"] = @(1);  /* 1=touchscreen */
        display[@"overscanned"] = @NO;
        info[@"displays"] = @[display];

        /*
         * CarPlaySDK builds different audio tables for wired and wireless
         * sessions. The wireless table uses Opus for interactive audio and
         * AAC-LC for buffered media; compatibility PCM entries belong to the
         * wired builder.
         *
         * Static recovery of Apple's current wireless builder established the
         * row order below. Showcase implements types 100, 101, 102, and 103.
         * Do not advertise the later auxiliary speech streams until their
         * receiver contracts are implemented. Preserve the SDK's insertion
         * order.
         */
        const uint64_t opus16 = 0x10000000ULL;
        const uint64_t opus24 = 0x20000000ULL;
        const uint64_t opus48 = 0x40000000ULL;
        const uint64_t opusAll = opus16 | opus24 | opus48;
        const uint64_t aacLC44 = 0x00400000ULL;
        const uint64_t aacLC48 = 0x00800000ULL;
        if (!g_receiver_audio) {
            /* Beta 2 rows, kept byte-for-byte as the sender-audio contract. */
            info[@"audioFormats"] = @[
                @{
                    @"type": @(100),
                    @"audioInputFormats": @(0x01000000),
                    @"audioOutputFormats": @(0x01000000)
                },
                @{
                    @"type": @(96),
                    @"audioInputFormats": @(0x04000000),
                    @"audioOutputFormats": @(0x04000000)
                }
            ];
            info[@"audioLatencies"] = @[
                @{
                    @"type": @(100), @"audioType": @"default",
                    @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
                }
            ];
        } else {
        info[@"audioFormats"] = @[
            @{
                @"audioType": @"default",
                @"type": @(100),             /* MainAudio */
                @"audioInputFormats": @(opusAll),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"default",
                @"type": @(101),             /* AltAudio */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"media",
                @"type": @(102),             /* MainAudio media */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(aacLC44 | aacLC48)
            },
            @{
                @"audioType": @"media",
                @"type": @(103),             /* MainBufferedAudio */
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(aacLC44 | aacLC48)
            },
            @{
                @"audioType": @"alert",
                @"type": @(100),
                @"audioInputFormats": @(0),
                @"audioOutputFormats": @(opus48)
            },
            @{
                @"audioType": @"telephony",
                @"type": @(100),
                @"audioInputFormats": @(opusAll),
                @"audioOutputFormats": @(opusAll)
            },
            @{
                @"audioType": @"speechRecognition",
                @"type": @(100),
                @"audioInputFormats": @(opus24),
                @"audioOutputFormats": @(opus24)
            }
        ];

        info[@"audioLatencies"] = @[
            @{
                @"type": @(100), @"audioType": @"default",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"telephony",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"speechRecognition",
                @"inputLatencyMicros": @0, @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"alert",
                @"outputLatencyMicros": @0
            },
            @{
                @"type": @(100), @"audioType": @"media",
                @"outputLatencyMicros": @0
            },
            @{
                @"type": @(101), @"audioType": @"default",
                @"outputLatencyMicros": @0
            }
        ];
        }

        info[@"initialVolume"] = @(-20.0);

        /* HID devices — Apple's single-touch-with-cancel format, used by the
         * CarPlay Simulator when "High Fidelty" and cancel support are enabled.
         * Report = 5 bytes: [touch|cancel<<1][xLo][xHi][yLo][yHi].
         * Coordinates use the negotiated display dimensions. */
        {
            const uint8_t hidDesc[] = {
                0x05, 0x0D,        /* Usage Page (Digitizer) */
                0x09, 0x04,        /* Usage (Touch Screen) */
                0xA1, 0x01,        /* Collection (Application) */
                0x09, 0x22,        /*   Usage (Finger) */
                0xA1, 0x02,        /*   Collection (Logical) */
                0x15, 0x00,        /*     Logical Minimum (0) */
                0x25, 0x01,        /*     Logical Maximum (1) */
                0x09, 0x33,        /*     Usage (Touch) */
                0x09, 0x34,        /*     Usage (Untouch/Cancel) */
                0x75, 0x01,        /*     Report Size (1) */
                0x95, 0x02,        /*     Report Count (2) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x95, 0x06,        /*     Report Count (6) */
                0x81, 0x01,        /*     Input (Constant) */
                0x05, 0x01,        /*     Usage Page (Generic Desktop) */
                0x26, (uint8_t)g_display_width,
                      (uint8_t)(g_display_width >> 8),
                                      /*     Logical Maximum (display width) */
                0x09, 0x30,        /*     Usage (X) */
                0x75, 0x10,        /*     Report Size (16) */
                0x95, 0x01,        /*     Report Count (1) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x26, (uint8_t)g_display_height,
                      (uint8_t)(g_display_height >> 8),
                                      /*     Logical Maximum (display height) */
                0x09, 0x31,        /*     Usage (Y) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0xC0,              /*   End Collection */
                0xC0               /* End Collection */
            };
            NSData *descData = [NSData dataWithBytes:hidDesc length:sizeof(hidDesc)];

            NSDictionary *hidDev = @{
                @"name": @"Touch Screen",
                @"uuid": @"1",
                @"displayUUID": @"e0ff8a27-6738-3d56-8a16-cc53ce1299b4",
                @"hidVendorID": @(0),
                @"hidProductID": @(0),
                @"hidCountryCode": @(0),
                @"hidDescriptor": descData
            };
            info[@"hidDevices"] = @[hidDev];
        }

        NSError *err = nil;
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:info
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&err];
        if (!plist) {
            printf("[AP] /info plist error: %s\n",
                   err.localizedDescription.UTF8String);
            send_response(sock, proto, 500, "Internal Server Error",
                         NULL, NULL, 0, r->cseq);
            return;
        }

        /* Dump full /info plist for debugging */
        printf("[AP] <- /info response: %zu bytes binary plist\n",
               (size_t)plist.length);
        printf("[AP] /info dict: %s\n", [[info description] UTF8String]);
        send_response(sock, proto, 200, "OK",
                     "application/x-apple-binary-plist",
                     plist.bytes, plist.length, r->cseq);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /pair-setup
 * ═══════════════════════════════════════════════════════════════ */

static void handle_pair_setup(int sock, const HTTPReq *r) {
    printf("[AP] -> POST /pair-setup (HKP=%s, bodyLen=%zu)\n",
           r->xAppleHKP[0] ? r->xAppleHKP : "none", r->bodyLen);

    if (r->body && r->bodyLen > 0) {
        printf("[AP] pair-setup TLV8 payload:\n");
        dump_tlv8(r->body, r->bodyLen);
    }

    /* Determine protocol (RTSP or HTTP) */
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    if (!r->body || r->bodyLen == 0) {
        printf("[AP] pair-setup: no body, sending empty 200\n");
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
        return;
    }

    /* The SRP state machine resets internally on each M1. */
    if (!ensure_pair_context()) {
        printf("[AP] ERROR: Failed to create pair context\n");
        send_response(sock, proto, 500, "Internal Error",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    app_send_status(STATUS_PAIR_SETUP_STARTED);

    /* Handle the pair-setup request through our SRP state machine */
    size_t resp_len = 0;
    uint8_t *resp_data = pair_setup_handle(g_pair, r->body, r->bodyLen, &resp_len);

    if (resp_data && resp_len > 0) {
        printf("[AP] pair-setup response: %zu bytes TLV8\n", resp_len);
        printf("[AP] pair-setup response hex:");
        size_t dumpLen = resp_len > 128 ? 128 : resp_len;
        for (size_t i = 0; i < dumpLen; i++) printf(" %02X", resp_data[i]);
        if (resp_len > 128) printf(" ...");
        printf("\n");

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream",
                     resp_data, resp_len, r->cseq);
        free(resp_data);
    } else {
        printf("[AP] pair-setup: handler returned no data, sending empty 200\n");
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
    }

    if (pair_setup_is_complete(g_pair)) {
        save_pairing_registry();
        printf("\n[AP] ╔══════════════════════════════════════╗\n");
        printf("[AP] ║  PAIR-SETUP COMPLETE — SUCCESS!      ║\n");
        printf("[AP] ║  Waiting for pair-verify...           ║\n");
        printf("[AP] ╚══════════════════════════════════════╝\n\n");
        app_send_status(STATUS_PAIR_SETUP_COMPLETE);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /pair-verify
 * ═══════════════════════════════════════════════════════════════ */

static void handle_pair_verify(int sock, const HTTPReq *r) {
    printf("[AP] -> POST /pair-verify (HKP=%s, PD=%s, bodyLen=%zu)\n",
           r->xAppleHKP[0] ? r->xAppleHKP : "none",
           r->xApplePD[0] ? r->xApplePD : "none",
           r->bodyLen);

    if (r->body && r->bodyLen > 0) {
        printf("[AP] pair-verify TLV8 payload:\n");
        dump_tlv8(r->body, r->bodyLen);
    }

    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    if (!r->body || r->bodyLen == 0) {
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
        return;
    }

    if (!ensure_pair_context()) {
        send_response(sock, proto, 500, "Internal Error",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    size_t resp_len = 0;
    uint8_t *resp_data = pair_verify_handle(g_pair, r->body, r->bodyLen, &resp_len);

    if (resp_data && resp_len > 0) {
        printf("[AP] pair-verify response: %zu bytes TLV8\n", resp_len);
        printf("[AP] pair-verify response hex:");
        size_t dumpLen = resp_len > 128 ? 128 : resp_len;
        for (size_t i = 0; i < dumpLen; i++) printf(" %02X", resp_data[i]);
        if (resp_len > 128) printf(" ...");
        printf("\n");

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream",
                     resp_data, resp_len, r->cseq);
        free(resp_data);
    } else {
        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", NULL, 0, r->cseq);
    }

    if (pair_verify_is_complete(g_pair)) {
        /* Derive control channel encryption keys */
        if (pair_derive_control_keys(g_pair, g_enc.readKey, g_enc.writeKey) == 0) {
            g_enc.readNonce = 0;
            g_enc.writeNonce = 0;
            g_enc.active = true;
            printf("[AP] *** Encrypted transport layer ACTIVE ***\n");
        }

        /* Pre-derive event channel encryption keys so they're ready
         * when iPhone connects to event port (before RECORD).
         * Reference derives these in _ControlStart during RECORD,
         * but our event thread accepts connections earlier. */
        if (pair_derive_event_keys(g_pair, g_event_enc.readKey, g_event_enc.writeKey) == 0) {
            g_event_enc.readNonce = 0;
            g_event_enc.writeNonce = 0;
            g_event_enc.active = true;
            printf("[AP] *** Event channel encryption keys PRE-DERIVED ***\n");
        }

        printf("\n[AP] ╔══════════════════════════════════════╗\n");
        printf("[AP] ║  PAIR-VERIFY COMPLETE — SUCCESS!     ║\n");
        printf("[AP] ║  Connection is now authenticated.     ║\n");
        printf("[AP] ╚══════════════════════════════════════╝\n\n");
        app_send_status(STATUS_PAIR_VERIFY_COMPLETE);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /fp-setup (FairPlay)
 * ═══════════════════════════════════════════════════════════════ */

static void handle_fp_setup(int sock, const HTTPReq *r) {
    printf("[AP] -> POST /fp-setup (bodyLen=%zu)\n", r->bodyLen);

    if (r->body && r->bodyLen > 0) {
        printf("[AP] fp-setup hex dump (%zu):", r->bodyLen);
        size_t dumpLen = r->bodyLen > 256 ? 256 : r->bodyLen;
        for (size_t i = 0; i < dumpLen; i++) printf(" %02X", r->body[i]);
        if (r->bodyLen > 256) printf(" ...");
        printf("\n");
    }

    send_response(sock, "HTTP/1.1", 200, "OK",
                 "application/octet-stream", NULL, 0, 0);
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /auth-setup
 * ═══════════════════════════════════════════════════════════════ */

static void handle_auth_setup(int sock, const HTTPReq *r) {
    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

    printf("[AP] -> POST /auth-setup (bodyLen=%zu, CSeq=%d, AT=%s)\n",
           r->bodyLen, r->cseq, r->xAppleAT[0] ? r->xAppleAT : "none");

    if (!r->body || r->bodyLen == 0) {
        printf("[AP] auth-setup: empty body\n");
        send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
        return;
    }

    /* Two formats:
     * 1) Raw MFi-SAP v1: 33 bytes = <1:version> <32:Curve25519 pk>
     * 2) Binary plist (iOS 18+): contains key data in plist wrapper */
    uint8_t version = 0;
    const uint8_t *peerPK = NULL;
    uint8_t peerPKBuf[32];
    bool isPlist = false;

    if (r->bodyLen == 33 && r->body[0] <= 2) {
        /* Raw MFi-SAP format */
        version = r->body[0];
        peerPK = r->body + 1;
    } else {
        /* Try binary plist */
        @autoreleasepool {
            NSData *d = [NSData dataWithBytesNoCopy:(void *)r->body
                                             length:r->bodyLen
                                       freeWhenDone:NO];
            id obj = [NSPropertyListSerialization
                propertyListWithData:d options:0 format:NULL error:NULL];
            if (obj) {
                printf("[AP] auth-setup plist: %s\n", [[obj description] UTF8String]);
                isPlist = true;

                /* Extract public key — try known keys */
                NSData *pkData = nil;
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dict = (NSDictionary *)obj;
                    pkData = dict[@"pk"] ?: dict[@"publicKey"] ?: dict[@"epk"];
                    if (!pkData) {
                        /* Dump all keys for analysis */
                        for (NSString *key in dict) {
                            id val = dict[key];
                            if ([val isKindOfClass:[NSData class]]) {
                                NSData *dv = (NSData *)val;
                                printf("[AP] auth-setup key '%s': %zu bytes:", [key UTF8String], dv.length);
                                const uint8_t *b = (const uint8_t *)dv.bytes;
                                for (size_t i = 0; i < dv.length && i < 64; i++) printf(" %02x", b[i]);
                                if (dv.length > 64) printf(" ...");
                                printf("\n");
                                if (dv.length == 32 && !pkData) pkData = dv;
                            } else if ([val isKindOfClass:[NSNumber class]]) {
                                printf("[AP] auth-setup key '%s': %s\n",
                                       [key UTF8String], [[val description] UTF8String]);
                            } else if ([val isKindOfClass:[NSString class]]) {
                                printf("[AP] auth-setup key '%s': %s\n",
                                       [key UTF8String], [val UTF8String]);
                            }
                        }
                    }
                    if (pkData && pkData.length == 32) {
                        memcpy(peerPKBuf, pkData.bytes, 32);
                        peerPK = peerPKBuf;
                        version = 1;
                    }
                }
            } else {
                printf("[AP] auth-setup: not a plist, hex (%zu):", r->bodyLen);
                for (size_t i = 0; i < r->bodyLen && i < 128; i++) printf(" %02x", r->body[i]);
                printf("\n");
            }
        }
    }

    if (!peerPK) {
        printf("[AP] auth-setup: could not extract peer public key (bodyLen=%zu)\n", r->bodyLen);
        /* Return 200 OK with empty plist to not kill the connection */
        @autoreleasepool {
            NSDictionary *resp = @{};
            NSData *plistData = [NSPropertyListSerialization
                dataWithPropertyList:resp format:NSPropertyListBinaryFormat_v1_0
                options:0 error:NULL];
            send_response(sock, proto, 200, "OK",
                         "application/x-apple-binary-plist",
                         (const uint8_t *)plistData.bytes, plistData.length, r->cseq);
        }
        return;
    }

    printf("[AP] auth-setup: version=%d, %s, client ECDH pk:", version, isPlist ? "plist" : "raw");
    for (int i = 0; i < 32; i++) printf(" %02x", peerPK[i]);
    printf("\n");

    if (!g_baa_ready) {
        printf("[AP] auth-setup: BAA not ready, attempting issuance...\n");
        load_baa_from_broker();
    }
    if (!g_baa_ready) {
        printf("[AP] auth-setup: BAA certificate unavailable\n");
        send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
        return;
    }

    /* Generate our Curve25519 keypair with the system CSPRNG and embedded
     * Monocypher. */
    uint8_t ourSK[32];
    uint8_t ourPK[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(ourSK), ourSK) !=
        errSecSuccess) {
        printf("[AP] auth-setup: secure random generation failed\n");
        send_response(sock, proto, 500, "Internal Server Error",
                      NULL, NULL, 0, r->cseq);
        return;
    }
    crypto_x25519_public_key(ourPK, ourSK);

    printf("[AP] auth-setup: our ECDH pk:");
    for (int i = 0; i < 32; i++) printf(" %02x", ourPK[i]);
    printf("\n");

    /* Compute ECDH shared secret */
    uint8_t sharedSecret[32];
    crypto_x25519(sharedSecret, ourSK, peerPK);
    crypto_wipe(ourSK, sizeof(ourSK));

    printf("[AP] auth-setup: shared secret established\n");

    /* Derive AES key and IV: SHA1("AES-KEY" + shared) and SHA1("AES-IV" + shared) */
    uint8_t aesKey[20], aesIV[20];
    CC_SHA1_CTX sha;
    CC_SHA1_Init(&sha);
    CC_SHA1_Update(&sha, "AES-KEY", 7);
    CC_SHA1_Update(&sha, sharedSecret, 32);
    CC_SHA1_Final(aesKey, &sha);

    CC_SHA1_Init(&sha);
    CC_SHA1_Update(&sha, "AES-IV", 6);
    CC_SHA1_Update(&sha, sharedSecret, 32);
    CC_SHA1_Final(aesIV, &sha);

    /* Sign SHA1(ourPK || peerPK) with BAA private key (ECDSA-SHA256) */
    @autoreleasepool {
        /* Build the data to sign: SHA1(ourPK || peerPK) = 20 bytes
         * But we'll sign the raw concatenation with ECDSA-SHA256 instead of
         * doing SHA1-then-RSA like MFi does. The iPhone needs to accept this. */
        uint8_t digestData[64];  /* ourPK || peerPK */
        memcpy(digestData, ourPK, 32);
        memcpy(digestData + 32, peerPK, 32);

        /* Sign with ECDSA-SHA256 (BAA key's native algorithm) */
        uint8_t *sigBytesOwned = NULL;
        int sigLength = 0;
        int signRC = baa_broker_sign(digestData, sizeof(digestData),
                                     &sigBytesOwned, &sigLength);
        if (signRC != 0) {
            printf("[AP] auth-setup: BAA broker sign FAILED: %d\n", signRC);
            send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
            return;
        }

        const uint8_t *sigBytes = sigBytesOwned;
        size_t sigLen = (size_t)sigLength;
        printf("[AP] auth-setup: ECDSA signature: %zu bytes\n", sigLen);

        /* Encrypt signature with AES-128-CTR */
        uint8_t *encSig = malloc(sigLen);
        size_t encLen = 0;
        CCCryptorRef cryptor;
        CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES128,
                                ccNoPadding, aesIV, aesKey, 16,
                                NULL, 0, 0, kCCModeOptionCTR_BE, &cryptor);
        CCCryptorUpdate(cryptor, sigBytes, sigLen, encSig, sigLen, &encLen);
        CCCryptorRelease(cryptor);
        free(sigBytesOwned);

        printf("[AP] auth-setup: encrypted sig: %zu bytes\n", encLen);

        /* ── Build OPACK blob for intermediate cert: {"baIC": inter_der} ──
         *
         * OPACK encoding (from pyatv/Apple CoreUtils):
         *   0xE1             = dict with 1 entry
         *   0x44             = string of length 4 (0x40 + 4)
         *   "baIC"           = 62 61 49 43
         *   0x92 LL LL       = bytes with 2-byte LE length (for 256-65535)
         *   [data...]        = intermediate cert DER
         *
         * For certs <= 255 bytes, use 0x91 + 1-byte LE length instead.
         * For certs <= 32 bytes, use 0x70+len inline (unlikely for certs).
         */
        size_t opackHdrLen;
        uint8_t opackHdr[16];
        opackHdr[0] = 0xE1;             /* dict, 1 entry */
        opackHdr[1] = 0x44;             /* string len=4 */
        opackHdr[2] = 'b'; opackHdr[3] = 'a'; opackHdr[4] = 'I'; opackHdr[5] = 'C';
        if (g_baa_inter_len <= 0x20) {
            opackHdr[6] = 0x70 + (uint8_t)g_baa_inter_len;
            opackHdrLen = 7;
        } else if (g_baa_inter_len <= 0xFF) {
            opackHdr[6] = 0x91;
            opackHdr[7] = (uint8_t)(g_baa_inter_len & 0xFF);
            opackHdrLen = 8;
        } else if (g_baa_inter_len <= 0xFFFF) {
            opackHdr[6] = 0x92;
            opackHdr[7] = (uint8_t)(g_baa_inter_len & 0xFF);        /* LE low */
            opackHdr[8] = (uint8_t)((g_baa_inter_len >> 8) & 0xFF); /* LE high */
            opackHdrLen = 9;
        } else {
            opackHdr[6] = 0x93;
            opackHdr[7] = (uint8_t)(g_baa_inter_len & 0xFF);
            opackHdr[8] = (uint8_t)((g_baa_inter_len >> 8) & 0xFF);
            opackHdr[9] = (uint8_t)((g_baa_inter_len >> 16) & 0xFF);
            opackHdr[10] = (uint8_t)((g_baa_inter_len >> 24) & 0xFF);
            opackHdrLen = 11;
        }
        size_t opackBlobLen = opackHdrLen + g_baa_inter_len;
        uint8_t *opackBlob = malloc(opackBlobLen);
        memcpy(opackBlob, opackHdr, opackHdrLen);
        memcpy(opackBlob + opackHdrLen, g_baa_inter_der, g_baa_inter_len);

        printf("[AP] auth-setup: OPACK baIC blob: %zu bytes (hdr=%zu + inter=%d)\n",
               opackBlobLen, opackHdrLen, g_baa_inter_len);

        /* ── Build BAA MFi-SAP M2 response ──
         *
         * New layout (from CarPlay Simulator disassembly):
         *   server_curve25519_pub[32]
         *   leaf_len_be[4]
         *   leaf_der[leaf_len]         ← ONLY leaf, not leaf+intermediate
         *   enc_sig_len_be[4]
         *   enc_sig[enc_sig_len]
         *   baIC_len_be[4]             ← OPACK blob length
         *   OPACK({"baIC": inter})[baIC_len]
         */
        size_t respLen = 32 + 4 + g_baa_leaf_len + 4 + encLen + 4 + opackBlobLen;
        uint8_t *resp = malloc(respLen);
        uint8_t *p = resp;

        /* 1) Server Curve25519 public key */
        memcpy(p, ourPK, 32); p += 32;

        /* 2) Leaf cert only */
        p[0] = (g_baa_leaf_len >> 24) & 0xFF;
        p[1] = (g_baa_leaf_len >> 16) & 0xFF;
        p[2] = (g_baa_leaf_len >> 8)  & 0xFF;
        p[3] =  g_baa_leaf_len        & 0xFF;
        p += 4;
        memcpy(p, g_baa_leaf_der, g_baa_leaf_len); p += g_baa_leaf_len;

        /* 3) Encrypted ECDSA signature */
        p[0] = (encLen >> 24) & 0xFF;
        p[1] = (encLen >> 16) & 0xFF;
        p[2] = (encLen >> 8)  & 0xFF;
        p[3] =  encLen        & 0xFF;
        p += 4;
        memcpy(p, encSig, encLen); p += encLen;

        /* 4) OPACK {"baIC": intermediate_der} */
        uint32_t opackBlobLen32 = (uint32_t)opackBlobLen;
        p[0] = (opackBlobLen32 >> 24) & 0xFF;
        p[1] = (opackBlobLen32 >> 16) & 0xFF;
        p[2] = (opackBlobLen32 >> 8)  & 0xFF;
        p[3] =  opackBlobLen32        & 0xFF;
        p += 4;
        memcpy(p, opackBlob, opackBlobLen); p += opackBlobLen;

        printf("[AP] auth-setup M2 response: %zu bytes "
               "(pk=32 + leaf=%d + sig=%zu + opack=%zu)\n",
               respLen, g_baa_leaf_len, encLen, opackBlobLen);

        send_response(sock, proto, 200, "OK",
                     "application/octet-stream", resp, respLen, r->cseq);
        app_send_status(STATUS_AUTH_COMPLETE);

        free(resp);
        free(opackBlob);
        free(encSig);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: OPTIONS
 * ═══════════════════════════════════════════════════════════════ */

static void handle_options(int sock, const HTTPReq *r) {
    printf("[AP] -> OPTIONS\n");
    const char *proto = strncmp(r->protocol, "RTSP", 4) == 0 ?
                        "RTSP/1.0" : "HTTP/1.1";

    @autoreleasepool {
        NSMutableString *hdr = [NSMutableString string];
        [hdr appendFormat:@"%s 200 OK\r\n", proto];
        [hdr appendFormat:@"Server: AirTunes/%s\r\n", SOURCE_VERSION];
        if (r->cseq > 0)
            [hdr appendFormat:@"CSeq: %d\r\n", r->cseq];
        [hdr appendString:@"Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, "
                          @"TEARDOWN, OPTIONS, POST, GET, PUT\r\n"];
        [hdr appendString:@"Content-Length: 0\r\n"];
        [hdr appendString:@"\r\n"];
        const char *h = hdr.UTF8String;
        send(sock, h, strlen(h), 0);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: RTSP SETUP
 *
 * Two phases:
 *  1) Initial session setup (no "streams" key): return control ports
 *  2) Stream setup (has "streams" array): allocate data/control ports
 * ═══════════════════════════════════════════════════════════════ */

static const char *addr_family_name(int family) {
    switch (family) {
        case AF_INET: return "IPv4";
        case AF_INET6: return "IPv6";
        default: return "unknown";
    }
}

static bool sockaddr_to_numeric(const struct sockaddr *sa, socklen_t slen,
                                char *host, size_t hostLen,
                                char *serv, size_t servLen) {
    int rc = getnameinfo(sa, slen, host, (socklen_t)hostLen,
                         serv, (socklen_t)servLen,
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc == 0) return true;
    snprintf(host, hostLen, "(getnameinfo:%d)", rc);
    if (serv && servLen) snprintf(serv, servLen, "0");
    return false;
}

/*
 * Apple's receiver marks the screen TCP socket as interactive video before
 * accepting the sender. This is not cosmetic DSCP tagging: Darwin's network
 * service type also selects the Wi-Fi WMM access category for locally emitted
 * packets, including TCP ACKs. Captures from CarPlay Simulator show 0x80 in
 * both directions, while Showcase previously returned every screen ACK as
 * best-effort 0x00 even though the iPhone's video packets were 0x80/0x82.
 *
 * Apply the public network-service API plus both layers used by
 * AccessorySDK's SocketSetQoS(kSocketQoS_AirPlayScreenVideo): the IP header
 * class and Darwin's private socket traffic class. The latter is what the
 * Apple implementation says the driver uses for mbuf prioritization.
 *
 * A Personal Hotspot peer can also arrive as an IPv4-mapped address on our
 * dual-stack IPv6 listener. In that case set IP_TOS as well as IPV6_TCLASS;
 * choosing solely from getsockname() would otherwise miss the on-wire IPv4
 * path used by older receivers. Reapply everything to the accepted socket
 * because not every Darwin release inherits every listener option.
 */
#ifndef SO_NET_SERVICE_TYPE
#define SO_NET_SERVICE_TYPE 0x1116
#endif
#ifndef NET_SERVICE_TYPE_VI
#define NET_SERVICE_TYPE_VI 3
#endif
#ifndef SO_TRAFFIC_CLASS
#define SO_TRAFFIC_CLASS 0x1086
#endif
#ifndef SO_TC_VI
#define SO_TC_VI 700
#endif

static void set_screen_socket_qos(int fd, const char *stage) {
    if (fd < 0) return;

    int serviceType = NET_SERVICE_TYPE_VI;
    int serviceResult = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                                   &serviceType, sizeof(serviceType));
    int serviceError = serviceResult == 0 ? 0 : errno;

    struct sockaddr_storage localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    socklen_t localLength = sizeof(localAddress);
    int family = AF_UNSPEC;
    if (getsockname(fd, (struct sockaddr *)&localAddress, &localLength) == 0)
        family = localAddress.ss_family;

    struct sockaddr_storage peerAddress;
    memset(&peerAddress, 0, sizeof(peerAddress));
    socklen_t peerLength = sizeof(peerAddress);
    int peerFamily = AF_UNSPEC;
    bool peerIsIPv4Mapped = false;
    if (getpeername(fd, (struct sockaddr *)&peerAddress, &peerLength) == 0) {
        peerFamily = peerAddress.ss_family;
        if (peerFamily == AF_INET6) {
            const struct sockaddr_in6 *peer6 =
                (const struct sockaddr_in6 *)&peerAddress;
            peerIsIPv4Mapped = IN6_IS_ADDR_V4MAPPED(&peer6->sin6_addr);
        }
    }

    int diffServ = 0x80; /* CS4 / WMM interactive video. */
    int ipResult = -1;
    int ipError = 0;
    int ipv6Result = -1;
    int ipv6Error = 0;
    if (family == AF_INET) {
#ifdef IP_TOS
        ipResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                              &diffServ, sizeof(diffServ));
        if (ipResult != 0) ipError = errno;
#endif
    } else if (family == AF_INET6) {
#ifdef IPV6_TCLASS
        ipv6Result = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS,
                                &diffServ, sizeof(diffServ));
        if (ipv6Result != 0) ipv6Error = errno;
#endif
#ifdef IP_TOS
        if (peerIsIPv4Mapped) {
            ipResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                                  &diffServ, sizeof(diffServ));
            if (ipResult != 0) ipError = errno;
        }
#endif
    }

    int trafficClass = SO_TC_VI;
    int trafficResult = setsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                   &trafficClass, sizeof(trafficClass));
    int trafficError = trafficResult == 0 ? 0 : errno;

    int appliedServiceType = -1;
    socklen_t appliedLength = sizeof(appliedServiceType);
    int getResult = getsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                               &appliedServiceType, &appliedLength);

    int appliedTrafficClass = -1;
    appliedLength = sizeof(appliedTrafficClass);
    int trafficGetResult = getsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                      &appliedTrafficClass, &appliedLength);

    printf("[SCREEN] QoS %s fd=%d family=%s peer=%s%s "
           "service=VI(%d) set=%s get=%s(%d) "
           "traffic=VI(%d) set=%s get=%s(%d) "
           "ipv6TClass=%s%s ipTOS=%s%s\n",
           stage ? stage : "socket", fd, addr_family_name(family),
           addr_family_name(peerFamily), peerIsIPv4Mapped ? "(v4-mapped)" : "",
           NET_SERVICE_TYPE_VI,
           serviceResult == 0 ? "OK" : "FAIL",
           getResult == 0 ? "OK" : "FAIL",
           getResult == 0 ? appliedServiceType : -1,
           SO_TC_VI,
           trafficResult == 0 ? "OK" : "FAIL",
           trafficGetResult == 0 ? "OK" : "FAIL",
           trafficGetResult == 0 ? appliedTrafficClass : -1,
           ipv6Result == 0 ? "OK" :
               (ipv6Result < 0 && !ipv6Error ? "N/A" : "FAIL"),
           ipv6Error ? strerror(ipv6Error) : "",
           ipResult == 0 ? "OK" :
               (ipResult < 0 && !ipError ? "N/A" : "FAIL"),
           ipError ? strerror(ipError) : "");
    if (serviceError || trafficError) {
        printf("[SCREEN] QoS %s errors service=%s traffic=%s\n",
               stage ? stage : "socket",
               serviceError ? strerror(serviceError) : "none",
               trafficError ? strerror(trafficError) : "none");
    }
}

/*
 * The event channel carries HID touch reports from this receiver to the
 * sender. On the hotspot link they share the receiver's transmit queue with
 * the screen stream's acknowledgements. Voice class lets a few dozen bytes of
 * touch data bypass that queue; its WMM access category is not aggregated, so
 * a report is not held while the radio builds a larger frame.
 */
#ifndef NET_SERVICE_TYPE_VO
#define NET_SERVICE_TYPE_VO 4
#endif
#ifndef SO_TC_VO
#define SO_TC_VO 800
#endif

static void set_event_socket_qos(int fd) {
    if (fd < 0) return;
    int serviceType = NET_SERVICE_TYPE_VO;
    int serviceResult = setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                                   &serviceType, sizeof(serviceType));
    int trafficClass = SO_TC_VO;
    int trafficResult = setsockopt(fd, SOL_SOCKET, SO_TRAFFIC_CLASS,
                                   &trafficClass, sizeof(trafficClass));
    int diffServ = 0xC0; /* CS6 / WMM voice. */
    int tosResult = -1;
    struct sockaddr_storage local;
    socklen_t localLength = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) == 0) {
        if (local.ss_family == AF_INET) {
            tosResult = setsockopt(fd, IPPROTO_IP, IP_TOS,
                                   &diffServ, sizeof(diffServ));
        } else if (local.ss_family == AF_INET6) {
            tosResult = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS,
                                   &diffServ, sizeof(diffServ));
            const struct sockaddr_in6 *local6 =
                (const struct sockaddr_in6 *)&local;
            if (IN6_IS_ADDR_V4MAPPED(&local6->sin6_addr))
                setsockopt(fd, IPPROTO_IP, IP_TOS, &diffServ, sizeof(diffServ));
        }
    }
    printf("[EVENT] QoS voice: service=%s traffic=%s tos=%s\n",
           serviceResult == 0 ? "OK" : "FAIL",
           trafficResult == 0 ? "OK" : "FAIL",
           tosResult == 0 ? "OK" : "FAIL");
}

static int bind_udp_port_ipv4(uint16_t *outPort) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    *outPort = ntohs(sa.sin_port);
    printf("[NET] bound UDP IPv4 fallback port %u fd=%d\n", *outPort, fd);
    return fd;
}

/* Helper: bind a UDP socket to any port and return (fd, port). */
static int bind_udp_port(uint16_t *outPort) {
    int savedErrno = 0;
    int fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd >= 0) {
        int no = 0;
        int yes = 1;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)) != 0) {
            savedErrno = errno;
            printf("[NET] WARN: UDP IPV6_V6ONLY=0 failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
            close(fd);
            goto udp_fallback;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        sa6.sin6_addr = in6addr_any;
        sa6.sin6_port = 0;
        if (bind(fd, (struct sockaddr *)&sa6, sizeof(sa6)) == 0) {
            socklen_t sl = sizeof(sa6);
            if (getsockname(fd, (struct sockaddr *)&sa6, &sl) == 0) {
                *outPort = ntohs(sa6.sin6_port);
                printf("[NET] bound UDP dual-stack port %u fd=%d\n", *outPort, fd);
                return fd;
            }
            savedErrno = errno;
            printf("[NET] WARN: dual-stack UDP getsockname failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        } else {
            savedErrno = errno;
            printf("[NET] WARN: dual-stack UDP bind failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        }
        close(fd);
    } else {
        savedErrno = errno;
        printf("[NET] WARN: dual-stack UDP socket failed errno=%d (%s)\n",
               savedErrno, strerror(savedErrno));
    }

udp_fallback:
    printf("[NET] WARN: dual-stack UDP bind failed errno=%d (%s), falling back to IPv4\n",
           savedErrno, strerror(savedErrno));
    return bind_udp_port_ipv4(outPort);
}

static int bind_tcp_port_ipv4(uint16_t *outPort) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    listen(fd, 1);
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    *outPort = ntohs(sa.sin_port);
    printf("[NET] bound TCP IPv4 fallback port %u fd=%d\n", *outPort, fd);
    return fd;
}

/* Helper: bind a TCP listen socket to any port and return (fd, port) */
static int bind_tcp_port(uint16_t *outPort) {
    int savedErrno = 0;
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd >= 0) {
        int no = 0;
        int yes = 1;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)) != 0) {
            savedErrno = errno;
            printf("[NET] WARN: TCP IPV6_V6ONLY=0 failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
            close(fd);
            goto tcp_fallback;
        }
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        sa6.sin6_addr = in6addr_any;
        sa6.sin6_port = 0;
        if (bind(fd, (struct sockaddr *)&sa6, sizeof(sa6)) == 0) {
            if (listen(fd, 1) == 0) {
                socklen_t sl = sizeof(sa6);
                if (getsockname(fd, (struct sockaddr *)&sa6, &sl) == 0) {
                    *outPort = ntohs(sa6.sin6_port);
                    printf("[NET] bound TCP dual-stack port %u fd=%d\n", *outPort, fd);
                    return fd;
                }
                savedErrno = errno;
                printf("[NET] WARN: dual-stack TCP getsockname failed errno=%d (%s)\n",
                       savedErrno, strerror(savedErrno));
            } else {
                savedErrno = errno;
                printf("[NET] WARN: dual-stack TCP listen failed errno=%d (%s)\n",
                       savedErrno, strerror(savedErrno));
            }
        } else {
            savedErrno = errno;
            printf("[NET] WARN: dual-stack TCP bind failed errno=%d (%s)\n",
                   savedErrno, strerror(savedErrno));
        }
        close(fd);
    } else {
        savedErrno = errno;
        printf("[NET] WARN: dual-stack TCP socket failed errno=%d (%s)\n",
               savedErrno, strerror(savedErrno));
    }

tcp_fallback:
    printf("[NET] WARN: dual-stack TCP bind failed errno=%d (%s), falling back to IPv4\n",
           savedErrno, strerror(savedErrno));
    return bind_tcp_port_ipv4(outPort);
}

/*
 * AirPlayReceiverSession opens its screen socket in the authenticated RTSP
 * peer's address family. That distinction matters on Darwin: accepting an
 * IPv4 sender through an IPv6 dual-stack socket produces an IPv4-mapped
 * socket on which IP_TOS cannot be applied. It also sets SO_RCVBUF before
 * listen(), so the accepted connection inherits the intended window scale.
 */
static int bind_screen_tcp_port(uint16_t *outPort, int peerFamily) {
    int family = peerFamily == AF_INET6 ? AF_INET6 : AF_INET;
    int fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        printf("[NET] ERROR: screen %s socket failed: %s\n",
               addr_family_name(family), strerror(errno));
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    if (family == AF_INET6) {
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
                       &yes, sizeof(yes)) != 0) {
            printf("[NET] ERROR: screen IPV6_V6ONLY=1 failed: %s\n",
                   strerror(errno));
            close(fd);
            return -1;
        }
    }

    int requestedRcvBuf = g_screen_receive_buffer;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF,
                   &requestedRcvBuf, sizeof(requestedRcvBuf)) != 0) {
        printf("[SCREEN] WARN: listener SO_RCVBUF request %d failed: %s\n",
               requestedRcvBuf, strerror(errno));
    }
    int listenerRcvBuf = 0;
    socklen_t listenerRcvBufLength = sizeof(listenerRcvBuf);
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &listenerRcvBuf,
                   &listenerRcvBufLength) == 0) {
        printf("[SCREEN] Listener TCP receive buffer: requested=%d actual=%d\n",
               requestedRcvBuf, listenerRcvBuf);
    }

    set_screen_socket_qos(fd, "listener");

    int bindResult = -1;
    if (family == AF_INET) {
        struct sockaddr_in address4;
        memset(&address4, 0, sizeof(address4));
        address4.sin_family = AF_INET;
        address4.sin_addr.s_addr = htonl(INADDR_ANY);
        address4.sin_port = 0;
        bindResult = bind(fd, (struct sockaddr *)&address4, sizeof(address4));
    } else {
        struct sockaddr_in6 address6;
        memset(&address6, 0, sizeof(address6));
        address6.sin6_family = AF_INET6;
        address6.sin6_addr = in6addr_any;
        address6.sin6_port = 0;
        bindResult = bind(fd, (struct sockaddr *)&address6, sizeof(address6));
    }
    if (bindResult != 0 || listen(fd, 1) != 0) {
        printf("[NET] ERROR: screen %s bind/listen failed: %s\n",
               addr_family_name(family), strerror(errno));
        close(fd);
        return -1;
    }

    struct sockaddr_storage local;
    memset(&local, 0, sizeof(local));
    socklen_t localLength = sizeof(local);
    if (getsockname(fd, (struct sockaddr *)&local, &localLength) != 0) {
        printf("[NET] ERROR: screen getsockname failed: %s\n",
               strerror(errno));
        close(fd);
        return -1;
    }
    if (local.ss_family == AF_INET) {
        *outPort = ntohs(((struct sockaddr_in *)&local)->sin_port);
    } else {
        *outPort = ntohs(((struct sockaddr_in6 *)&local)->sin6_port);
    }
    printf("[NET] bound screen TCP %s port %u fd=%d\n",
           addr_family_name(family), *outPort, fd);
    return fd;
}

static int socket_bound_family(int fd) {
    struct sockaddr_storage local;
    socklen_t localLen = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (fd < 0 ||
        getsockname(fd, (struct sockaddr *)&local, &localLen) != 0)
        return AF_UNSPEC;
    return local.ss_family;
}

static bool build_peer_sockaddr(const char *host, uint16_t port,
                                int socketFamily,
                                struct sockaddr_storage *out,
                                socklen_t *outLen,
                                char *display, size_t displayLen) {
    if (!host || !*host || !out || !outLen) return false;

    char addr[NI_MAXHOST];
    char scope[IF_NAMESIZE];
    memset(addr, 0, sizeof(addr));
    memset(scope, 0, sizeof(scope));
    snprintf(addr, sizeof(addr), "%s", host);

    char *pct = strchr(addr, '%');
    if (pct) {
        *pct = '\0';
        snprintf(scope, sizeof(scope), "%s", pct + 1);
    }

    memset(out, 0, sizeof(*out));
    struct in_addr ipv4;
    if (inet_pton(AF_INET, addr, &ipv4) == 1) {
        if (socketFamily == AF_INET6) {
            struct sockaddr_in6 *mapped = (struct sockaddr_in6 *)out;
            mapped->sin6_family = AF_INET6;
            mapped->sin6_port = htons(port);
            mapped->sin6_addr.s6_addr[10] = 0xff;
            mapped->sin6_addr.s6_addr[11] = 0xff;
            memcpy(&mapped->sin6_addr.s6_addr[12], &ipv4, sizeof(ipv4));
            *outLen = sizeof(*mapped);
        } else {
            struct sockaddr_in *sin = (struct sockaddr_in *)out;
            sin->sin_family = AF_INET;
            sin->sin_port = htons(port);
            sin->sin_addr = ipv4;
            *outLen = sizeof(*sin);
        }
        if (display && displayLen) snprintf(display, displayLen, "%s", addr);
        return true;
    }

    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)out;
    memset(sin6, 0, sizeof(*sin6));
    sin6->sin6_family = AF_INET6;
    sin6->sin6_port = htons(port);
    if (inet_pton(AF_INET6, addr, &sin6->sin6_addr) == 1) {
        if (scope[0]) {
            sin6->sin6_scope_id = if_nametoindex(scope);
            if (sin6->sin6_scope_id == 0) {
                printf("[TIMING] WARN: scope interface '%s' not found for %s\n",
                       scope, host);
            }
        } else if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
            sin6->sin6_scope_id = if_nametoindex("bridge100");
            if (sin6->sin6_scope_id) snprintf(scope, sizeof(scope), "bridge100");
            printf("[TIMING] IPv6 link-local had no scope; using bridge100 scope_id=%u\n",
                   sin6->sin6_scope_id);
        }
        *outLen = sizeof(struct sockaddr_in6);
        if (display && displayLen) {
            if (scope[0]) snprintf(display, displayLen, "%s%%%s", addr, scope);
            else snprintf(display, displayLen, "%s", addr);
        }
        return true;
    }

    return false;
}

/* Session state */
static int   g_timing_fd = -1;
static int   g_event_fd  = -1;
static int   g_keepalive_fd = -1;
static uint16_t g_timing_port = 0;
static uint16_t g_event_port  = 0;
static uint16_t g_keepalive_port = 0;
static bool  g_session_active = false;
static bool  g_timing_thread_running = false;
static bool  g_event_thread_running = false;
static int   g_event_client_fd = -1;  /* accepted event connection */
static volatile uint64_t g_last_touch_nanos = 0;

/* Screen stream state */
static int      g_screen_listen_fd = -1;     /* TCP listen socket for screen data */
static uint16_t g_screen_data_port = 0;
static uint64_t g_screen_conn_id = 0;        /* streamConnectionID from SETUP Phase 2 */
static uint8_t  g_screen_key[32] = {0};      /* ChaCha20-Poly1305 decryption key */
static bool     g_screen_key_valid = false;

/* iPhone's timing port and IP — needed for server-initiated timing negotiation */
static uint16_t g_iphone_timing_port = 0;
static char     g_iphone_ip[64] = {0};
static int      g_iphone_family = AF_UNSPEC;
static int      g_rtsp_sock = -1;  /* current RTSP control socket, for getpeername */
static volatile int g_timing_sync_count = 0;  /* responses received during negotiation */
static volatile double g_timing_remote_minus_local = 0.0;
static volatile double g_timing_best_rtt = DBL_MAX;
static volatile int32_t g_timing_offset_valid = 0;
static volatile uint32_t g_timing_maintenance_generation = 0;
static bool app_send_video_timing(void);

/* ═══════════════════════════════════════════════════════════════
 * NTP Timing Responder Thread
 *
 * The iPhone sends RTCP-style NTP timing requests (packet type 210)
 * to our timing UDP port. We must respond with type 211 containing
 * NTP timestamps for clock synchronisation. Without this, the
 * iPhone tears down the session.
 *
 * Packet format (32 bytes):
 *   [0]    v_p_m           (version/padding/marker, typically 0x80)
 *   [1]    pt              (210 = request, 211 = response)
 *   [2-3]  length          (network-order, 32-bit words minus 1 = 6)
 *   [4-7]  rtpTimestamp    (RTP timestamp, echoed back)
 *   [8-11] ntpOriginateHi  (T1 seconds — server copies client's T3)
 *   [12-15]ntpOriginateLo  (T1 fraction)
 *   [16-19]ntpReceiveHi    (T2 seconds — server receive time)
 *   [20-23]ntpReceiveLo    (T2 fraction)
 *   [24-27]ntpTransmitHi   (T3 seconds — server transmit time)
 *   [28-31]ntpTransmitLo   (T3 fraction)
 *
 * NTP epoch: seconds since 1900-01-01. Unix offset = 2208988800.
 * ═══════════════════════════════════════════════════════════════ */

#define NTP_EPOCH_OFFSET 2208988800UL

static void get_ntp_time(uint32_t *sec, uint32_t *frac) {
    /*
     * AirPlay timing is an NTP-encoded monotonic clock, not civil time.
     * Apple's simulator sends seconds equal to NTP_EPOCH_OFFSET plus its
     * monotonic uptime, and its CarPlaySDK converts between that clock and
     * mach_absolute_time for screen presentation and audio anchors.
     *
     * Using gettimeofday here made every timing exchange advertise a clock
     * billions of seconds away from the sender's media timeline. Pairing and
     * transport survived because NTP can describe a large fixed offset, but
     * the screen and buffered-audio paths then had to recover from a clock
     * domain we invented. Keep the same NTP wire representation Apple uses
     * while sourcing it from the host clock that media timestamps use.
     *
     * This must be mach_absolute_time, not CLOCK_MONOTONIC. On older iOS,
     * CoreMedia's host clock and mach_absolute_time include a different amount
     * of suspended time than CLOCK_MONOTONIC. Feeding the latter into NTP and
     * then scheduling on CMClockGetHostTimeClock moves every frame by the
     * accumulated sleep duration.
     */
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{
        mach_timebase_info(&timebase);
    });
    uint64_t ticks = mach_absolute_time();
    long double seconds =
        ((long double)ticks * (long double)timebase.numer) /
        ((long double)timebase.denom * 1000000000.0L);
    uint64_t wholeSeconds = (uint64_t)seconds;
    long double fractionalSeconds = seconds - (long double)wholeSeconds;
    *sec = (uint32_t)((uint64_t)NTP_EPOCH_OFFSET +
                      wholeSeconds);
    *frac = (uint32_t)(fractionalSeconds * 4294967296.0L);
}

static uint64_t synchronized_ntp_for_host_ticks(uint64_t hostTicks,
                                                uint64_t *rawNanos) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t timebaseOnce;
    dispatch_once(&timebaseOnce, ^{
        mach_timebase_info(&timebase);
    });

    long double ticksToSeconds =
        (long double)timebase.numer /
        ((long double)timebase.denom * 1000000000.0L);
    long double hostSeconds = (long double)hostTicks * ticksToSeconds;
    long double synchronizedSeconds =
        hostSeconds + (long double)NTP_EPOCH_OFFSET;
    if (g_timing_offset_valid) {
        synchronizedSeconds +=
            (long double)g_timing_remote_minus_local;
    }
    if (synchronizedSeconds < 0) synchronizedSeconds = 0;

    uint64_t wholeSeconds = (uint64_t)synchronizedSeconds;
    long double fractionalSeconds =
        synchronizedSeconds - (long double)wholeSeconds;
    if (rawNanos) {
        *rawNanos = (uint64_t)((long double)hostTicks *
                               (long double)timebase.numer /
                               (long double)timebase.denom);
    }
    return (wholeSeconds << 32) |
           (uint32_t)(fractionalSeconds * 4294967296.0L);
}

static double ntp_wire_time(const uint8_t bytes[8]) {
    uint32_t secondsNetwork = 0;
    uint32_t fractionNetwork = 0;
    memcpy(&secondsNetwork, bytes, sizeof(secondsNetwork));
    memcpy(&fractionNetwork, bytes + 4, sizeof(fractionNetwork));
    return (double)ntohl(secondsNetwork) +
           (double)ntohl(fractionNetwork) / 4294967296.0;
}

static void timing_thread_func(void *ctx) {
    (void)ctx;
    printf("[TIMING] NTP responder started on UDP port %u (fd=%d)\n",
           g_timing_port, g_timing_fd);
    fflush(stdout);

    uint8_t buf[64];
    struct sockaddr_storage from;

    while (g_timing_fd >= 0) {
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(g_timing_fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&from, &fromLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            printf("[TIMING] recvfrom error: %s\n", strerror(errno));
            break;
        }
        if (n < 32) {
            printf("[TIMING] Short packet (%zd bytes), ignoring\n", n);
            continue;
        }

        char fromHost[NI_MAXHOST] = {0};
        char fromPort[NI_MAXSERV] = {0};
        sockaddr_to_numeric((struct sockaddr *)&from, fromLen,
                            fromHost, sizeof(fromHost),
                            fromPort, sizeof(fromPort));

        uint8_t pt = buf[1];

        if (pt == 210) {
            /* Timing request from iPhone — build response */
            printf("[TIMING] Received timing REQUEST (%zd bytes) from %s:%s family=%s\n",
                   n, fromHost, fromPort, addr_family_name(from.ss_family));

            uint32_t recvSec, recvFrac;
            get_ntp_time(&recvSec, &recvFrac);

            uint8_t resp[32];
            memcpy(resp, buf, 32);

            resp[1] = 211;  /* response type */

            /* T1 (originate) = copy client's T3 (transmit) */
            memcpy(resp + 8, buf + 24, 8);

            /* T2 (receive) = our receive time */
            resp[16] = (recvSec >> 24) & 0xFF;
            resp[17] = (recvSec >> 16) & 0xFF;
            resp[18] = (recvSec >>  8) & 0xFF;
            resp[19] = (recvSec >>  0) & 0xFF;
            resp[20] = (recvFrac >> 24) & 0xFF;
            resp[21] = (recvFrac >> 16) & 0xFF;
            resp[22] = (recvFrac >>  8) & 0xFF;
            resp[23] = (recvFrac >>  0) & 0xFF;

            /* T3 (transmit) = our send time */
            uint32_t sendSec, sendFrac;
            get_ntp_time(&sendSec, &sendFrac);
            resp[24] = (sendSec >> 24) & 0xFF;
            resp[25] = (sendSec >> 16) & 0xFF;
            resp[26] = (sendSec >>  8) & 0xFF;
            resp[27] = (sendSec >>  0) & 0xFF;
            resp[28] = (sendFrac >> 24) & 0xFF;
            resp[29] = (sendFrac >> 16) & 0xFF;
            resp[30] = (sendFrac >>  8) & 0xFF;
            resp[31] = (sendFrac >>  0) & 0xFF;

            ssize_t sent = sendto(g_timing_fd, resp, 32, 0,
                                  (struct sockaddr *)&from, fromLen);
            printf("[TIMING] Sent NTP response (%zd bytes) to %s:%s family=%s\n",
                   sent, fromHost, fromPort, addr_family_name(from.ss_family));
        } else if (pt == 211) {
            /* Timing response from iPhone to our negotiation request */
            uint32_t receiveSeconds = 0;
            uint32_t receiveFraction = 0;
            get_ntp_time(&receiveSeconds, &receiveFraction);
            double t1 = ntp_wire_time(buf + 8);
            double t2 = ntp_wire_time(buf + 16);
            double t3 = ntp_wire_time(buf + 24);
            double t4 = (double)receiveSeconds +
                        (double)receiveFraction / 4294967296.0;
            double rtt = (t4 - t1) - (t3 - t2);
            double remoteMinusLocal =
                ((t2 - t1) + (t3 - t4)) * 0.5;
            bool selected = false;
            if (rtt >= 0.0 && rtt < 1.0 &&
                rtt < g_timing_best_rtt) {
                g_timing_best_rtt = rtt;
                g_timing_remote_minus_local = remoteMinusLocal;
                g_timing_offset_valid = 1;
                selected = true;
                app_send_video_timing();
            }
            g_timing_sync_count++;
            printf("[TIMING] Received timing RESPONSE (pt=211) from %s:%s "
                   "family=%s sync #%d rtt=%.3fms remote-local=%.3fms "
                   "selected=%d\n",
                   fromHost, fromPort, addr_family_name(from.ss_family),
                   g_timing_sync_count, rtt * 1000.0,
                   remoteMinusLocal * 1000.0, selected ? 1 : 0);
        } else {
            printf("[TIMING] Unknown packet type %u (%zd bytes)\n", pt, n);
        }
        fflush(stdout);
    }
    printf("[TIMING] Responder thread exiting\n");
    g_timing_thread_running = false;
}

static void start_timing_thread(void) {
    if (g_timing_thread_running || g_timing_fd < 0) return;
    g_timing_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        timing_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Event Port Acceptor Thread
 *
 * The iPhone connects to our event TCP port after SETUP.
 * We accept the connection and keep it alive. The event channel
 * uses HTTP/RTSP-like messaging for control events.
 * ═══════════════════════════════════════════════════════════════ */

static void event_thread_func(void *ctx) {
    (void)ctx;
    printf("[EVENT] Acceptor started on TCP port %u (fd=%d)\n",
           g_event_port, g_event_fd);
    fflush(stdout);

    while (g_event_fd >= 0) {
        struct sockaddr_storage ca;
        socklen_t cl = sizeof(ca);
        int client = accept(g_event_fd, (struct sockaddr *)&ca, &cl);
        if (client < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(100000);
                continue;
            }
            printf("[EVENT] accept error: %s\n", strerror(errno));
            break;
        }

        char host[NI_MAXHOST], serv[NI_MAXSERV];
        sockaddr_to_numeric((struct sockaddr *)&ca, cl,
                            host, sizeof(host), serv, sizeof(serv));
        printf("[EVENT] *** Connection from %s:%s family=%s ***\n",
               host, serv, addr_family_name(ca.ss_family));
        fflush(stdout);

        g_event_client_fd = client;

        /* HID commands are tiny and latency-sensitive. Without TCP_NODELAY,
         * Nagle combines consecutive reports while waiting for the iPhone's
         * ACK, which turns continuous swipes into visible stair-steps. */
        int yes = 1;
        setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        set_event_socket_qos(client);

        /* Read loop — decrypt ChaCha20-Poly1305 framed messages */
        uint8_t buf[16384];
        struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        if (g_event_enc.active) {
            printf("[EVENT] Encrypted event channel active\n");
            fflush(stdout);
            uint64_t normalResponseCount = 0;
            while (1) {
                int ptLen = enc_recv_frame(client, &g_event_enc, buf, sizeof(buf));
                if (ptLen == -2) {
                    printf("[EVENT] Encrypted channel idle, still alive\n");
                    fflush(stdout);
                    continue;
                }
                if (ptLen < 0) {
                    printf("[EVENT] Encrypted recv error or disconnect\n");
                    break;
                }
                if (ptLen >= 12 &&
                    memcmp(buf, "RTSP/1.0 200", 12) == 0) {
                    normalResponseCount++;
                    if (normalResponseCount % 250 == 0) {
                        printf("[EVENT] %llu normal HID acknowledgements\n",
                               normalResponseCount);
                    }
                    continue;
                }
                if (process_event_command_frame(buf, (size_t)ptLen))
                    continue;
                printf("[EVENT] Decrypted %d bytes (nonce=%llu)\n",
                       ptLen, g_event_enc.readNonce - 1);
                int dump = ptLen > 256 ? 256 : ptLen;
                printf("[EVENT] ASCII: ");
                for (int i = 0; i < dump; i++)
                    printf("%c", (buf[i] >= 0x20 && buf[i] < 0x7f) ? buf[i] : '.');
                printf("\n");
                fflush(stdout);
            }
        } else {
            printf("[EVENT] WARNING: plaintext event channel (no encryption keys)\n");
            fflush(stdout);
            while (1) {
                ssize_t n = recv(client, buf, sizeof(buf), 0);
                if (n > 0) {
                    printf("[EVENT] Received %zd bytes:", n);
                    int dump = n > 128 ? 128 : (int)n;
                    for (int i = 0; i < dump; i++) printf(" %02X", buf[i]);
                    if (n > 128) printf(" ...");
                    printf("\n");
                    fflush(stdout);
                } else if (n == 0) {
                    printf("[EVENT] Client disconnected\n");
                    break;
                } else {
                    if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
                    printf("[EVENT] recv error: %s\n", strerror(errno));
                    break;
                }
            }
        }
        close(client);
        g_event_client_fd = -1;
        printf("[EVENT] Client connection closed\n");
        fflush(stdout);
    }
    g_event_thread_running = false;
}

static void start_event_thread(void) {
    if (g_event_thread_running || g_event_fd < 0) return;
    g_event_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        event_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * KeepAlive Port Responder
 *
 * UDP keep-alive: just echo back whatever the iPhone sends.
 * ═══════════════════════════════════════════════════════════════ */

static bool g_keepalive_thread_running = false;

static void keepalive_thread_func(void *ctx) {
    (void)ctx;
    printf("[KEEPALIVE] Responder started on UDP port %u (fd=%d)\n",
           g_keepalive_port, g_keepalive_fd);
    fflush(stdout);

    uint8_t buf[256];
    struct sockaddr_storage from;

    while (g_keepalive_fd >= 0) {
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(g_keepalive_fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&from, &fromLen);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        printf("[KEEPALIVE] Received %zd bytes\n", n);
        /* Echo back */
        sendto(g_keepalive_fd, buf, n, 0,
               (struct sockaddr *)&from, fromLen);
        fflush(stdout);
    }
    g_keepalive_thread_running = false;
}

static void start_keepalive_thread(void) {
    if (g_keepalive_thread_running || g_keepalive_fd < 0) return;
    g_keepalive_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        keepalive_thread_func(NULL);
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Screen Data Receiver Thread
 *
 * Accepts TCP connection from iPhone on the screen data port,
 * derives ChaCha20-Poly1305 decryption key from pair-verify shared
 * secret + streamConnectionID, and reads incoming video frames.
 *
 * Screen data framing: each frame is a 128-byte header followed by
 * encrypted H.264 NAL unit data.
 * ═══════════════════════════════════════════════════════════════ */
static volatile int32_t g_screen_thread_running = 0;
static volatile int32_t g_screen_start_pending = 0;
static uint64_t monotonic_nanos_now(void);

/* ── Helpers: read exactly N bytes from TCP ── */
static bool tcp_read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

/*
 * A completed-frame arrival gap cannot distinguish sender starvation from
 * TCP head-of-line blocking: the old telemetry only sampled the socket after
 * recv() had finally returned the whole record. Keep the screen socket's
 * blocking semantics, but use select() as an observation point while waiting.
 * No timeout is applied to the connection and no bytes or frames are dropped.
 */
typedef struct {
    bool valid;
    uint32_t receiveWindow;
    uint32_t smoothedRTT;
    uint32_t currentRTT;
    uint32_t retransmitTimeout;
    uint32_t flags;
    uint64_t receivedPackets;
    uint64_t receivedBytes;
    uint64_t outOfOrderBytes;
} ScreenTCPSnapshot;

static ScreenTCPSnapshot screen_tcp_snapshot(int fd) {
    ScreenTCPSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
#ifdef TCP_CONNECTION_INFO
    struct tcp_connection_info tcpInfo;
    memset(&tcpInfo, 0, sizeof(tcpInfo));
    socklen_t tcpInfoLength = sizeof(tcpInfo);
    if (getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &tcpInfo,
                   &tcpInfoLength) == 0) {
        snapshot.valid = true;
        snapshot.receiveWindow = tcpInfo.tcpi_rcv_wnd;
        snapshot.smoothedRTT = tcpInfo.tcpi_srtt;
        snapshot.currentRTT = tcpInfo.tcpi_rttcur;
        snapshot.retransmitTimeout = tcpInfo.tcpi_rto;
        snapshot.flags = tcpInfo.tcpi_flags;
        snapshot.receivedPackets = tcpInfo.tcpi_rxpackets;
        snapshot.receivedBytes = tcpInfo.tcpi_rxbytes;
        snapshot.outOfOrderBytes = tcpInfo.tcpi_rxoutoforderbytes;
    }
#else
    (void)fd;
#endif
    return snapshot;
}

static void screen_log_tcp_wait(int fd, const char *phase,
                                uint64_t startedNanos, size_t got, size_t need,
                                ScreenTCPSnapshot baseline,
                                const char *event) {
    uint64_t nowNanos = monotonic_nanos_now();
    double waitedMillis = (double)(nowNanos - startedNanos) / 1000000.0;
    int pendingBytes = 0;
    if (ioctl(fd, FIONREAD, &pendingBytes) != 0 || pendingBytes < 0)
        pendingBytes = 0;

    ScreenTCPSnapshot current = screen_tcp_snapshot(fd);
    uint64_t packetDelta = 0;
    uint64_t byteDelta = 0;
    uint64_t outOfOrderDelta = 0;
    if (baseline.valid && current.valid) {
        packetDelta = current.receivedPackets - baseline.receivedPackets;
        byteDelta = current.receivedBytes - baseline.receivedBytes;
        outOfOrderDelta =
            current.outOfOrderBytes - baseline.outOfOrderBytes;
    }

    printf("[SCREEN][TCP-%s] phase=%s waited=%.1fms read=%zu/%zu "
           "socket=%d rxPackets=%llu(+%llu) rxBytes=%llu(+%llu) "
           "rxOOO=%llu(+%llu) rcvWnd=%u srtt=%u rtt=%u rto=%u "
           "flags=0x%x\n",
           event, phase, waitedMillis, got, need, pendingBytes,
           (unsigned long long)current.receivedPackets,
           (unsigned long long)packetDelta,
           (unsigned long long)current.receivedBytes,
           (unsigned long long)byteDelta,
           (unsigned long long)current.outOfOrderBytes,
           (unsigned long long)outOfOrderDelta,
           current.receiveWindow, current.smoothedRTT, current.currentRTT,
           current.retransmitTimeout, current.flags);
}

static bool screen_read_exact(int fd, uint8_t *buf, size_t len,
                              const char *phase) {
    const uint64_t logThresholdNanos = 500ULL * NSEC_PER_MSEC;
    const uint64_t logIntervalNanos = 500ULL * NSEC_PER_MSEC;
    const uint64_t touchWindowNanos = 2ULL * NSEC_PER_SEC;
    const bool isBody = strcmp(phase, "body") == 0;
    uint64_t startedNanos = monotonic_nanos_now();
    uint64_t lastLogNanos = 0;
    bool observedInteractiveWait = false;
    ScreenTCPSnapshot baseline = screen_tcp_snapshot(fd);
    size_t got = 0;

    while (got < len) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);
        struct timeval timeout = { .tv_sec = 0, .tv_usec = 250000 };
        int ready = select(fd + 1, &readSet, NULL, NULL, &timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (ready == 0) {
            uint64_t nowNanos = monotonic_nanos_now();
            uint64_t waitedNanos = nowNanos - startedNanos;
            uint64_t lastTouchNanos = g_last_touch_nanos;
            bool touchIsRecent =
                lastTouchNanos != 0 && nowNanos >= lastTouchNanos &&
                nowNanos - lastTouchNanos <= touchWindowNanos;
            if (touchIsRecent) observedInteractiveWait = true;
            if (waitedNanos >= logThresholdNanos &&
                (isBody || touchIsRecent) &&
                (lastLogNanos == 0 ||
                 nowNanos - lastLogNanos >= logIntervalNanos)) {
                screen_log_tcp_wait(fd, phase, startedNanos, got, len,
                                    baseline, "WAIT");
                lastLogNanos = nowNanos;
            }
            continue;
        }

        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        got += (size_t)n;
    }

    uint64_t completedNanos = monotonic_nanos_now();
    if (completedNanos - startedNanos >= logThresholdNanos &&
        (isBody || observedInteractiveWait)) {
        screen_log_tcp_wait(fd, phase, startedNanos, got, len, baseline,
                            "RECOVER");
    }
    return true;
}

/* ── IPC to iPadPlay app via Unix socket ── */
#define IPADPLAY_SOCK "/tmp/ipadplay.sock"
#define MSG_VIDEO_CONFIG 0x01
#define MSG_VIDEO_FRAME  0x02
#define MSG_STATUS       0x04   /* services → app, 1 byte status code */
#define MSG_APP_VISIBILITY 0x05 /* app → services, 1 while foreground */
#define MSG_VIDEO_TIMING 0x06   /* services → app, uint32 latency in ms */
#define MSG_VIDEO_RESYNC 0x07   /* app → services, renderer needs keyframe */
#define VIDEO_FRAME_METADATA_SIZE 56
/* STATUS_* codes are forward-declared at the top of the file. */

static int g_app_sock = -1;
static volatile bool g_app_video_enabled = true;
static volatile uint32_t g_screen_latency_ms = 75;

/* AirPlayScreenHeader.smallParam[1] bit 1 (kAirPlayScreenFlag_RespectTimestamps).
 * When the sender sets it, params[0] of every VideoFrame carries the 32.32
 * fixed-point time on the session timeline at which the frame must appear.
 * Displaying on arrival instead turns delivery jitter straight into judder and
 * throws away frames that arrive inside one refresh of each other. */
static volatile uint32_t g_screen_respect_timestamps = 0;

static uint64_t monotonic_nanos_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

/* Presentation contract:
 * [uint32 latencyMs][uint8 respectTimestamps]
 * [double senderToHostOffset][uint8 offsetValid].
 *
 * NTP gives remote-minus-local. Frame timestamps are on the remote timeline,
 * so senderToHostOffset is its negation. */
static uint32_t build_video_timing_payload(uint8_t out[14]) {
    uint32_t latency = g_screen_latency_ms;
    memcpy(out, &latency, sizeof(latency));
    out[4] = g_screen_respect_timestamps ? 1 : 0;
    double senderToHostOffset = -g_timing_remote_minus_local;
    memcpy(out + 5, &senderToHostOffset, sizeof(senderToHostOffset));
    out[13] = g_timing_offset_valid ? 1 : 0;
    return 14;
}
static dispatch_semaphore_t g_app_send_lock = NULL;
static dispatch_semaphore_t g_video_config_lock = NULL;
static uint8_t *g_latest_video_config = NULL;
static uint32_t g_latest_video_config_length = 0;
static void start_touch_reader(int fd);  /* forward declaration */
static void send_request_ui_command(const char *reason);
static void send_take_main_screen_command(const char *reason);

static bool app_write_all(int fd, const uint8_t *data, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t n = write(fd, data + sent, length - sent);
        if (n <= 0) return false;
        sent += (size_t)n;
    }
    return true;
}

static bool app_write_msg_to_socket(int fd, uint8_t type,
                                    const uint8_t *data, uint32_t len) {
    uint8_t hdr[5] = {
        len & 0xFF, (len >> 8) & 0xFF,
        (len >> 16) & 0xFF, (len >> 24) & 0xFF, type
    };
    return app_write_all(fd, hdr, sizeof(hdr)) &&
           app_write_all(fd, data, len);
}

static bool app_ensure_connected(void) {
    if (g_app_sock >= 0) return true;
    g_app_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_app_sock < 0) return false;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, IPADPLAY_SOCK, sizeof(addr.sun_path) - 1);
    if (connect(g_app_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(g_app_sock);
        g_app_sock = -1;
        return false;
    }
    int yes = 1;
    setsockopt(g_app_sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    printf("[SCREEN] Connected to iPadPlay app via %s\n", IPADPLAY_SOCK);
    fflush(stdout);

    /* Start touch reader on this socket (reads touch events from app) */
    start_touch_reader(g_app_sock);

    /* A relaunched UI process has no H.264 format description. Bootstrap each
     * new IPC connection with the negotiated timing and latest SPS/PPS before
     * the next video frame. */
    uint8_t timingPayload[14];
    uint32_t timingLen = build_video_timing_payload(timingPayload);
    if (!app_write_msg_to_socket(g_app_sock, MSG_VIDEO_TIMING,
                                 timingPayload, timingLen))
        goto fail;
    if (g_video_config_lock)
        dispatch_semaphore_wait(g_video_config_lock,
                                DISPATCH_TIME_FOREVER);
    if (g_latest_video_config && g_latest_video_config_length > 0) {
        bool configSent = app_write_msg_to_socket(
            g_app_sock, MSG_VIDEO_CONFIG, g_latest_video_config,
            g_latest_video_config_length);
        if (g_video_config_lock)
            dispatch_semaphore_signal(g_video_config_lock);
        if (!configSent) goto fail;
        printf("[SCREEN] Bootstrapped new app connection with video config\n");
        /* The new decoder cannot consume an arbitrary delta frame. Cycling
         * MainScreen asks the phone for a fresh config + IDR instead of
         * copying and replaying an ever-growing compressed GOP. */
        send_take_main_screen_command("new app decoder");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     100 * NSEC_PER_MSEC),
                       dispatch_get_global_queue(0, 0), ^{
            send_request_ui_command("new app decoder");
        });
    } else if (g_video_config_lock) {
        dispatch_semaphore_signal(g_video_config_lock);
    }
    return true;

fail:
    close(g_app_sock);
    g_app_sock = -1;
    return false;
}

static bool app_send_msg(uint8_t type, const uint8_t *data, uint32_t len) {
    if (g_app_send_lock)
        dispatch_semaphore_wait(g_app_send_lock, DISPATCH_TIME_FOREVER);
    bool success = false;
    if (!app_ensure_connected()) goto done;
    if (!app_write_msg_to_socket(g_app_sock, type, data, len)) goto fail;
    success = true;
    goto done;
fail:
    close(g_app_sock);
    g_app_sock = -1;
done:
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
    return success;
}

static bool app_send_video_timing(void) {
    uint8_t payload[14];
    uint32_t len = build_video_timing_payload(payload);
    return app_send_msg(MSG_VIDEO_TIMING, payload, len);
}

/* ═══════════════════════════════════════════════════════════════
 * Wireless CarPlay audio
 *
 * Low-latency audio arrives as encrypted RTP/UDP. MainBuffered (type 103)
 * instead uses a TCP byte stream containing 2-byte, big-endian, inclusive
 * record lengths followed by encrypted RTP packets. The network service
 * authenticates and decrypts packets, then forwards codec frames to Showcase;
 * the app owns the system audio session and hardware codec.
 * ═══════════════════════════════════════════════════════════════ */

typedef struct {
    uint32_t type;
    int dataFd;
    int controlFd;
    uint16_t dataPort;
    uint16_t controlPort;
    uint64_t connectionID;
    uint64_t formatMask;
    uint32_t framesPerPacket;
    uint32_t latencyMs;
    uint8_t key[32];
    bool keyValid;
    volatile int32_t running;
    volatile uint64_t generation;
    bool haveSequence;
    uint16_t lastSequence;
    uint64_t packetCount;
    uint64_t decryptErrors;
    uint64_t sequenceGaps;
    uint64_t lastArrivalNanos;
    uint64_t maxArrivalGapNanos;
    uint64_t longArrivalGaps;
    uint32_t lastRtpTimestamp;
    uint64_t lastHostNTP;
    int64_t renderedSampleTime;
    uint64_t renderedHostNTP;
    uint64_t renderedHostRawNanos;
    uint64_t renderUpdateCount;
    bool flushPending;
    uint16_t flushUntilSequence;
    uint32_t flushUntilTimestamp;
    uint64_t flushDropCount;
    bool usesTCP;
} carplay_audio_stream_t;

typedef struct {
    carplay_audio_stream_t *stream;
    uint64_t generation;
    int dataFd;
    uint16_t dataPort;
    bool usesTCP;
} carplay_audio_receiver_context_t;

static pthread_mutex_t g_audio_feedback_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_audio_control_lock = PTHREAD_MUTEX_INITIALIZER;

static carplay_audio_stream_t g_audio_streams[4] = {
    { .type = 100, .dataFd = -1, .controlFd = -1 },
    { .type = 101, .dataFd = -1, .controlFd = -1 },
    { .type = 102, .dataFd = -1, .controlFd = -1 },
    { .type = 103, .dataFd = -1, .controlFd = -1 }   /* MainBufferedAudio */
};

static carplay_audio_stream_t *audio_stream_for_type(uint32_t type) {
    for (size_t i = 0; i < sizeof(g_audio_streams) /
                            sizeof(g_audio_streams[0]); i++) {
        if (g_audio_streams[i].type == type) return &g_audio_streams[i];
    }
    return NULL;
}

static uint32_t audio_default_frames_per_packet(uint64_t formatMask) {
    if (formatMask & 0x00008854ULL)
        return 1; /* PCM */
    if (formatMask == 0x00400000ULL || formatMask == 0x00800000ULL)
        return 1024; /* AAC-LC */
    if (formatMask == 0x10000000ULL) return 320; /* Opus 16 kHz, 20 ms */
    if (formatMask == 0x20000000ULL) return 480; /* Opus 24 kHz, 20 ms */
    if (formatMask == 0x40000000ULL) return 960; /* Opus 48 kHz, 20 ms */
    return 512;      /* AAC-ELD */
}

static double audio_sample_rate(uint64_t formatMask) {
    switch (formatMask) {
        case 0x00000004ULL: return 8000.0;
        case 0x00000010ULL: return 16000.0;
        case 0x00000040ULL: return 24000.0;
        case 0x00000800ULL:
        case 0x00400000ULL:
        case 0x01000000ULL: return 44100.0;
        case 0x00008000ULL:
        case 0x00800000ULL:
        case 0x02000000ULL: return 48000.0;
        case 0x04000000ULL: return 16000.0;
        case 0x08000000ULL: return 24000.0;
        case 0x10000000ULL: return 16000.0;
        case 0x20000000ULL: return 24000.0;
        case 0x40000000ULL: return 48000.0;
        default: return 0.0;
    }
}

static void app_send_audio_config(carplay_audio_stream_t *stream) {
    uint8_t payload[20] = {0};
    memcpy(payload, &stream->type, 4);
    memcpy(payload + 4, &stream->formatMask, 8);
    memcpy(payload + 12, &stream->framesPerPacket, 4);
    memcpy(payload + 16, &stream->latencyMs, 4);
    app_send_msg(MSG_AUDIO_CONFIG, payload, sizeof(payload));
}

static void app_send_audio_packet(carplay_audio_stream_t *stream,
                                  uint16_t sequence, uint32_t timestamp,
                                  const uint8_t *bytes, uint32_t length) {
    uint32_t msgLength = 12 + length;
    uint8_t *message = malloc(msgLength);
    if (!message) return;
    memset(message, 0, 12);
    memcpy(message, &stream->type, 4);
    memcpy(message + 4, &sequence, 2);
    memcpy(message + 8, &timestamp, 4);
    memcpy(message + 12, bytes, length);
    app_send_msg(MSG_AUDIO_PACKET, message, msgLength);
    free(message);
}

static void app_send_audio_control(uint32_t streamType, uint8_t action) {
    uint8_t payload[5] = {0};
    memcpy(payload, &streamType, 4);
    payload[4] = action;
    bool sent = app_send_msg(MSG_AUDIO_CONTROL, payload, sizeof(payload));
    printf("[AUDIO] control stream=%u action=%u app=%s\n",
           streamType, action, sent ? "sent" : "failed");
}

static void audio_process_rtp_packet(carplay_audio_stream_t *stream,
                                     uint8_t *packet, size_t packetLength) {
    if (!stream || !packet || packetLength < 12 + 24 ||
        !stream->keyValid) return;

    uint16_t sequenceNetwork = 0;
    uint32_t timestampNetwork = 0;
    memcpy(&sequenceNetwork, packet + 2, 2);
    memcpy(&timestampNetwork, packet + 4, 4);
    uint16_t sequence = ntohs(sequenceNetwork);
    uint32_t timestamp = ntohl(timestampNetwork);
    uint64_t arrivalNanos = monotonic_nanos_now();
    uint64_t arrivalGapNanos = stream->lastArrivalNanos
        ? arrivalNanos - stream->lastArrivalNanos : 0;
    stream->lastArrivalNanos = arrivalNanos;
    if (arrivalGapNanos > stream->maxArrivalGapNanos)
        stream->maxArrivalGapNanos = arrivalGapNanos;
    if (arrivalGapNanos >= 100 * NSEC_PER_MSEC) {
        stream->longArrivalGaps++;
        printf("[AUDIO] stream=%u arrival gap #%llu %.1fms seq=%u\n",
               stream->type,
               (unsigned long long)stream->longArrivalGaps,
               (double)arrivalGapNanos / 1000000.0, sequence);
    }

    /*
     * FLUSHBUFFERED names the first packet of the sender's new RTP epoch with
     * an extended sequence number and timestamp. The RTP header carries only
     * the low 16 sequence bits. Drop the old epoch until that boundary (or the
     * first packet modularly after it) so it cannot refill the AudioQueue
     * after the app has discarded its stale buffered media.
     */
    bool dropForFlush = false;
    bool completedFlush = false;
    uint64_t droppedForFlush = 0;
    pthread_mutex_lock(&g_audio_control_lock);
    if (stream->flushPending) {
        int16_t relative =
            (int16_t)(sequence - stream->flushUntilSequence);
        if (relative < 0 && timestamp != stream->flushUntilTimestamp) {
            stream->flushDropCount++;
            droppedForFlush = stream->flushDropCount;
            dropForFlush = true;
        } else {
            stream->flushPending = false;
            completedFlush = true;
            droppedForFlush = stream->flushDropCount;
        }
    }
    pthread_mutex_unlock(&g_audio_control_lock);
    if (dropForFlush) {
        if (droppedForFlush <= 3 || (droppedForFlush % 100) == 0) {
            printf("[AUDIO] stream=%u flush drop #%llu seq=%u ts=%u\n",
                   stream->type, (unsigned long long)droppedForFlush,
                   sequence, timestamp);
        }
        return;
    }
    if (completedFlush) {
        printf("[AUDIO] stream=%u flush boundary reached seq=%u ts=%u "
               "dropped=%llu\n",
               stream->type, sequence, timestamp,
               (unsigned long long)droppedForFlush);
    }

    uint8_t *encrypted = packet + 12;
    size_t encryptedLength = packetLength - 12;
    if (encryptedLength < 24) return;

    size_t ciphertextLength = encryptedLength - 24;
    uint8_t nonce[12] = {0};
    memcpy(nonce + 4, encrypted + encryptedLength - 8, 8);
    uint8_t *tag = encrypted + encryptedLength - 24;

    /* Modern CarPlay audio authenticates RTP timestamp + SSRC, both in
     * their network-order wire representation. */
    crypto_aead_ctx crypto;
    crypto_aead_init_ietf(&crypto, stream->key, nonce);
    int result = crypto_aead_read(&crypto, encrypted, tag,
                                  packet + 4, 8,
                                  encrypted, ciphertextLength);
    crypto_wipe(&crypto, sizeof(crypto));
    if (result != 0) {
        stream->decryptErrors++;
        if (stream->decryptErrors <= 3 ||
            (stream->decryptErrors % 100) == 0) {
            printf("[AUDIO] stream=%u decrypt failure #%llu seq=%u\n",
                   stream->type,
                   (unsigned long long)stream->decryptErrors, sequence);
        }
        return;
    }

    if (stream->haveSequence &&
        sequence != (uint16_t)(stream->lastSequence + 1)) {
        stream->sequenceGaps++;
        printf("[AUDIO] stream=%u RTP gap #%llu expected=%u got=%u\n",
               stream->type,
               (unsigned long long)stream->sequenceGaps,
               (uint16_t)(stream->lastSequence + 1), sequence);
    }
    stream->lastSequence = sequence;
    stream->haveSequence = true;
    stream->packetCount++;
    uint32_t hostSeconds = 0;
    uint32_t hostFraction = 0;
    get_ntp_time(&hostSeconds, &hostFraction);
    stream->lastRtpTimestamp = timestamp;
    stream->lastHostNTP =
        ((uint64_t)hostSeconds << 32) | hostFraction;
    app_send_audio_packet(stream, sequence, timestamp, encrypted,
                          (uint32_t)ciphertextLength);
    if (stream->packetCount <= 3 ||
        (stream->packetCount % 500) == 0) {
        printf("[AUDIO] stream=%u packet #%llu seq=%u ts=%u bytes=%zu\n",
               stream->type, (unsigned long long)stream->packetCount,
               sequence, timestamp, ciphertextLength);
    }
}

static void audio_receiver_func(void *arg) {
    carplay_audio_receiver_context_t *context = arg;
    carplay_audio_stream_t *stream = context->stream;
    uint64_t generation = context->generation;
    int dataFd = context->dataFd;
    uint8_t packet[65536];
    printf("[AUDIO] stream=%u receiver started %s port=%u fd=%d "
           "generation=%llu format=0x%llx framesPerPacket=%u key=%d\n",
           stream->type, context->usesTCP ? "TCP" : "UDP",
           context->dataPort, dataFd, (unsigned long long)generation,
           (unsigned long long)stream->formatMask,
           stream->framesPerPacket, stream->keyValid ? 1 : 0);
    app_send_audio_config(stream);

    if (context->usesTCP) {
        int client = accept(dataFd, NULL, NULL);
        if (client < 0) {
            printf("[AUDIO] stream=%u TCP accept failed: %s\n",
                   stream->type, strerror(errno));
        } else {
            int receiveBuffer = 2 * 1024 * 1024;
            setsockopt(client, SOL_SOCKET, SO_RCVBUF,
                       &receiveBuffer, sizeof(receiveBuffer));
            printf("[AUDIO] stream=%u TCP sender connected fd=%d\n",
                   stream->type, client);
            while (stream->running &&
                   stream->generation == generation) {
                uint8_t lengthBytes[2];
                if (!tcp_read_exact(client, lengthBytes,
                                    sizeof(lengthBytes))) break;
                uint16_t inclusiveLength =
                    ((uint16_t)lengthBytes[0] << 8) | lengthBytes[1];
                if (inclusiveLength < 2 + 12 + 24) {
                    printf("[AUDIO] stream=%u invalid TCP record length=%u\n",
                           stream->type, inclusiveLength);
                    break;
                }
                size_t packetLength = (size_t)inclusiveLength - 2;
                if (!tcp_read_exact(client, packet, packetLength)) break;
                if (stream->generation != generation) break;
                audio_process_rtp_packet(stream, packet, packetLength);
            }
            close(client);
        }
    } else {
        while (stream->running &&
               stream->generation == generation) {
            ssize_t received = recvfrom(dataFd, packet,
                                        sizeof(packet), 0, NULL, NULL);
            if (received < 0) {
                if (errno == EINTR || errno == EAGAIN ||
                    errno == EWOULDBLOCK) continue;
                printf("[AUDIO] stream=%u recv error: %s\n",
                       stream->type, strerror(errno));
                break;
            }
            if (stream->generation != generation) break;
            audio_process_rtp_packet(stream, packet, (size_t)received);
        }
    }
    if (stream->generation == generation)
        __sync_bool_compare_and_swap(&stream->running, 1, 0);
    printf("[AUDIO] stream=%u receiver stopped generation=%llu "
           "packets=%llu gaps=%llu decryptErrors=%llu "
           "arrivalGaps=%llu maxArrival=%.1fms\n",
           stream->type, (unsigned long long)generation,
           (unsigned long long)stream->packetCount,
           (unsigned long long)stream->sequenceGaps,
           (unsigned long long)stream->decryptErrors,
           (unsigned long long)stream->longArrivalGaps,
           (double)stream->maxArrivalGapNanos / 1000000.0);
    free(context);
}

static void start_audio_receiver(carplay_audio_stream_t *stream) {
    if (!stream || stream->dataFd < 0 ||
        !__sync_bool_compare_and_swap(&stream->running, 0, 1)) return;
    carplay_audio_receiver_context_t *context =
        calloc(1, sizeof(*context));
    if (!context) {
        stream->running = 0;
        return;
    }
    context->stream = stream;
    context->generation = stream->generation;
    context->dataFd = stream->dataFd;
    context->dataPort = stream->dataPort;
    context->usesTCP = stream->usesTCP;
    if (!stream->usesTCP) {
        int receiveBuffer = 512 * 1024;
        setsockopt(stream->dataFd, SOL_SOCKET, SO_RCVBUF,
                   &receiveBuffer, sizeof(receiveBuffer));
        struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(stream->dataFd, SOL_SOCKET, SO_RCVTIMEO,
                   &timeout, sizeof(timeout));
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                   ^{ audio_receiver_func(context); });
}

static void stop_audio_receiver(carplay_audio_stream_t *stream,
                                const char *reason) {
    if (!stream) return;
    bool wasActive =
        stream->running || stream->dataFd >= 0 || stream->controlFd >= 0 ||
        stream->formatMask != 0;
    if (!wasActive) return;

    uint64_t oldGeneration = stream->generation;
    __sync_add_and_fetch(&stream->generation, 1);
    stream->running = 0;

    int dataFd = stream->dataFd;
    int controlFd = stream->controlFd;
    stream->dataFd = -1;
    stream->controlFd = -1;
    stream->dataPort = 0;
    stream->controlPort = 0;
    if (dataFd >= 0) {
        shutdown(dataFd, SHUT_RDWR);
        close(dataFd);
    }
    if (controlFd >= 0 && controlFd != dataFd) {
        shutdown(controlFd, SHUT_RDWR);
        close(controlFd);
    }

    stream->formatMask = 0;
    stream->keyValid = false;
    stream->haveSequence = false;
    pthread_mutex_lock(&g_audio_feedback_lock);
    stream->renderedSampleTime = 0;
    stream->renderedHostNTP = 0;
    stream->renderedHostRawNanos = 0;
    stream->renderUpdateCount = 0;
    pthread_mutex_unlock(&g_audio_feedback_lock);
    app_send_audio_control(stream->type, AUDIO_CONTROL_STOP);
    printf("[AUDIO] stream=%u stopped generation=%llu reason=%s\n",
           stream->type, (unsigned long long)oldGeneration,
           reason ? reason : "unspecified");
}

/* ── Send a single-byte status update to the iPadPlay app (best-effort) ── */
static void app_send_status(uint8_t code) {
    app_send_msg(MSG_STATUS, &code, 1);
}

static bool h264_frame_contains_idr(const uint8_t *bytes, size_t length) {
    size_t offset = 0;
    while (offset + 5 <= length) {
        uint32_t nalLength =
            ((uint32_t)bytes[offset] << 24) |
            ((uint32_t)bytes[offset + 1] << 16) |
            ((uint32_t)bytes[offset + 2] << 8) |
            (uint32_t)bytes[offset + 3];
        if (nalLength == 0 || offset + 4 + nalLength > length) break;
        if ((bytes[offset + 4] & 0x1f) == 5) return true;
        offset += 4 + nalLength;
    }
    return false;
}

static bool app_send_video_frame(uint64_t timestamp, bool isIDR,
                                 const uint8_t *bytes, uint32_t length,
                                 uint32_t serviceSequence,
                                 uint64_t serviceArrivalNanos,
                                 uint32_t arrivalGapMicros,
                                 uint32_t tcpPendingBytes,
                                 uint32_t tcpReceiveWindow,
                                 uint32_t tcpSmoothedRTT,
                                 uint32_t tcpCurrentRTT,
                                 uint32_t tcpFlags,
                                 uint32_t decryptMicros) {
    uint32_t messageLength = VIDEO_FRAME_METADATA_SIZE + length;
    uint8_t header[5] = {
        messageLength & 0xff, (messageLength >> 8) & 0xff,
        (messageLength >> 16) & 0xff, (messageLength >> 24) & 0xff,
        MSG_VIDEO_FRAME
    };
    uint8_t metadata[VIDEO_FRAME_METADATA_SIZE] = {0};
    memcpy(metadata, &timestamp, sizeof(timestamp));
    metadata[8] = isIDR ? 1 : 0;
    metadata[9] = 1; /* metadata layout version */
    memcpy(metadata + 12, &serviceSequence, sizeof(serviceSequence));
    memcpy(metadata + 16, &serviceArrivalNanos,
           sizeof(serviceArrivalNanos));
    memcpy(metadata + 24, &arrivalGapMicros, sizeof(arrivalGapMicros));
    memcpy(metadata + 28, &tcpPendingBytes, sizeof(tcpPendingBytes));
    memcpy(metadata + 32, &tcpReceiveWindow, sizeof(tcpReceiveWindow));
    memcpy(metadata + 36, &tcpSmoothedRTT, sizeof(tcpSmoothedRTT));
    memcpy(metadata + 40, &tcpCurrentRTT, sizeof(tcpCurrentRTT));
    memcpy(metadata + 44, &tcpFlags, sizeof(tcpFlags));
    memcpy(metadata + 48, &decryptMicros, sizeof(decryptMicros));

    uint64_t lockStarted = monotonic_nanos_now();
    if (g_app_send_lock)
        dispatch_semaphore_wait(g_app_send_lock, DISPATCH_TIME_FOREVER);
    uint64_t lockAcquired = monotonic_nanos_now();
    bool success = false;
    if (!app_ensure_connected()) goto done;
    success = app_write_all(g_app_sock, header, sizeof(header)) &&
              app_write_all(g_app_sock, metadata, sizeof(metadata)) &&
              app_write_all(g_app_sock, bytes, length);
    if (!success) {
        close(g_app_sock);
        g_app_sock = -1;
    }
done:
    ;
    uint64_t writeFinished = monotonic_nanos_now();
    double lockWaitMs = (double)(lockAcquired - lockStarted) / 1000000.0;
    double ipcHoldMs = (double)(writeFinished - lockAcquired) / 1000000.0;
    if (!success || arrivalGapMicros > 50000 ||
        serviceSequence % 300 == 0 || lockWaitMs > 5.0 ||
        ipcHoldMs > 5.0) {
        printf("[SCREEN-TL] seq=%u arrival=%llu gap=%.1fms bytes=%u "
               "decrypt=%.2fms pending=%u rcvWnd=%u srtt=%ums rtt=%ums "
               "tcpFlags=0x%x ipcWait=%.2fms ipcHold=%.2fms sent=%d\n",
               serviceSequence,
               (unsigned long long)serviceArrivalNanos,
               (double)arrivalGapMicros / 1000.0, length,
               (double)decryptMicros / 1000.0, tcpPendingBytes,
               tcpReceiveWindow, tcpSmoothedRTT, tcpCurrentRTT, tcpFlags,
               lockWaitMs, ipcHoldMs, success ? 1 : 0);
    }
    if (g_app_send_lock) dispatch_semaphore_signal(g_app_send_lock);
    return success;
}

/* ── HID report sender — sends touch events to iPhone via event channel ── */
#define MSG_TOUCH 0x03
static int g_event_cmd_cseq = 10;
static dispatch_queue_t g_hid_send_queue = NULL;

static void send_event_command(NSDictionary *cmd, const char *name,
                               const char *reason) {
    if (g_event_client_fd < 0 || !g_event_enc.active) {
        printf("[EVENT-CMD] %s unavailable (%s): fd=%d enc=%d\n",
               name, reason ?: "unspecified", g_event_client_fd,
               g_event_enc.active);
        return;
    }
    @autoreleasepool {
        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:cmd
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:nil];
        if (!plist) return;
        NSMutableString *header = [NSMutableString string];
        [header appendString:@"POST /command RTSP/1.0\r\n"];
        [header appendFormat:@"Content-Length: %lu\r\n",
                             (unsigned long)plist.length];
        [header appendString:
            @"Content-Type: application/x-apple-binary-plist\r\n"];
        int commandSequence = __sync_fetch_and_add(&g_event_cmd_cseq, 1);
        [header appendFormat:@"CSeq: %d\r\n", commandSequence];
        [header appendFormat:@"User-Agent: AirPlay/%s\r\n", SOURCE_VERSION];
        [header appendString:@"\r\n"];
        NSMutableData *message =
            [NSMutableData dataWithBytes:header.UTF8String
                                  length:strlen(header.UTF8String)];
        [message appendData:plist];

        if (g_event_send_lock)
            dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
        int result = enc_send_frame(g_event_client_fd, &g_event_enc,
                                    message.bytes, message.length);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
        printf("[EVENT-CMD] %s %s (%s, nonce=%llu)\n",
               name,
               result == 0 ? "sent" : "failed", reason ?: "unspecified",
               g_event_enc.writeNonce ? g_event_enc.writeNonce - 1 : 0);
    }
}

static void send_request_ui_command(const char *reason) {
    @autoreleasepool {
        send_event_command(@{ @"type": @"requestUI" }, "requestUI", reason);
    }
}

static void send_force_key_frame_command(const char *reason) {
    @autoreleasepool {
        send_event_command(@{ @"type": @"forceKeyFrame" },
                           "forceKeyFrame", reason);
    }
}

/* When Showcase leaves the foreground, its own UI becomes the active native
 * display. Tell the iPhone's CarPlay resource manager that the accessory is
 * taking MainScreen. requestUI returns the screen to CarPlay later and causes
 * a fresh screen stream/config/keyframe instead of trying to reconstruct an
 * arbitrarily long H.264 dependency chain. */
static void send_take_main_screen_command(const char *reason) {
    @autoreleasepool {
        NSDictionary *resource = @{
            @"resourceID": @(1),        /* MainScreen */
            @"transferType": @(1),      /* Take */
            @"transferPriority": @(500),/* UserInitiated */
            @"takeConstraint": @(100),  /* Anytime */
            @"borrowConstraint": @(100) /* Anytime */
        };
        NSDictionary *cmd = @{
            @"type": @"changeModes",
            @"params": @{ @"resources": @[resource] }
        };
        send_event_command(cmd, "changeModes(MainScreen=Take)", reason);
    }
}

#define HID_CONGESTED_MAX_PENDING 3
#define HID_HEALTHY_BURST_MAX_PENDING 12
#define HID_SEND_STALL_NANOS (50ULL * NSEC_PER_MSEC)
static volatile int32_t g_hid_pending_moves = 0;
static volatile int64_t g_hid_dropped_moves = 0;
static volatile uint64_t g_hid_oldest_pending_nanos = 0;
static volatile uint64_t g_hid_slow_send_count = 0;

static void send_hid_report(const uint8_t *report, size_t reportLen) {
    if (g_event_client_fd < 0 || !g_event_enc.active) return;

    @autoreleasepool {
        NSDictionary *cmd = @{
            @"type": @"hidSendReport",
            @"uuid": @"1",
            @"hidReport": [NSData dataWithBytes:report length:reportLen]
        };

        NSData *plist = [NSPropertyListSerialization
            dataWithPropertyList:cmd
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:nil];
        if (!plist) return;

        NSMutableString *hdrStr = [NSMutableString string];
        [hdrStr appendString:@"POST /command RTSP/1.0\r\n"];
        [hdrStr appendFormat:@"Content-Length: %lu\r\n", (unsigned long)plist.length];
        [hdrStr appendString:@"Content-Type: application/x-apple-binary-plist\r\n"];
        int commandSequence = __sync_fetch_and_add(&g_event_cmd_cseq, 1);
        [hdrStr appendFormat:@"CSeq: %d\r\n", commandSequence];
        [hdrStr appendString:@"\r\n"];

        NSMutableData *msg = [NSMutableData dataWithBytes:hdrStr.UTF8String
                                                   length:strlen(hdrStr.UTF8String)];
        [msg appendData:plist];

        uint64_t startedNanos = monotonic_nanos_now();
        if (g_event_send_lock)
            dispatch_semaphore_wait(
                g_event_send_lock, DISPATCH_TIME_FOREVER);
        uint64_t lockAcquiredNanos = monotonic_nanos_now();
        int result = enc_send_frame(
            g_event_client_fd, &g_event_enc, msg.bytes, msg.length);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
        uint64_t completedNanos = monotonic_nanos_now();
        uint64_t totalNanos = completedNanos - startedNanos;
        if (result != 0 || totalNanos >= 20 * NSEC_PER_MSEC) {
            uint64_t slowCount =
                __sync_add_and_fetch(&g_hid_slow_send_count, 1);
            if (slowCount <= 10 || (slowCount % 50) == 0) {
                printf("[TOUCH-WIRE] #%llu result=%d total=%.2fms "
                       "lock=%.2fms write=%.2fms pending=%d shed=%lld\n",
                       (unsigned long long)slowCount, result,
                       (double)totalNanos / 1000000.0,
                       (double)(lockAcquiredNanos - startedNanos) /
                           1000000.0,
                       (double)(completedNanos - lockAcquiredNanos) /
                           1000000.0,
                       (int)g_hid_pending_moves,
                       (long long)g_hid_dropped_moves);
            }
        }
    }
}

/* Down and up are never shed. UIKit may deliver several coalesced samples in
 * one IPC message, so queue depth by itself is not congestion: the previous
 * three-report admission cap discarded the end of healthy short swipes before
 * the event queue had a chance to run. Permit a bounded coalesced burst and
 * shed interior points only when the oldest queued write has made no progress
 * for 50 ms. */
static bool queue_touch_report(uint8_t phase, uint16_t x, uint16_t y,
                               uint8_t contact, uint64_t timestampNs) {
    if (!g_hid_send_queue) return false;
    /* Preserve the complete path. CarPlay derives gesture velocity from the
     * intermediate reports, so replacing moves with the newest point creates
     * sluggish or intermittently missed swipes even on a healthy transport.
     *
     * The event socket is blocking, so when the radio congests, enc_send_frame
     * stalls and moves pile up behind it. Releasing that backlog delivers a
     * dozen points to the iPhone within a few milliseconds; CarPlay times
     * touches on arrival, reads that as an enormous velocity, and flings the
     * map. Bounding the queue keeps the path intact while the transport is
     * healthy — the overwhelmingly common case — and sheds interior points only
     * while it is behind, which is exactly when a stale point is worthless. */
    bool isMove = (phase == 1);
    if (isMove) {
        uint64_t nowNanos = monotonic_nanos_now();
        int32_t pending = g_hid_pending_moves;
        uint64_t oldestNanos = g_hid_oldest_pending_nanos;
        bool sendStalled =
            pending >= HID_CONGESTED_MAX_PENDING &&
            oldestNanos != 0 &&
            nowNanos - oldestNanos >= HID_SEND_STALL_NANOS;
        if (pending >= HID_HEALTHY_BURST_MAX_PENDING || sendStalled) {
            __sync_fetch_and_add(&g_hid_dropped_moves, 1);
            return false;
        }
        int32_t newPending =
            __sync_add_and_fetch(&g_hid_pending_moves, 1);
        if (newPending == 1)
            __sync_lock_test_and_set(
                &g_hid_oldest_pending_nanos, nowNanos);
    }
    dispatch_async(g_hid_send_queue, ^{
        uint8_t report[5] = {
            phase == 3 ? 2 : (phase == 2 ? 0 : 1),
            (uint8_t)(x & 0xff),
            (uint8_t)(x >> 8),
            (uint8_t)(y & 0xff),
            (uint8_t)(y >> 8)
        };
        send_hid_report(report, sizeof(report));
        if (isMove) {
            int32_t remaining =
                __sync_sub_and_fetch(&g_hid_pending_moves, 1);
            __sync_lock_test_and_set(
                &g_hid_oldest_pending_nanos,
                remaining > 0 ? monotonic_nanos_now() : 0);
        }
        (void)contact;
        (void)timestampNs;
    });
    return true;
}

/* ── Touch reader thread — reads touch events from iPadPlay app via IPC ── */
static bool g_touch_reader_running = false;

static void touch_reader_func(void *arg) {
    int fd = (int)(intptr_t)arg;
    printf("[TOUCH] Reader started on fd=%d\n", fd);
    fflush(stdout);

    int touchCount = 0;
    uint64_t gestureCount = 0;
    uint64_t gestureStartSample = 0;
    uint64_t gestureStartHost = 0;
    uint16_t gestureStartX = 0, gestureStartY = 0;
    uint16_t gestureLastX = 0, gestureLastY = 0;
    double gesturePath = 0;
    uint32_t gestureMoves = 0;
    uint32_t gestureQueuedMoves = 0;
    int64_t gestureShedStart = 0;

    while (1) {
        /* Read IPC header: [4 byte len LE][1 byte type] */
        uint8_t hdr[5];
        if (!tcp_read_exact(fd, hdr, 5)) break;

        uint32_t len = hdr[0] | (hdr[1]<<8) | (hdr[2]<<16) | (hdr[3]<<24);
        uint8_t type = hdr[4];

        if (type == MSG_TOUCH && len > 0) {
            uint8_t *payload = malloc(len);
            if (!payload || !tcp_read_exact(fd, payload, len)) {
                free(payload);
                break;
            }

            if (len == 5) {
                /* Accept Beta 2 clients during package transition. */
                uint8_t phase = payload[0];
                uint16_t x = payload[1] | (payload[2] << 8);
                uint16_t y = payload[3] | (payload[4] << 8);
                queue_touch_report(phase, x, y, 0, 0);
                touchCount++;
            } else if ((len % 14) == 0) {
                for (uint32_t offset = 0; offset < len; offset += 14) {
                    uint8_t phase = payload[offset];
                    uint8_t contact = payload[offset + 1];
                    uint16_t x = payload[offset + 2] |
                                 (payload[offset + 3] << 8);
                    uint16_t y = payload[offset + 4] |
                                 (payload[offset + 5] << 8);
                    uint64_t timestampNs = 0;
                    memcpy(&timestampNs, payload + offset + 6,
                           sizeof(timestampNs));
                    uint64_t touchHostNanos = monotonic_nanos_now();
                    g_last_touch_nanos = touchHostNanos;
                    if (phase == 0) {
                        gestureCount++;
                        gestureStartSample = timestampNs;
                        gestureStartHost = touchHostNanos;
                        gestureStartX = gestureLastX = x;
                        gestureStartY = gestureLastY = y;
                        gesturePath = 0;
                        gestureMoves = 0;
                        gestureQueuedMoves = 0;
                        gestureShedStart = g_hid_dropped_moves;
                    } else if (phase == 1) {
                        double dx = (double)x - gestureLastX;
                        double dy = (double)y - gestureLastY;
                        gesturePath += hypot(dx, dy);
                        gestureLastX = x;
                        gestureLastY = y;
                        gestureMoves++;
                    }
                    bool queued = queue_touch_report(
                        phase, x, y, contact, timestampNs);
                    if (phase == 1 && queued) gestureQueuedMoves++;
                    touchCount++;
                    if (touchCount <= 3 || touchCount % 100 == 0) {
                        printf("[TOUCH] #%d: phase=%d contact=%u x=%u y=%u "
                               "sample=%llu → HID btn=%d pending=%d shed=%lld\n",
                               touchCount, phase, contact, x, y,
                               (unsigned long long)timestampNs,
                               phase == 2 ? 0 : 1,
                               (int)g_hid_pending_moves,
                               (long long)g_hid_dropped_moves);
                    }
                    if (phase == 2 || phase == 3) {
                        double dx = (double)x - gestureStartX;
                        double dy = (double)y - gestureStartY;
                        double displacement = hypot(dx, dy);
                        double durationMs =
                            timestampNs >= gestureStartSample &&
                            gestureStartSample != 0
                                ? (double)(timestampNs -
                                    gestureStartSample) / 1000000.0
                                : (double)(touchHostNanos -
                                    gestureStartHost) / 1000000.0;
                        int64_t shed =
                            g_hid_dropped_moves - gestureShedStart;
                        printf("[TOUCH-GESTURE] #%llu phase=%u "
                               "duration=%.1fms moves=%u queued=%u "
                               "shed=%lld displacement=%.1f path=%.1f "
                               "end=(%u,%u)\n",
                               (unsigned long long)gestureCount, phase,
                               durationMs, gestureMoves,
                               gestureQueuedMoves, (long long)shed,
                               displacement, gesturePath, x, y);
                    }
                }
            } else {
                printf("[TOUCH] ignored malformed payload len=%u\n", len);
            }
            free(payload);
            fflush(stdout);
        } else if (type == MSG_APP_VISIBILITY && len == 1) {
            uint8_t visible = 0;
            if (!tcp_read_exact(fd, &visible, 1)) break;
            g_app_video_enabled = visible != 0;
            printf("[SCREEN] Showcase is %s; video forwarding %s\n",
                   g_app_video_enabled ? "foreground" : "background",
                   g_app_video_enabled ? "resumed" : "paused");
            if (g_app_video_enabled) {
                send_request_ui_command("foreground resync");
            } else {
                send_take_main_screen_command("Showcase backgrounded");
            }
        } else if (type == MSG_VIDEO_RESYNC && len == 1) {
            uint8_t requested = 0;
            if (!tcp_read_exact(fd, &requested, 1)) break;
            if (requested) {
                printf("[SCREEN] Renderer requested a fresh screen stream\n");
                send_force_key_frame_command("decoder/stale-chain recovery");
            }
        } else if (type == MSG_AUDIO_RENDER && len == 20) {
            uint8_t payload[20];
            if (!tcp_read_exact(fd, payload, sizeof(payload))) break;
            uint32_t streamType = 0;
            int64_t sampleTime = 0;
            uint64_t hostTicks = 0;
            memcpy(&streamType, payload, 4);
            memcpy(&sampleTime, payload + 4, 8);
            memcpy(&hostTicks, payload + 12, 8);

            carplay_audio_stream_t *audio =
                audio_stream_for_type(streamType);
            if (audio) {
                uint64_t rawNanos = 0;
                uint64_t hostNTP =
                    synchronized_ntp_for_host_ticks(hostTicks, &rawNanos);
                pthread_mutex_lock(&g_audio_feedback_lock);
                audio->renderedSampleTime = sampleTime;
                audio->renderedHostNTP = hostNTP;
                audio->renderedHostRawNanos = rawNanos;
                audio->renderUpdateCount++;
                uint64_t updateCount = audio->renderUpdateCount;
                pthread_mutex_unlock(&g_audio_feedback_lock);
                if (updateCount <= 3 || (updateCount % 20) == 0) {
                    printf("[AUDIO] render stream=%u update=%llu "
                           "sample=%lld hostNTP=%llu rawNs=%llu\n",
                           streamType, (unsigned long long)updateCount,
                           (long long)sampleTime,
                           (unsigned long long)hostNTP,
                           (unsigned long long)rawNanos);
                }
            }
        } else {
            /* Skip unknown message type — read and discard payload */
            if (len > 0 && len < 65536) {
                uint8_t *discard = malloc(len);
                tcp_read_exact(fd, discard, len);
                free(discard);
            }
        }
    }

    printf("[TOUCH] Reader exiting (%d events processed)\n", touchCount);
    fflush(stdout);
    g_touch_reader_running = false;
}

static void start_touch_reader(int fd) {
    if (g_touch_reader_running) return;
    g_touch_reader_running = true;
    intptr_t fdArg = fd;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        touch_reader_func((void *)fdArg);
    });
}

static void *screen_thread_func(void *arg) {
    (void)arg;
    int listenFd = g_screen_listen_fd;
    printf("[SCREEN] Waiting for iPhone to connect on port %u (fd=%d)...\n",
           g_screen_data_port, listenFd);
    fflush(stdout);

    struct sockaddr_storage peer;
    socklen_t peerLen = sizeof(peer);
    int clientFd = accept(listenFd, (struct sockaddr *)&peer, &peerLen);
    if (clientFd < 0) {
        printf("[SCREEN] ERROR: accept failed: %s\n", strerror(errno));
        fflush(stdout);
        close(listenFd);
        if (g_screen_listen_fd == listenFd)
            g_screen_listen_fd = -1;
        __sync_lock_release(&g_screen_thread_running);
        return NULL;
    }
    close(listenFd);
    if (g_screen_listen_fd == listenFd)
        g_screen_listen_fd = -1;

    char peerIP[NI_MAXHOST] = {0};
    char peerPort[NI_MAXSERV] = {0};
    sockaddr_to_numeric((struct sockaddr *)&peer, peerLen,
                        peerIP, sizeof(peerIP), peerPort, sizeof(peerPort));
    printf("[SCREEN] *** Connected from %s:%s family=%s ***\n",
           peerIP, peerPort, addr_family_name(peer.ss_family));
    set_screen_socket_qos(clientFd, "accepted");

    /*
     * The iPhone encoder emits short bursts far above its average bitrate.
     * A shallow fixed window works on fast PCIe radios, but on older HSIC
     * receivers it propagates temporary radio loss back to the sender, where
     * the screen sink starts discarding frames. The app selects this window
     * from the runtime WLAN transport rather than jailbreak layout or a device
     * model table.
     */
    int requestedRcvBuf = g_screen_receive_buffer;
    int rcvBuf = requestedRcvBuf;
    if (setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF,
                   &requestedRcvBuf, sizeof(requestedRcvBuf)) != 0) {
        printf("[SCREEN] WARN: SO_RCVBUF request %d failed: %s\n",
               requestedRcvBuf, strerror(errno));
    }
    socklen_t rcvBufLength = sizeof(rcvBuf);
    if (getsockopt(clientFd, SOL_SOCKET, SO_RCVBUF,
                   &rcvBuf, &rcvBufLength) == 0) {
        printf("[SCREEN] TCP receive buffer: requested=%d actual=%d bytes\n",
               requestedRcvBuf, rcvBuf);
    }

    /*
     * Leave Darwin's stretch ACKs alone. On HSIC Wi-Fi the chip shares one
     * USB-class bus between transmit and receive; forcing an ACK every other
     * segment raised the iPad4,2's transmit/receive frame ratio from 0.34 to
     * 0.74 and its discarded-frame rate from 5% to 28%. Across three
     * recorded sessions, windows with transmit below half the receive rate
     * discarded 1-2% of frames and windows above it about 20%.
     */
    printf("[SCREEN] Key valid=%d, connID=%llu\n", g_screen_key_valid, g_screen_conn_id);
    fflush(stdout);

    /* ── Frame processing state ── */
    uint8_t header[128];
    uint8_t *body = NULL;
    size_t bodyAlloc = 0;
    uint64_t chachaNonce = 0;  /* 8-byte LE nonce, incremented per video frame */
    int videoFrameCount = 0;
    uint64_t totalBytes = 0;
    int msgCount = 0;
    double arrivalWindowStart = 0;
    double lastFrameArrival = 0;
    double maxFrameGap = 0;
    uint64_t arrivalWindowBytes = 0;
    unsigned int arrivalWindowFrames = 0;
    unsigned int gapsOver50ms = 0;
    unsigned int gapsOver100ms = 0;
    double lastStatsLogSeconds = 0;

    while (1) {
        /* Read 128-byte header */
        if (!screen_read_exact(clientFd, header, 128, "header")) {
            printf("[SCREEN] Connection closed (header read)\n");
            break;
        }

        uint32_t bodySize = header[0] | (header[1] << 8) | (header[2] << 8*2) | (header[3] << 8*3);
        uint8_t opcode = header[4];

        /* Ensure body buffer is big enough */
        if (bodySize > 0) {
            if (bodySize > bodyAlloc) {
                bodyAlloc = bodySize + 4096;
                body = realloc(body, bodyAlloc);
            }
            if (!screen_read_exact(clientFd, body, bodySize, "body")) {
                printf("[SCREEN] Connection closed (body read, expected %u)\n", bodySize);
                break;
            }
        }

        uint64_t messageArrivalNanos = monotonic_nanos_now();
        totalBytes += 128 + bodySize;
        msgCount++;

        switch (opcode) {
            case 1: { /* VideoConfig — SPS/PPS (AVCC), display dimensions */
                float width = *(float *)(header + 8 + 8);   /* params[1].f32[0] */
                float height = *(float *)(header + 8 + 12);  /* params[1].f32[1] */

                /* smallParam[1] carries the screen flags. Bit 1 is
                 * RespectTimestamps, bit 2 Encrypted — the latter is a useful
                 * cross-check because this stream is in fact encrypted. */
                uint8_t screenFlags = header[6];
                g_screen_respect_timestamps = (screenFlags & 0x02) ? 1 : 0;
                printf("[SCREEN] VideoConfig: %.0fx%.0f, AVCC=%u bytes, "
                       "flags=0x%02x (respectTimestamps=%u encrypted=%u)\n",
                       width, height, bodySize, screenFlags,
                       g_screen_respect_timestamps,
                       (screenFlags & 0x04) ? 1u : 0u);

                /* The renderer must learn the contract before the first frame
                 * that depends on it. */
                app_send_video_timing();

                /* Send config to iPadPlay app: [float width][float height][AVCC] */
                uint32_t msgLen = 8 + bodySize;
                uint8_t *msg = malloc(msgLen);
                memcpy(msg, &width, 4);
                memcpy(msg + 4, &height, 4);
                memcpy(msg + 8, body, bodySize);
                if (g_video_config_lock)
                    dispatch_semaphore_wait(g_video_config_lock,
                                            DISPATCH_TIME_FOREVER);
                free(g_latest_video_config);
                g_latest_video_config = malloc(msgLen);
                if (g_latest_video_config) {
                    memcpy(g_latest_video_config, msg, msgLen);
                    g_latest_video_config_length = msgLen;
                } else {
                    g_latest_video_config_length = 0;
                }
                if (g_video_config_lock)
                    dispatch_semaphore_signal(g_video_config_lock);
                bool sent = app_send_msg(MSG_VIDEO_CONFIG, msg, msgLen);
                free(msg);
                printf("[SCREEN] VideoConfig → app: %s\n", sent ? "OK" : "not connected");
                fflush(stdout);
                break;
            }

            case 0: { /* VideoFrame — encrypted H.264 data */
                videoFrameCount++;

                if (!g_screen_key_valid || bodySize < 16) {
                    if (videoFrameCount <= 3)
                        printf("[SCREEN] VideoFrame #%d: %u bytes (no key or too small)\n",
                               videoFrameCount, bodySize);
                    chachaNonce++;
                    break;
                }

                /* Decrypt with ChaCha20-Poly1305 (DJB 64x64 variant)
                 * Map to IETF 12-byte nonce: [4 zero bytes][8-byte LE nonce]
                 * AAD = 128-byte header, body = ciphertext + 16-byte tag */
                uint8_t ietfNonce[12];
                memset(ietfNonce, 0, 4);
                memcpy(ietfNonce + 4, &chachaNonce, 8);  /* LE nonce */

                uint32_t ctLen = bodySize - 16;  /* last 16 = poly1305 tag */

                crypto_aead_ctx ctx;
                crypto_aead_init_ietf(&ctx, g_screen_key, ietfNonce);
                int authResult = crypto_aead_read(
                    &ctx, body, body + ctLen, header, sizeof(header),
                    body, ctLen);
                crypto_wipe(&ctx, sizeof(ctx));
                int authOK = authResult == 0;

                if (videoFrameCount <= 3) {
                    printf("[SCREEN] VideoFrame #%d: %u bytes ct, decrypt=%s, nonce=%llu\n",
                           videoFrameCount, ctLen, authOK ? "OK" : "FAIL", chachaNonce);
                    if (ctLen >= 8) {
                        printf("[SCREEN] Decrypted hex: ");
                        int dl = ctLen > 32 ? 32 : ctLen;
                        for (int i = 0; i < dl; i++) printf("%02x ", body[i]);
                        printf("...\n");
                    }
                    fflush(stdout);
                }

                chachaNonce++;

                if (!authOK) break;

                uint64_t decryptDoneNanos = monotonic_nanos_now();
                uint64_t decryptNanos = decryptDoneNanos -
                    messageArrivalNanos;
                uint32_t decryptMicros = decryptNanos / 1000ULL > UINT32_MAX
                    ? UINT32_MAX : (uint32_t)(decryptNanos / 1000ULL);
                double arrivalSeconds =
                    (double)messageArrivalNanos / 1000000000.0;
                uint32_t arrivalGapMicros = 0;
                if (arrivalWindowStart == 0)
                    arrivalWindowStart = arrivalSeconds;
                if (lastFrameArrival > 0) {
                    double gap = arrivalSeconds - lastFrameArrival;
                    double gapMicros = gap * 1000000.0;
                    if (gapMicros > (double)UINT32_MAX)
                        arrivalGapMicros = UINT32_MAX;
                    else if (gapMicros > 0)
                        arrivalGapMicros = (uint32_t)gapMicros;
                    if (gap > maxFrameGap) maxFrameGap = gap;
                    if (gap > 0.050) gapsOver50ms++;
                    if (gap > 0.100) gapsOver100ms++;
                }
                lastFrameArrival = arrivalSeconds;
                arrivalWindowFrames++;
                arrivalWindowBytes += ctLen;

                /* packet[5] bit 0x10 marks an IDR frame in the AirPlay screen
                 * protocol. params[0] is the sender's 32.32 fixed-point
                 * presentation time on the session timeline; the renderer maps
                 * it into host time and schedules the frame there whenever
                 * RespectTimestamps is set. */
                uint64_t ntpTimestamp = 0;
                memcpy(&ntpTimestamp, header + 8, sizeof(ntpTimestamp));
                bool isIDR = (header[5] & 0x10) != 0 ||
                    h264_frame_contains_idr(body, ctLen);
                if (g_app_video_enabled) {
                    int pendingBytes = 0;
                    if (ioctl(clientFd, FIONREAD, &pendingBytes) != 0 ||
                        pendingBytes < 0)
                        pendingBytes = 0;

                    uint32_t receiveWindow = 0;
                    uint32_t smoothedRTT = 0;
                    uint32_t currentRTT = 0;
                    uint32_t tcpFlags = 0;
#ifdef TCP_CONNECTION_INFO
                    if (arrivalGapMicros > 50000 ||
                        videoFrameCount % 300 == 0) {
                        struct tcp_connection_info tcpInfo;
                        memset(&tcpInfo, 0, sizeof(tcpInfo));
                        socklen_t tcpInfoLength = sizeof(tcpInfo);
                        if (getsockopt(clientFd, IPPROTO_TCP,
                                       TCP_CONNECTION_INFO, &tcpInfo,
                                       &tcpInfoLength) == 0) {
                            receiveWindow = tcpInfo.tcpi_rcv_wnd;
                            smoothedRTT = tcpInfo.tcpi_srtt;
                            currentRTT = tcpInfo.tcpi_rttcur;
                            tcpFlags = tcpInfo.tcpi_flags;
                        }
                    }
#endif
                    app_send_video_frame(
                        ntpTimestamp, isIDR, body, ctLen,
                        (uint32_t)videoFrameCount, messageArrivalNanos,
                        arrivalGapMicros, (uint32_t)pendingBytes,
                        receiveWindow, smoothedRTT, currentRTT, tcpFlags,
                        decryptMicros);
                }

                double windowDuration = arrivalSeconds - arrivalWindowStart;
                if (windowDuration >= 5.0) {
                    double fps = arrivalWindowFrames / windowDuration;
                    double mbps = (arrivalWindowBytes * 8.0) /
                        (windowDuration * 1000000.0);
                    printf("[SCREEN] Live arrival: %.1f fps %.2f Mbps, "
                           "max gap %.1fms (>50=%u >100=%u), forwarding=%d\n",
                           fps, mbps, maxFrameGap * 1000.0,
                           gapsOver50ms, gapsOver100ms,
                           g_app_video_enabled ? 1 : 0);
                    arrivalWindowStart = arrivalSeconds;
                    arrivalWindowBytes = 0;
                    arrivalWindowFrames = 0;
                    maxFrameGap = 0;
                    gapsOver50ms = 0;
                    gapsOver100ms = 0;
                }
                break;
            }

            case 5: { /* KeepAliveWithBody — carries sender video statistics.
                       * The AccessorySDK ignores this opcode outright. Parsing
                       * the plist and printing the dictionary costs a copy, a
                       * deserialisation and ~17 line-buffered write() calls,
                       * and it used to happen on this thread once a second —
                       * long enough to stop draining the screen socket and turn
                       * the next frames into a late burst. Snapshot the bytes,
                       * hand them to a background queue, and sample rarely. */
                static dispatch_queue_t statsQueue;
                static dispatch_once_t statsOnce;
                dispatch_once(&statsOnce, ^{
                    statsQueue = dispatch_queue_create(
                        "com.reng.showcase.screenstats", DISPATCH_QUEUE_SERIAL);
                    dispatch_set_target_queue(statsQueue,
                        dispatch_get_global_queue(
                            DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
                });
                struct timespec statsNow;
                clock_gettime(CLOCK_MONOTONIC, &statsNow);
                double statsSeconds = (double)statsNow.tv_sec +
                    (double)statsNow.tv_nsec / 1000000000.0;
                if (statsSeconds - lastStatsLogSeconds >= 15.0 &&
                    bodySize > 0 && bodySize < 4u * 1024u * 1024u) {
                    lastStatsLogSeconds = statsSeconds;
                    size_t plistLength = bodySize;
                    if (plistLength > 25000) plistLength -= 25000;
                    NSData *snapshot = [NSData dataWithBytes:body
                                                      length:plistLength];
                    dispatch_async(statsQueue, ^{
                        @autoreleasepool {
                            id stats = [NSPropertyListSerialization
                                propertyListWithData:snapshot
                                             options:NSPropertyListImmutable
                                              format:NULL
                                               error:NULL];
                            if (stats)
                                printf("[SCREEN] Sender performance: %s\n",
                                       [[stats description] UTF8String]);
                        }
                    });
                }
                break;
            }
            case 2: /* KeepAlive */
            case 4: /* Ignore (bandwidth measurement) */
                break;

            default:
                if (msgCount <= 10)
                    printf("[SCREEN] Unknown opcode %d, body=%u\n", opcode, bodySize);
                break;
        }

        if (msgCount % 500 == 0) {
            printf("[SCREEN] %d msgs, %d video frames, %llu bytes total\n",
                   msgCount, videoFrameCount, totalBytes);
            fflush(stdout);
        }
    }

    printf("[SCREEN] Thread exit: %d msgs, %d video frames, %llu bytes\n",
           msgCount, videoFrameCount, totalBytes);
    fflush(stdout);
    free(body);
    close(clientFd);
    __sync_lock_release(&g_screen_thread_running);
    return NULL;
}

static void start_screen_thread(void) {
    if (g_screen_listen_fd < 0) return;
    if (!__sync_bool_compare_and_swap(&g_screen_thread_running, 0, 1)) {
        /* A replacement SETUP can arrive while the old stream thread is
         * finishing its socket cleanup. Retry off the RTSP thread so the
         * SETUP response is never delayed. */
        if (__sync_bool_compare_and_swap(&g_screen_start_pending, 0, 1)) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                while (g_screen_thread_running)
                    usleep(20000);
                __sync_lock_release(&g_screen_start_pending);
                start_screen_thread();
            });
        }
        return;
    }
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        screen_thread_func(NULL);
    });
}

static ssize_t send_timing_request(int fd,
                                   const struct sockaddr *destination,
                                   socklen_t destinationLength) {
    uint8_t packet[32] = {0};
    packet[0] = 0x80;
    packet[1] = 0xD2;
    packet[2] = 0x00;
    packet[3] = 0x07;

    uint32_t seconds = 0;
    uint32_t fraction = 0;
    get_ntp_time(&seconds, &fraction);
    packet[24] = (seconds >> 24) & 0xFF;
    packet[25] = (seconds >> 16) & 0xFF;
    packet[26] = (seconds >> 8) & 0xFF;
    packet[27] = seconds & 0xFF;
    packet[28] = (fraction >> 24) & 0xFF;
    packet[29] = (fraction >> 16) & 0xFF;
    packet[30] = (fraction >> 8) & 0xFF;
    packet[31] = fraction & 0xFF;
    return sendto(fd, packet, sizeof(packet), 0,
                  destination, destinationLength);
}

/* ═══════════════════════════════════════════════════════════════
 * Timing Negotiation — server-initiated NTP sync
 *
 * The reference implementation (AirPlayReceiverSession.c) calls
 * _TimingNegotiate() from AirPlayReceiverSessionStart() (RECORD).
 * The SERVER sends NTP requests to the CLIENT's timing port.
 * The client responds, and we compute clock offset.
 *
 * We send from our timing socket (g_timing_fd) so responses
 * come back to our timing responder thread.
 * ═══════════════════════════════════════════════════════════════ */

/* Blocking timing negotiation — sends NTP requests and waits for responses.
 * The reference (AirPlayReceiverSession.c _TimingNegotiate) blocks until
 * at least 3 successful NTP roundtrips complete. The RECORD 200 OK must
 * NOT be sent until timing is synchronized. */
static bool timing_negotiate_blocking(void) {
    if (g_iphone_timing_port == 0 || g_iphone_ip[0] == '\0' || g_timing_fd < 0) {
        printf("[TIMING-NEG] Cannot negotiate — no iPhone timing port/IP/fd\n");
        return false;
    }

    printf("[TIMING-NEG] Starting BLOCKING negotiation -> %s:%u\n",
           g_iphone_ip, g_iphone_timing_port);
    fflush(stdout);

    struct sockaddr_storage dest;
    socklen_t destLen = 0;
    char destDisplay[NI_MAXHOST + IF_NAMESIZE + 4];
    memset(destDisplay, 0, sizeof(destDisplay));
    int timingFamily = socket_bound_family(g_timing_fd);
    if (!build_peer_sockaddr(g_iphone_ip, g_iphone_timing_port,
                             timingFamily,
                             &dest, &destLen,
                             destDisplay, sizeof(destDisplay))) {
        printf("[TIMING] WARN: could not parse timing destination %s; waiting for client timing packets\n",
               g_iphone_ip);
        return false;
    }
    printf("[TIMING] negotiate socket=%s destination=%s %s port=%u\n",
           addr_family_name(timingFamily), addr_family_name(dest.ss_family),
           destDisplay, g_iphone_timing_port);

    g_timing_sync_count = 0;
    g_timing_best_rtt = DBL_MAX;
    g_timing_remote_minus_local = 0.0;
    g_timing_offset_valid = 0;
    app_send_video_timing();

    /* Send 5 NTP requests with 100ms spacing, then wait for responses */
    for (int i = 0; i < 5; i++) {
        ssize_t sent = send_timing_request(
            g_timing_fd, (struct sockaddr *)&dest, destLen);
        if (sent < 0) {
            printf("[TIMING] WARN: sendto failed for %s errno=%d (%s); waiting for client timing packets\n",
                   destDisplay, errno, strerror(errno));
        } else {
            printf("[TIMING-NEG] Sent NTP request %d/5 (%zd bytes)\n", i + 1, sent);
        }
        fflush(stdout);

        /* Wait 100ms between requests */
        usleep(100000);
    }

    /* Wait up to 2 seconds for at least 3 responses
     * (responses are counted by the timing responder thread) */
    int waitMs = 0;
    while (g_timing_sync_count < 3 && waitMs < 2000) {
        usleep(50000);  /* 50ms poll */
        waitMs += 50;
    }

    printf("[TIMING-NEG] Negotiation complete: %d responses in %dms\n",
           g_timing_sync_count, waitMs);
    fflush(stdout);

    /*
     * CarPlaySDK continues probing roughly every 2–3 seconds for the lifetime
     * of a session. Keep one generation alive so resume/re-RECORD replaces the
     * old destination without accumulating maintenance loops.
     */
    uint32_t generation =
        __sync_add_and_fetch(&g_timing_maintenance_generation, 1);
    struct sockaddr_storage maintenanceDestination = dest;
    socklen_t maintenanceLength = destLen;
    int maintenanceFd = g_timing_fd;
    dispatch_async(dispatch_get_global_queue(
                       DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (generation == g_timing_maintenance_generation &&
               maintenanceFd == g_timing_fd && maintenanceFd >= 0) {
            usleep(2500000);
            if (generation != g_timing_maintenance_generation) break;
            ssize_t sent = send_timing_request(
                maintenanceFd,
                (struct sockaddr *)&maintenanceDestination,
                maintenanceLength);
            if (sent < 0 && errno != EINTR)
                printf("[TIMING] maintenance request failed: %s\n",
                       strerror(errno));
        }
    });

    return (g_timing_sync_count >= 3);
}

static void handle_rtsp_setup(int sock, const HTTPReq *r) {
    printf("[AP] -> SETUP %s (CSeq=%d, bodyLen=%zu)\n",
           r->path, r->cseq, r->bodyLen);

    NSDictionary *reqDict = nil;
    if (r->body && r->bodyLen > 0) {
        @autoreleasepool {
            NSData *d = [NSData dataWithBytesNoCopy:(void *)r->body
                                             length:r->bodyLen
                                       freeWhenDone:NO];
            id obj = [NSPropertyListSerialization
                propertyListWithData:d options:0 format:NULL error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                reqDict = (NSDictionary *)obj;
                printf("[AP] SETUP plist: %s\n",
                       [[obj description] UTF8String]);
            }
        }
    }

    @autoreleasepool {
        NSMutableDictionary *respDict = [NSMutableDictionary dictionary];
        NSArray *streams = reqDict[@"streams"];

        if (!streams) {
            /* ── Phase 1: Initial session control setup ── */
            printf("[AP] SETUP: initial session setup (no streams)\n");

            /* Extract iPhone's timing port from request */
            NSNumber *iphoneTimingPort = reqDict[@"timingPort"];
            if (iphoneTimingPort) {
                g_iphone_timing_port = [iphoneTimingPort unsignedShortValue];
                printf("[AP] iPhone's timing port: %u\n", g_iphone_timing_port);
            }

            /* Extract iPhone's IP from socket peer address */
            g_rtsp_sock = sock;
            struct sockaddr_storage peerAddr;
            socklen_t peerLen = sizeof(peerAddr);
            if (getpeername(sock, (struct sockaddr *)&peerAddr, &peerLen) == 0) {
                char host[NI_MAXHOST] = {0};
                char serv[NI_MAXSERV] = {0};
                sockaddr_to_numeric((struct sockaddr *)&peerAddr, peerLen,
                                    host, sizeof(host), serv, sizeof(serv));
                /* Strip ::ffff: prefix for IPv4-mapped IPv6 */
                const char *ip = host;
                g_iphone_family = peerAddr.ss_family;
                if (peerAddr.ss_family == AF_INET6) {
                    const struct sockaddr_in6 *peer6 =
                        (const struct sockaddr_in6 *)&peerAddr;
                    if (IN6_IS_ADDR_V4MAPPED(&peer6->sin6_addr)) {
                        ip += strncmp(ip, "::ffff:", 7) == 0 ? 7 : 0;
                        g_iphone_family = AF_INET;
                    }
                }
                snprintf(g_iphone_ip, sizeof(g_iphone_ip), "%s", ip);
                printf("[AP] iPhone IP: %s (socketFamily=%s "
                       "screenFamily=%s peer_port=%s)\n",
                       g_iphone_ip, addr_family_name(peerAddr.ss_family),
                       addr_family_name(g_iphone_family), serv);
            }

            /* Allocate control ports if not already done */
            if (!g_session_active) {
                if (g_timing_fd < 0)
                    g_timing_fd = bind_udp_port(&g_timing_port);
                if (g_event_fd < 0)
                    g_event_fd = bind_tcp_port(&g_event_port);
                if (g_keepalive_fd < 0)
                    g_keepalive_fd = bind_udp_port(&g_keepalive_port);
                g_session_active = true;

                /* Start background threads for timing, event, keepalive */
                start_timing_thread();
                start_event_thread();
                start_keepalive_thread();
            }

            respDict[@"timingPort"] = @(g_timing_port);
            respDict[@"eventPort"]  = @(g_event_port);

            /*
             * Session features are negotiated, not enabled merely by listing
             * their stream formats in /info. Enable only the buffered-audio
             * feature that both peers advertised/support; do not mirror
             * unknown sender features.
             */
            NSArray *requestedFeatures = reqDict[@"features"];
            if (g_receiver_audio &&
                [requestedFeatures isKindOfClass:[NSArray class]] &&
                [requestedFeatures containsObject:@"mainBuffered"]) {
                respDict[@"enabledFeatures"] = @[@"mainBuffered"];
                printf("[AUDIO] enabled session feature: mainBuffered\n");
            }

            /* iPhone sent keepAliveLowPower=1 */
            if ([reqDict[@"keepAliveLowPower"] boolValue]) {
                respDict[@"keepAlivePort"] = @(g_keepalive_port);
            }

            printf("[AP] SETUP response: timingPort=%u eventPort=%u keepAlivePort=%u (dual-stack when available)\n",
                   g_timing_port, g_event_port, g_keepalive_port);
            app_send_status(STATUS_SESSION_SETUP);

        } else {
            /* ── Phase 2: Stream setup ── */
            printf("[AP] SETUP: stream setup (%lu streams)\n", (unsigned long)[streams count]);

            NSMutableArray *respStreams = [NSMutableArray array];

            for (NSDictionary *stream in streams) {
                NSNumber *typeNum = stream[@"type"];
                int type = [typeNum intValue];
                printf("[AP] SETUP stream type=%d\n", type);

                NSMutableDictionary *rs = [NSMutableDictionary dictionary];
                rs[@"type"] = typeNum;

                uint16_t dataPort = 0;
                int dataFd = -1;

                /* Screen is H.264/TCP. CarPlay audio types 100/101/102 are
                 * encrypted RTP/UDP and are handled by dedicated receivers. */
                if (type == 110) {
                    dataFd = bind_screen_tcp_port(&dataPort, g_iphone_family);
                    printf("[NET] screen/video dataPort=%u fd=%d family=%s\n",
                           dataPort, dataFd,
                           addr_family_name(socket_bound_family(dataFd)));

                    NSNumber *latency = stream[@"latencyMs"];
                    if (latency) {
                        uint32_t requestedLatency =
                            (uint32_t)[latency unsignedIntValue];
                        if (requestedLatency >= 20 &&
                            requestedLatency <= 500) {
                            g_screen_latency_ms = requestedLatency;
                        }
                    }
                    printf("[AP] Screen target latency: %u ms\n",
                           g_screen_latency_ms);
                    app_send_video_timing();

                    /* Save screen stream state for screen thread */
                    g_screen_listen_fd = dataFd;
                    g_screen_data_port = dataPort;

                    /* Get streamConnectionID for key derivation */
                    NSNumber *connID = stream[@"streamConnectionID"];
                    if (connID) {
                        g_screen_conn_id = [connID unsignedLongLongValue];
                        printf("[AP] Screen streamConnectionID: %llu\n", g_screen_conn_id);

                        /* Derive ChaCha20-Poly1305 key via pair context */
                        if (pair_derive_stream_key(g_pair, g_screen_conn_id, g_screen_key) == 0) {
                            g_screen_key_valid = true;
                            printf("[AP] Screen decryption key ready\n");
                        }
                    }

                    /* Start screen receiver thread */
                    start_screen_thread();
                    app_send_status(STATUS_STREAM_SETUP);
                } else if (type == 100 || type == 101 ||
                           type == 102 || type == 103) {
                    printf("[AUDIO] SETUP requested type=%d (%s)\n", type,
                           type == 103 ? "MainBuffered" :
                           type == 102 ? "MainHigh" :
                           type == 101 ? "Alt" : "Main");
                    /* Apple's MainBuffered receiver opens a TCP server. Its
                     * SETUP response also advertises the 8 MiB buffer used for
                     * the prefetched media stream. Types 100-102 remain UDP. */
                    bool bufferedTCP = type == 103;
                    carplay_audio_stream_t *audio =
                        audio_stream_for_type((uint32_t)type);
                    if (audio) {
                        stop_audio_receiver(
                            audio, "replaced by a new SETUP");
                    }
                    dataFd = bufferedTCP
                        ? bind_tcp_port(&dataPort)
                        : bind_udp_port(&dataPort);
                    if (audio && dataFd >= 0) {
                        audio->dataFd = dataFd;
                        audio->dataPort = dataPort;
                        audio->usesTCP = bufferedTCP;
                        audio->packetCount = 0;
                        audio->decryptErrors = 0;
                        audio->sequenceGaps = 0;
                        audio->lastArrivalNanos = 0;
                        audio->maxArrivalGapNanos = 0;
                        audio->longArrivalGaps = 0;
                        audio->haveSequence = false;
                        pthread_mutex_lock(&g_audio_control_lock);
                        audio->flushPending = false;
                        audio->flushUntilSequence = 0;
                        audio->flushUntilTimestamp = 0;
                        audio->flushDropCount = 0;
                        pthread_mutex_unlock(&g_audio_control_lock);
                        pthread_mutex_lock(&g_audio_feedback_lock);
                        audio->renderedSampleTime = 0;
                        audio->renderedHostNTP = 0;
                        audio->renderedHostRawNanos = 0;
                        audio->renderUpdateCount = 0;
                        pthread_mutex_unlock(&g_audio_feedback_lock);

                        NSNumber *connectionID =
                            stream[@"streamConnectionID"];
                        audio->connectionID = connectionID
                            ? connectionID.unsignedLongLongValue : 0;
                        NSNumber *format = stream[@"audioFormat"];
                        if (format) {
                            audio->formatMask =
                                format.unsignedLongLongValue;
                        } else {
                            /* SDK fallback: uncompressed stereo output. */
                            audio->formatMask = 0x00008000ULL;
                        }
                        NSNumber *samplesPerFrame = stream[@"spf"];
                        audio->framesPerPacket = samplesPerFrame
                            ? samplesPerFrame.unsignedIntValue
                            : audio_default_frames_per_packet(
                                  audio->formatMask);
                        NSNumber *audioLatency = stream[@"audioLatencyMs"];
                        audio->latencyMs = audioLatency
                            ? audioLatency.unsignedIntValue : 100;
                        /* MainBuffered carries its own 32-byte key in the
                         * SETUP body ("shk") rather than having one derived
                         * from the stream connection ID, which is how the
                         * screen and the low-latency audio types work. Observed
                         * directly in Apple's receiver log. */
                        audio->keyValid = false;
                        NSData *sharedKey = stream[@"shk"];
                        if ([sharedKey isKindOfClass:[NSData class]] &&
                            sharedKey.length == sizeof(audio->key)) {
                            memcpy(audio->key, sharedKey.bytes,
                                   sizeof(audio->key));
                            audio->keyValid = true;
                            printf("[AUDIO] stream=%d key supplied in SETUP "
                                   "(shk, %u bytes)\n", type,
                                   (unsigned)sharedKey.length);
                        } else if (audio->connectionID &&
                                   pair_derive_stream_key(
                                       g_pair, audio->connectionID,
                                       audio->key) == 0) {
                            audio->keyValid = true;
                            printf("[AUDIO] stream=%d key derived from "
                                   "connID\n", type);
                        }

                        /* Recorded for the renderer and for diagnosis: the
                         * compression type and mode select the decoder, and
                         * clientID identifies which app is playing. */
                        NSNumber *compression = stream[@"ct"];
                        NSString *audioMode = stream[@"audioMode"];
                        NSString *audioTypeStr = stream[@"audioType"];
                        NSString *clientID = stream[@"clientID"];
                        printf("[AUDIO] stream=%d ct=%s mode=%s audioType=%s "
                               "client=%s formatIndex=%s\n", type,
                               compression ? compression.stringValue.UTF8String : "-",
                               audioMode ? audioMode.UTF8String : "-",
                               audioTypeStr ? audioTypeStr.UTF8String : "-",
                               clientID ? clientID.UTF8String : "-",
                               stream[@"audioFormatIndex"]
                                   ? [stream[@"audioFormatIndex"] stringValue].UTF8String
                                   : "-");
                        if (audio->connectionID)
                            rs[@"streamConnectionID"] =
                                @(audio->connectionID);

                        /* MainHigh uses a companion RTCP port. MainBuffered
                         * carries its records over TCP and has no controlPort
                         * in Apple's SETUP response. */
                        if (type == 102) {
                            uint16_t controlPort = 0;
                            int controlFd =
                                bind_udp_port(&controlPort);
                            audio->controlFd = controlFd;
                            audio->controlPort = controlPort;
                            if (controlFd >= 0)
                                rs[@"controlPort"] = @(controlPort);
                        }
                        if (type == 103)
                            rs[@"audioBufferSize"] = @(8 * 1024 * 1024);
                        printf("[NET] audio stream=%d %s dataPort=%u fd=%d "
                               "controlPort=%u format=0x%llx spf=%u "
                               "latency=%ums connID=%llu key=%d\n",
                               type, bufferedTCP ? "TCP" : "UDP",
                               dataPort, dataFd,
                               audio->controlPort,
                               (unsigned long long)audio->formatMask,
                               audio->framesPerPacket, audio->latencyMs,
                               (unsigned long long)audio->connectionID,
                               audio->keyValid ? 1 : 0);
                        start_audio_receiver(audio);
                    }
                } else {
                    dataFd = bind_udp_port(&dataPort);
                    printf("[NET] auxiliary stream=%d UDP dataPort=%u fd=%d\n",
                           type, dataPort, dataFd);
                }
                rs[@"dataPort"] = @(dataPort);

                /* Unknown auxiliary streams retain the legacy control port.
                 * Known audio streams above use the per-type SDK contract. */
                if (type != 110 && type != 100 && type != 101 &&
                    type != 102 && type != 103) {
                    uint16_t ctrlPort = 0;
                    int ctrlFd = bind_udp_port(&ctrlPort);
                    rs[@"controlPort"] = @(ctrlPort);
                    /* Keep control fd alive — just log for now */
                    if (ctrlFd >= 0) {
                        printf("[AP] SETUP stream type=%d controlPort=%u (fd=%d, kept open, dual-stack when available)\n",
                               type, ctrlPort, ctrlFd);
                    }
                }

                printf("[AP] SETUP stream type=%d → dataPort=%u (fd=%d, kept open)\n",
                       type, dataPort, dataFd);
                [respStreams addObject:rs];
                /* DO NOT close dataFd — iPhone will connect/send data to it */
            }

            respDict[@"streams"] = respStreams;
        }

        /* Serialize response plist */
        NSError *err = nil;
        NSData *plistData = [NSPropertyListSerialization
            dataWithPropertyList:respDict
            format:NSPropertyListBinaryFormat_v1_0
            options:0 error:&err];

        if (plistData) {
            printf("[AP] SETUP response plist (%zu bytes): %s\n",
                   plistData.length, [[respDict description] UTF8String]);
            send_response(sock, "RTSP/1.0", 200, "OK",
                         "application/x-apple-binary-plist",
                         (const uint8_t *)plistData.bytes, plistData.length, r->cseq);
        } else {
            printf("[AP] SETUP plist serialization error: %s\n",
                   [[err description] UTF8String]);
            send_response(sock, "RTSP/1.0", 500, "Internal Server Error",
                         NULL, NULL, 0, r->cseq);
        }
    }
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: RTSP RECORD / TEARDOWN / FLUSH / other
 * ═══════════════════════════════════════════════════════════════ */

static bool g_recording = false;

static void handle_record(int sock, const HTTPReq *r) {
    printf("[AP] -> RECORD (CSeq=%d)\n", r->cseq);

    if (!g_session_active) {
        printf("[AP] RECORD received before SETUP — rejecting\n");
        send_response(sock, "RTSP/1.0", 403, "Forbidden",
                     NULL, NULL, 0, r->cseq);
        return;
    }

    g_recording = true;

    /* Ensure background threads are running */
    start_timing_thread();
    start_event_thread();
    start_keepalive_thread();

    printf("[AP] RECORD: Starting session — timing negotiation first...\n");
    fflush(stdout);

    /* ── CRITICAL: Timing negotiation MUST complete BEFORE sending 200 OK ──
     * The reference (AirPlayReceiverSession.c) calls AirPlayReceiverSessionStart()
     * which blocks on _TimingNegotiate() before returning. The iPhone expects
     * timing to be synchronized by the time it receives RECORD 200 OK.
     * If we send 200 OK before timing is done, iPhone tears down immediately. */
    bool timingOK = timing_negotiate_blocking();

    printf("[AP] ╔══════════════════════════════════════╗\n");
    printf("[AP] ║  RECORD — Session is LIVE            ║\n");
    printf("[AP] ║  Timing:%u Event:%u KeepAlive:%u     ║\n",
           g_timing_port, g_event_port, g_keepalive_port);
    printf("[AP] ║  iPhone timing port: %u              ║\n",
           g_iphone_timing_port);
    printf("[AP] ║  Timing sync: %s (%d responses)    ║\n",
           timingOK ? "YES" : "NO", g_timing_sync_count);
    printf("[AP] ╚══════════════════════════════════════╝\n");
    fflush(stdout);

    send_response(sock, "RTSP/1.0", 200, "OK", NULL, NULL, 0, r->cseq);

    /* Ask the phone for the first UI frame. The same command is reused after
     * foregrounding so the decoder can restart from a clean keyframe. */
    send_request_ui_command("record started");
}

static void handle_teardown(int sock, const HTTPReq *r) {
    printf("[AP] -> TEARDOWN (CSeq=%d, bodyLen=%zu)\n", r->cseq, r->bodyLen);

    bool hadStreamTargets = false;
    if (r->body && r->bodyLen > 0) {
        @autoreleasepool {
            NSData *d = [NSData dataWithBytesNoCopy:(void *)r->body
                                             length:r->bodyLen
                                       freeWhenDone:NO];
            id obj = [NSPropertyListSerialization
                propertyListWithData:d options:0 format:NULL error:NULL];
            if (obj) {
                printf("[AP] TEARDOWN plist: %s\n",
                       [[obj description] UTF8String]);
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSArray *streams = obj[@"streams"];
                    if ([streams isKindOfClass:[NSArray class]] &&
                        streams.count > 0) {
                        hadStreamTargets = true;
                        for (id entry in streams) {
                            if (![entry isKindOfClass:
                                    [NSDictionary class]]) continue;
                            NSNumber *type = entry[@"type"];
                            carplay_audio_stream_t *audio =
                                audio_stream_for_type(
                                    type.unsignedIntValue);
                            if (audio)
                                stop_audio_receiver(
                                    audio, "sender stream TEARDOWN");
                        }
                    }
                }
            } else {
                printf("[AP] TEARDOWN hex (%zu):", r->bodyLen);
                size_t n = r->bodyLen > 256 ? 256 : r->bodyLen;
                for (size_t i = 0; i < n; i++) printf(" %02X", r->body[i]);
                printf("\n");
            }
        }
    }

    if (!hadStreamTargets) {
        g_recording = false;
        __sync_add_and_fetch(&g_timing_maintenance_generation, 1);
        for (size_t index = 0;
             index < sizeof(g_audio_streams) /
                     sizeof(g_audio_streams[0]);
             index++) {
            stop_audio_receiver(
                &g_audio_streams[index], "full session TEARDOWN");
        }
    }

    send_response(sock, "RTSP/1.0", 200, "OK", NULL, NULL, 0, r->cseq);
    printf("[AP] %s torn down.\n",
           hadStreamTargets ? "Requested stream(s)" : "Session");
    fflush(stdout);
}

static void handle_setrate(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            NSData *data = [NSData dataWithBytesNoCopy:(void *)r->body
                                                length:r->bodyLen
                                          freeWhenDone:NO];
            id object = [NSPropertyListSerialization
                propertyListWithData:data options:0 format:NULL error:NULL];
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *rtpTime = request[@"rtpTime"];
        NSNumber *rate = request[@"rate"];
        if (!rtpTime || !rate) {
            printf("[AUDIO] SETRATE missing rtpTime/rate\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        /*
         * MainBuffered uses SETRATE as its playback anchor. Apple's receiver
         * returns the requested RTP position together with the accessory's
         * current synchronized network time, then applies that same anchor
         * locally. The network-time seconds in this plist omit the NTP epoch
         * bias used on the UDP timing wire.
         */
        uint64_t synchronizedNTP =
            synchronized_ntp_for_host_ticks(mach_absolute_time(), NULL);
        uint32_t ntpSeconds = (uint32_t)(synchronizedNTP >> 32);
        uint32_t ntpFraction = (uint32_t)synchronizedNTP;
        uint32_t networkSeconds = ntpSeconds - NTP_EPOCH_OFFSET;
        NSDictionary *response = @{
            @"networkTimeFlags": @0,
            @"networkTimeTimelineID": @0,
            @"networkTimeSecs": @(networkSeconds),
            @"networkTimeFrac": @(ntpFraction),
            @"rtpTime": rtpTime,
            @"rate": rate
        };
        NSData *body = [NSPropertyListSerialization
            dataWithPropertyList:response
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:NULL];
        printf("[AUDIO] SETRATE rate=%s rtpTime=%s anchor=%u.%u\n",
               rate.stringValue.UTF8String,
               rtpTime.stringValue.UTF8String,
               networkSeconds, ntpFraction);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      "application/x-apple-binary-plist",
                      body.bytes, body.length, r->cseq);
        app_send_audio_control(103, rate.doubleValue == 0.0
                                    ? AUDIO_CONTROL_PAUSE
                                    : AUDIO_CONTROL_RESUME);
    }
}

static void handle_setrate_anchor_time(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            NSData *data = [NSData dataWithBytesNoCopy:(void *)r->body
                                                length:r->bodyLen
                                          freeWhenDone:NO];
            id object = [NSPropertyListSerialization
                propertyListWithData:data options:0 format:NULL error:NULL];
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *rate = request[@"rate"];
        if (!rate) {
            printf("[AUDIO] SETRATEANCHORTIME missing rate\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        bool paused = rate.doubleValue == 0.0;
        printf("[AUDIO] SETRATEANCHORTIME rate=%s -> %s\n",
               rate.stringValue.UTF8String,
               paused ? "pause" : "resume");
        app_send_audio_control(103, paused
                                    ? AUDIO_CONTROL_PAUSE
                                    : AUDIO_CONTROL_RESUME);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      NULL, NULL, 0, r->cseq);
    }
}

static void handle_flush_buffered(int sock, const HTTPReq *r) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (r->body && r->bodyLen > 0) {
            NSData *data = [NSData dataWithBytesNoCopy:(void *)r->body
                                                length:r->bodyLen
                                          freeWhenDone:NO];
            id object = [NSPropertyListSerialization
                propertyListWithData:data options:0 format:NULL error:NULL];
            if ([object isKindOfClass:[NSDictionary class]])
                request = object;
        }

        NSNumber *flushUntilSeq = request[@"flushUntilSeq"];
        NSNumber *flushUntilTS = request[@"flushUntilTS"];
        if (!flushUntilSeq || !flushUntilTS) {
            printf("[AUDIO] FLUSHBUFFERED missing sequence/timestamp\n");
            send_response(sock, "RTSP/1.0", 400, "Bad Request",
                          NULL, NULL, 0, r->cseq);
            return;
        }

        carplay_audio_stream_t *audio = audio_stream_for_type(103);
        uint64_t extendedSequence =
            flushUntilSeq.unsignedLongLongValue;
        uint32_t timestamp = flushUntilTS.unsignedIntValue;
        if (audio) {
            pthread_mutex_lock(&g_audio_control_lock);
            audio->flushPending = true;
            audio->flushUntilSequence =
                (uint16_t)(extendedSequence & 0xffff);
            audio->flushUntilTimestamp = timestamp;
            audio->flushDropCount = 0;
            pthread_mutex_unlock(&g_audio_control_lock);

            /* Old render coordinates no longer describe the media epoch. */
            pthread_mutex_lock(&g_audio_feedback_lock);
            audio->renderedSampleTime = 0;
            audio->renderedHostNTP = 0;
            audio->renderedHostRawNanos = 0;
            audio->renderUpdateCount = 0;
            pthread_mutex_unlock(&g_audio_feedback_lock);
        }

        printf("[AUDIO] FLUSHBUFFERED untilSeq=%llu (rtp=%u) "
               "untilTS=%u\n",
               (unsigned long long)extendedSequence,
               (unsigned)(extendedSequence & 0xffff), timestamp);
        app_send_audio_control(103, AUDIO_CONTROL_FLUSH);
        send_response(sock, "RTSP/1.0", 200, "OK",
                      NULL, NULL, 0, r->cseq);
    }
}

static void handle_rtsp_generic(int sock, const HTTPReq *r) {
    printf("[AP] -> %s %s (CSeq=%d, bodyLen=%zu)\n",
           r->method, r->path, r->cseq, r->bodyLen);

    if (r->body && r->bodyLen > 0) {
        printf("[AP] body hex (%zu):", r->bodyLen);
        size_t dumpLen = r->bodyLen > 256 ? 256 : r->bodyLen;
        for (size_t i = 0; i < dumpLen; i++) printf(" %02X", r->body[i]);
        printf("\n");
    }

    const char *proto = strncmp(r->protocol, "RTSP", 4) == 0 ?
                        "RTSP/1.0" : "HTTP/1.1";
    send_response(sock, proto, 200, "OK", NULL, NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * Endpoint: POST /command, /feedback
 * ═══════════════════════════════════════════════════════════════ */

static NSDictionary *g_modes_state = nil;


static void handle_command_dictionary(NSDictionary *command) {
    NSString *type = command[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;

    if ([type isEqualToString:@"modesChanged"]) {
        NSDictionary *params = command[@"params"];
        if ([params isKindOfClass:[NSDictionary class]]) {
            g_modes_state = [params copy];
            printf("[CONTROL] modesChanged state updated: %s\n",
                   g_modes_state.description.UTF8String);
        }
    } else if ([type isEqualToString:@"disableBluetooth"]) {
        const uint8_t request = 1;
        bool sent = app_send_msg(MSG_BT_HANDOFF, &request, sizeof(request));
        printf("[HANDOFF] disableBluetooth honored; app teardown request %s\n",
               sent ? "sent" : "failed");
    } else if ([type isEqualToString:@"duckAudio"] ||
               [type isEqualToString:@"unduckAudio"]) {
        printf("[CONTROL] %s received\n", type.UTF8String);
    } else if ([type isEqualToString:@"forceKeyFrame"]) {
        printf("[CONTROL] forceKeyFrame received\n");
    } else {
        printf("[CONTROL] unhandled command type=%s\n", type.UTF8String);
    }
}

static bool process_event_command_frame(const uint8_t *bytes, size_t length) {
    HTTPReq request;
    if (!parse_http(bytes, length, &request) ||
        strcasecmp(request.method, "POST") != 0 ||
        !strstr(request.path, "/command") ||
        request.bodyLen < request.contentLength) return false;

    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)request.body
                                            length:request.bodyLen
                                      freeWhenDone:NO];
        id object = [NSPropertyListSerialization
            propertyListWithData:data options:0 format:NULL error:NULL];
        if ([object isKindOfClass:[NSDictionary class]])
            handle_command_dictionary(object);
    }

    char response[160];
    int responseLength = snprintf(
        response, sizeof(response),
        "RTSP/1.0 200 OK\r\nContent-Length: 0\r\nCSeq: %d\r\n\r\n",
        request.cseq);
    if (g_event_send_lock)
        dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
    int result = enc_send_frame(g_event_client_fd, &g_event_enc,
                                (const uint8_t *)response,
                                (size_t)responseLength);
    if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
    printf("[EVENT] command response %s CSeq=%d\n",
           result == 0 ? "sent" : "failed", request.cseq);
    return true;
}

static void handle_feedback(int sock, const HTTPReq *request) {
    @autoreleasepool {
        NSMutableArray *streams = [NSMutableArray array];
        for (size_t index = 0;
             index < sizeof(g_audio_streams) / sizeof(g_audio_streams[0]);
             index++) {
            carplay_audio_stream_t *audio = &g_audio_streams[index];
            if (audio->dataFd < 0 || audio->formatMask == 0) continue;

            NSMutableDictionary *stream = [NSMutableDictionary dictionary];
            stream[@"type"] = @(audio->type);
            double rate = audio_sample_rate(audio->formatMask);
            if (rate > 0) stream[@"sampleRate"] = @(rate);
            int64_t renderedSampleTime = 0;
            uint64_t renderedHostNTP = 0;
            uint64_t renderedHostRawNanos = 0;
            uint64_t renderUpdateCount = 0;
            pthread_mutex_lock(&g_audio_feedback_lock);
            renderedSampleTime = audio->renderedSampleTime;
            renderedHostNTP = audio->renderedHostNTP;
            renderedHostRawNanos = audio->renderedHostRawNanos;
            renderUpdateCount = audio->renderUpdateCount;
            pthread_mutex_unlock(&g_audio_feedback_lock);
            if (renderUpdateCount > 0 && renderedHostNTP != 0) {
                stream[@"streamConnectionID"] = @(audio->connectionID);
                stream[@"timestamp"] = @(renderedHostNTP);
                stream[@"timestampRawNs"] = @(renderedHostRawNanos);
                stream[@"sampleTime"] = @(renderedSampleTime);
            }
            [streams addObject:stream];
        }

        NSDictionary *feedback = @{ @"streams": streams };
        NSError *error = nil;
        NSData *body = [NSPropertyListSerialization
            dataWithPropertyList:feedback
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0
                           error:&error];
        printf("[AUDIO] feedback streams=%lu render=%s%s\n",
               (unsigned long)streams.count,
               streams.count > 0 &&
                       [streams[0][@"sampleTime"] isKindOfClass:
                           [NSNumber class]] ? "valid" : "pending",
               error ? " serialization-error" : "");
        bool rtsp = strncmp(request->protocol, "RTSP", 4) == 0;
        send_response(sock, rtsp ? "RTSP/1.0" : "HTTP/1.1",
                      error ? 500 : 200, error ? "Error" : "OK",
                      "application/x-apple-binary-plist",
                      body.bytes, body.length, request->cseq);
    }
}

static void handle_post_generic(int sock, const HTTPReq *r) {
    printf("[AP] -> POST %s (bodyLen=%zu, ct=%s)\n",
           r->path, r->bodyLen,
           r->contentType[0] ? r->contentType : "none");

    if (r->body && r->bodyLen > 0) {
        /* Try binary plist */
        @autoreleasepool {
            NSData *d = [NSData dataWithBytesNoCopy:(void *)r->body
                                             length:r->bodyLen
                                       freeWhenDone:NO];
            id obj = [NSPropertyListSerialization
                propertyListWithData:d options:0 format:NULL error:NULL];
            if (obj) {
                printf("[AP] plist: %s\n", [[obj description] UTF8String]);
                if (strstr(r->path, "/command") &&
                    [obj isKindOfClass:[NSDictionary class]])
                    handle_command_dictionary(obj);
            } else {
                printf("[AP] hex (%zu):", r->bodyLen);
                size_t n = r->bodyLen > 256 ? 256 : r->bodyLen;
                for (size_t i = 0; i < n; i++) printf(" %02X", r->body[i]);
                printf("\n");
            }
        }
    }

    bool rtsp = (strncmp(r->protocol, "RTSP", 4) == 0);
    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";
    send_response(sock, proto, 200, "OK",
                 "application/x-apple-binary-plist", NULL, 0, r->cseq);
}

/* ═══════════════════════════════════════════════════════════════
 * Request Router
 * ═══════════════════════════════════════════════════════════════ */

static void route_request(int sock, const HTTPReq *r) {
    printf("\n[AP] ── %s %s %s ──\n", r->method, r->path, r->protocol);
    fflush(stdout);

    if (strcasecmp(r->method, "GET") == 0) {
        if (strstr(r->path, "/info"))
            handle_info(sock, r);
        else {
            printf("[AP] -> GET %s (unknown)\n", r->path);
            send_ok(sock, r);
        }
    }
    else if (strcasecmp(r->method, "POST") == 0) {
        if (strstr(r->path, "/pair-setup"))
            handle_pair_setup(sock, r);
        else if (strstr(r->path, "/pair-verify"))
            handle_pair_verify(sock, r);
        else if (strstr(r->path, "/fp-setup"))
            handle_fp_setup(sock, r);
        else if (strstr(r->path, "/auth-setup"))
            handle_auth_setup(sock, r);
        else if (strstr(r->path, "/feedback"))
            handle_feedback(sock, r);
        else
            handle_post_generic(sock, r);
    }
    else if (strcasecmp(r->method, "OPTIONS") == 0) {
        handle_options(sock, r);
    }
    else if (strcasecmp(r->method, "SETUP") == 0) {
        handle_rtsp_setup(sock, r);
    }
    else if (strcasecmp(r->method, "RECORD") == 0) {
        handle_record(sock, r);
    }
    else if (strcasecmp(r->method, "SETRATE") == 0) {
        handle_setrate(sock, r);
    }
    else if (strcasecmp(r->method, "SETRATEANCHORTIME") == 0) {
        handle_setrate_anchor_time(sock, r);
    }
    else if (strcasecmp(r->method, "FLUSHBUFFERED") == 0) {
        handle_flush_buffered(sock, r);
    }
    else if (strcasecmp(r->method, "TEARDOWN") == 0) {
        handle_teardown(sock, r);
    }
    else {
        /* FLUSH, ANNOUNCE, PAUSE, PUT, etc. */
        handle_rtsp_generic(sock, r);
    }
    fflush(stdout);
}

/* ═══════════════════════════════════════════════════════════════
 * TCP Listener — port 7000 with keep-alive
 * ═══════════════════════════════════════════════════════════════ */

/* Routes one complete request received on the encrypted control channel. */
static void route_encrypted_request(int c, HTTPReq *r) {
    printf("\n[AP] ── %s %s %s (encrypted) ──\n", r->method, r->path, r->protocol);
    fflush(stdout);
    if (strcasecmp(r->method, "GET") == 0 && strstr(r->path, "/info")) {
        handle_info(c, r);
    } else if (strcasecmp(r->method, "POST") == 0) {
        if (strstr(r->path, "/pair-setup"))
            handle_pair_setup(c, r);
        else if (strstr(r->path, "/pair-verify"))
            handle_pair_verify(c, r);
        else if (strstr(r->path, "/fp-setup"))
            handle_fp_setup(c, r);
        else if (strstr(r->path, "/auth-setup"))
            handle_auth_setup(c, r);
        else if (strstr(r->path, "/feedback"))
            handle_feedback(c, r);
        else
            handle_post_generic(c, r);
    } else if (strcasecmp(r->method, "SETUP") == 0) {
        handle_rtsp_setup(c, r);
    } else if (strcasecmp(r->method, "RECORD") == 0) {
        handle_record(c, r);
    } else if (strcasecmp(r->method, "SETRATE") == 0) {
        handle_setrate(c, r);
    } else if (strcasecmp(r->method,
                          "SETRATEANCHORTIME") == 0) {
        handle_setrate_anchor_time(c, r);
    } else if (strcasecmp(r->method,
                          "FLUSHBUFFERED") == 0) {
        handle_flush_buffered(c, r);
    } else if (strcasecmp(r->method, "TEARDOWN") == 0) {
        handle_teardown(c, r);
    } else if (strcasecmp(r->method, "OPTIONS") == 0) {
        handle_options(c, r);
    } else {
        handle_rtsp_generic(c, r);
    }
    fflush(stdout);
}

static void handle_client(int c) {
    uint8_t buf[65536];
    size_t bufUsed = 0;
    enum { ENC_REQUEST_MAX = 65536 };
    uint8_t *encBuf = malloc(ENC_REQUEST_MAX);
    size_t encUsed = 0;
    if (!encBuf) {
        close(c);
        return;
    }

    /* Set recv timeout — must be long enough for iPhone to send SETUP Phase 2
     * after RECORD. Keepalive channel handles liveness detection. */
    struct timeval tv = { .tv_sec = 600, .tv_usec = 0 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* TCP keepalive. An iPhone that leaves Wi-Fi never closes the
     * connection, so probe after 10 s of silence and give up after 3 misses.
     * The iPhone posts /feedback every 2 s while a session runs. */
    int yes = 1, idle = 10, interval = 3, count = 3;
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
    setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof(count));

    while (1) {
        /* ── Encrypted mode: read framed ChaCha20-Poly1305 messages ── */
        if (g_enc.active) {
            uint8_t ptBuf[16384];
            int ptLen = enc_recv_frame(c, &g_enc, ptBuf, sizeof(ptBuf));
            if (ptLen == -2) {
                printf("[AP] Encrypted channel idle, still alive\n");
                fflush(stdout);
                continue;
            }
            if (ptLen <= 0) {
                if (ptLen == 0)
                    printf("[AP] Client closed connection (encrypted)\n");
                else
                    printf("[AP] Encrypted recv error or timeout\n");
                break;
            }

            printf("[ENC] Decrypted frame: %d bytes (nonce=%llu)\n",
                   ptLen, g_enc.readNonce - 1);

            /* Dump first 128 bytes */
            printf("[ENC] Plaintext hex (%d):", ptLen);
            int dump = ptLen > 128 ? 128 : ptLen;
            for (int i = 0; i < dump; i++) printf(" %02X", ptBuf[i]);
            if (ptLen > 128) printf(" ...");
            printf("\n");
            printf("[ENC] ASCII: ");
            for (int i = 0; i < dump; i++)
                printf("%c", (ptBuf[i] >= 0x20 && ptBuf[i] < 0x7f) ? ptBuf[i] : '.');
            printf("\n");
            fflush(stdout);

            /* iOS 27 splits a request across encrypted records (a SETUP
             * body of 832 bytes arrives as 816 + 16), so collect the
             * plaintext and route each request once it is complete. */
            if ((size_t)ptLen > ENC_REQUEST_MAX - encUsed) {
                printf("[ENC] Request larger than %d bytes, dropped\n", ENC_REQUEST_MAX);
                encUsed = 0;
                continue;
            }
            memcpy(encBuf + encUsed, ptBuf, (size_t)ptLen);
            encUsed += (size_t)ptLen;
            while (encUsed > 0) {
                HTTPReq r;
                size_t length;
                RequestState state = take_request(encBuf, encUsed, ENC_REQUEST_MAX, &r, &length);
                if (state == REQUEST_INCOMPLETE) {
                    printf("[ENC] Waiting for the rest of the request (%zu bytes so far)\n", encUsed);
                    break;
                }
                if (state == REQUEST_READY) route_encrypted_request(c, &r);
                else printf("[ENC] Dropped %zu bytes that are not a valid request\n", length);
                memmove(encBuf, encBuf + length, encUsed - length);
                encUsed -= length;
            }
            continue;
        }

        /* ── Plaintext mode: normal HTTP/RTSP parsing ── */
        ssize_t n = recv(c, buf + bufUsed, sizeof(buf) - bufUsed, 0);
        if (n <= 0) {
            if (n == 0)
                printf("[AP] Client closed connection\n");
            else if (errno == EAGAIN || errno == EWOULDBLOCK)
                printf("[AP] Client timeout (600s idle)\n");
            else
                printf("[AP] recv error: %s\n", strerror(errno));
            break;
        }
        bufUsed += n;

        /* Try to parse a complete request */
        HTTPReq r;
        if (!parse_http(buf, bufUsed, &r)) {
            /* Not enough data yet, keep reading */
            if (bufUsed >= sizeof(buf) - 1) {
                printf("[AP] Buffer overflow, dropping\n");
                bufUsed = 0;
            }
            continue;
        }

        /* Wait for the end of the headers and the full body */
        if (!r.body || (r.contentLength > 0 && r.bodyLen < r.contentLength)) {
            if (bufUsed >= sizeof(buf) - 1) {
                printf("[AP] Buffer overflow, dropping\n");
                bufUsed = 0;
            }
            continue;
        }

        /* Route the request */
        route_request(c, &r);

        /* Calculate total request size and shift buffer */
        size_t headerSize = (r.body ? (r.body - buf) : bufUsed);
        size_t totalSize = headerSize + r.contentLength;
        if (totalSize < bufUsed) {
            memmove(buf, buf + totalSize, bufUsed - totalSize);
            bufUsed -= totalSize;
        } else {
            bufUsed = 0;
        }
    }
    free(encBuf);
    close(c);
    printf("[AP] Connection closed\n");
    /* A session uses one encrypted control connection. Once it ends, by
     * TEARDOWN, the iPhone closing it, or the iPhone leaving Wi-Fi, exit so
     * Showcase stops the session the same way the Stop button does. */
    if (g_enc.active) {
        printf("[AP] CarPlay session ended; exiting\n");
        fflush(stdout);
        exit(0);
    }
}

static bool start_airplay_server(uint16_t port) {
    int sock = socket(AF_INET6, SOCK_STREAM, 0);
    if (sock < 0) { perror("[AP] socket"); return false; }

    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    int no = 0;
    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    struct sockaddr_in6 addr = {0};
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(port);
    addr.sin6_addr = in6addr_any;

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[AP] bind"); close(sock); return false;
    }
    if (listen(sock, 5) < 0) {
        perror("[AP] listen"); close(sock); return false;
    }
    printf("[AP] AirPlay server listening on port %d (IPv4+IPv6)\n", port);

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (1) {
            struct sockaddr_storage ca;
            socklen_t cl = sizeof(ca);
            int c = accept(sock, (struct sockaddr *)&ca, &cl);
            if (c < 0) { perror("[AP] accept"); continue; }

            char host[NI_MAXHOST], serv[NI_MAXSERV];
            sockaddr_to_numeric((struct sockaddr *)&ca, cl,
                                host, sizeof(host), serv, sizeof(serv));
            printf("\n[AP] *** NEW CONNECTION from %s:%s family=%s ***\n",
                   host, serv, addr_family_name(ca.ss_family));
            fflush(stdout);
            app_send_status(STATUS_IPHONE_CONNECTED);

            /* Handle each connection in its own dispatch queue */
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                handle_client(c);
            });
        }
    });
    return true;
}

/* ═══════════════════════════════════════════════════════════════
 * Control Channel — connect to iPhone's _carplay-ctrl._tcp
 * Keep connection alive and read continuously
 * ═══════════════════════════════════════════════════════════════ */

static void trim_dot(const char *src, char *dst, size_t dstLen) {
    if (!src || !dst || dstLen == 0) return;
    size_t n = strlen(src);
    while (n > 0 && src[n - 1] == '.') n--;
    if (n >= dstLen) n = dstLen - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* try_connect — verbose=true prints each attempt, false is silent (for probing) */
static int try_connect(const char *host, uint16_t port, uint32_t ifIndex,
                       bool verbose, int timeout_sec) {
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", (unsigned)port);

    char clean[256];
    trim_dot(host, clean, sizeof(clean));

    /* Force IPv4 — IPv6 outbound on bridge100 consistently fails
     * (SYN never gets SYN-ACK, blocks for 75s) */
    struct addrinfo hints = { .ai_family = AF_INET,
                              .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    int gai = getaddrinfo(clean, portStr, &hints, &res);
    if (gai != 0) {
        if (verbose)
            printf("[CTRL] getaddrinfo(%s:%s) failed: %s\n",
                   clean, portStr, gai_strerror(gai));
        if (gai != EAI_SYSTEM) errno = EHOSTUNREACH;
        return -1;
    }

    int lastError = EHOSTUNREACH;
    for (const struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) { lastError = errno; continue; }

        char addrStr[NI_MAXHOST], portS[NI_MAXSERV];
        getnameinfo(ai->ai_addr, ai->ai_addrlen,
                    addrStr, sizeof(addrStr), portS, sizeof(portS),
                    NI_NUMERICHOST | NI_NUMERICSERV);
        if (verbose)
            printf("[CTRL] Trying %s:%s\n", addrStr, portS);

        /* Non-blocking connect with configurable timeout via select() */
        int flags = fcntl(s, F_GETFL, 0);
        fcntl(s, F_SETFL, flags | O_NONBLOCK);

        int ret = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (ret < 0 && errno == EINPROGRESS) {
            fd_set wset;
            FD_ZERO(&wset);
            FD_SET(s, &wset);
            struct timeval tv = { .tv_sec = timeout_sec, .tv_usec = 0 };
            int sel = select(s + 1, NULL, &wset, NULL, &tv);
            if (sel > 0) {
                int serr = 0;
                socklen_t slen = sizeof(serr);
                if (getsockopt(s, SOL_SOCKET, SO_ERROR, &serr, &slen) < 0)
                    serr = errno;
                if (serr == 0) ret = 0;
                else { errno = serr; ret = -1; }
            } else {
                if (sel == 0) errno = ETIMEDOUT;
                ret = -1;
            }
        }

        int connectError = ret < 0 ? errno : 0;
        /* Restore blocking mode */
        fcntl(s, F_SETFL, flags);

        if (ret == 0) {
            printf("[CTRL] Connected %s:%s\n", addrStr, portS);
            freeaddrinfo(res);
            return s;
        }
        if (verbose)
            printf("[CTRL] Failed: %s\n", strerror(connectError));
        lastError = connectError;
        close(s);
    }
    freeaddrinfo(res);
    errno = lastError; /* cleanup must not hide refusal of a stale port */
    return -1;
}

/* ═══════════════════════════════════════════════════════════════
 * Ctrl Service State — stored globally for re-resolution
 * ═══════════════════════════════════════════════════════════════ */

static char g_ctrlName[256]    = {0};
static char g_ctrlRegType[256] = {0};
static char g_ctrlDomain[256]  = {0};
static uint32_t g_ctrlIfIndex  = 0;
static volatile bool g_ctrlFound = false;
static volatile bool g_ctrlConnected = false;

/* Synchronous re-resolve: returns fresh port, or 0 on failure */
typedef struct { char host[256]; uint16_t port; bool resolved; } ResolveResult;

static void sync_resolve_cb(DNSServiceRef ref, DNSServiceFlags flags,
                             uint32_t ifIndex, DNSServiceErrorType err,
                             const char *fullname, const char *hosttarget,
                             uint16_t port, uint16_t txtLen,
                             const unsigned char *txtRecord, void *ctx) {
    (void)ref; (void)flags; (void)ifIndex; (void)fullname;
    (void)txtLen; (void)txtRecord;
    ResolveResult *r = (ResolveResult *)ctx;
    if (err == kDNSServiceErr_NoError) {
        trim_dot(hosttarget, r->host, sizeof(r->host));
        r->port = ntohs(port);
        r->resolved = true;
    }
}

static bool resolve_ctrl_port(ResolveResult *out) {
    if (!g_ctrlFound) return false;

    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceResolve(
        &ref, kDNSServiceFlagsForceMulticast, g_ctrlIfIndex,
        g_ctrlName, g_ctrlRegType, g_ctrlDomain,
        sync_resolve_cb, out);
    if (e != kDNSServiceErr_NoError) return false;

    /* Wait up to 3s for resolve response */
    int fd = DNSServiceRefSockFD(ref);
    fd_set rset;
    FD_ZERO(&rset);
    FD_SET(fd, &rset);
    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    if (select(fd + 1, &rset, NULL, NULL, &tv) > 0) {
        DNSServiceProcessResult(ref);
    }
    DNSServiceRefDeallocate(ref);
    return out->resolved;
}

/* ═══════════════════════════════════════════════════════════════
 * Ctrl Channel — smart connect with re-resolve on failure
 * ═══════════════════════════════════════════════════════════════ */

static void ctrl_send_connect(int sock, const char *host) {
    printf("[CTRL] *** Connected to CarPlay control channel ***\n");
    g_ctrlConnected = true;

    /* Send GET /ctrl-int/1/connect
     * CRITICAL: AirPlay-Receiver-Device-ID must be DECIMAL INTEGER,
     * not MAC format. TomSignalius uses "%llu", wiomoc uses str(mac_int). */
    char request[1024];
    int reqlen = snprintf(request, sizeof(request),
        "GET /ctrl-int/1/connect HTTP/1.1\r\n"
        "Host: %s\r\n"
        "User-Agent: AirPlay/%s\r\n"
        "AirPlay-Receiver-Device-ID: %s\r\n"
        "\r\n",
        host, SOURCE_VERSION, DEVICE_ID_INT);

    printf("[CTRL] Sending:\n%s", request);
    ssize_t sent = send(sock, request, reqlen, 0);
    printf("[CTRL] Sent %zd bytes\n", sent);
    if (sent <= 0) { close(sock); goto done; }

    /* TCP keepalive to prevent idle timeout */
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));

    /* Read the initial 200 OK response, then keep channel open
     * and read any further commands the iPhone sends. */
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t buf[8192];
    ssize_t n = recv(sock, buf, sizeof(buf) - 1, 0);
    if (n > 0) {
        buf[n] = '\0';
        printf("[CTRL] Response (%zd bytes):\n", n);
        if (n > 4 && (buf[0] == 'H' || buf[0] == 'R')) {
            fwrite(buf, 1, (size_t)n, stdout);
            printf("\n");
        }
        printf("[CTRL] Hex (%zd):", n);
        for (int i = 0; i < n && i < 256; i++) printf(" %02X", buf[i]);
        if (n > 256) printf(" ...");
        printf("\n");

        if (strstr((char *)buf, "200") || strstr((char *)buf, "OK"))
            printf("[CTRL] *** ctrl-int connect SUCCEEDED — keeping channel open ***\n");
        else {
            printf("[CTRL] *** ctrl-int connect got non-200 response ***\n");
            goto done;
        }
    } else if (n == 0) {
        printf("[CTRL] iPhone closed connection without responding (FIN)\n");
        goto done;
    } else {
        printf("[CTRL] recv error: %s\n", strerror(errno));
        goto done;
    }
    fflush(stdout);

    /* Keep channel open — read any commands iPhone sends.
     * Use a long recv timeout so we stay alive but don't block forever. */
    tv.tv_sec = 120;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    while (1) {
        n = recv(sock, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            buf[n] = '\0';
            printf("[CTRL] Received (%zd bytes):\n", n);
            if (n > 4 && (buf[0] >= 0x20 && buf[0] < 0x7f)) {
                fwrite(buf, 1, (size_t)n, stdout);
                printf("\n");
            }
            printf("[CTRL] Hex (%zd):", n);
            for (int i = 0; i < n && i < 512; i++) printf(" %02X", buf[i]);
            if (n > 512) printf(" ...");
            printf("\n");
            fflush(stdout);

            /* Echo back 200 OK for any HTTP-looking request */
            if (buf[0] == 'G' || buf[0] == 'P' || buf[0] == 'H') {
                const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
                send(sock, resp, strlen(resp), 0);
                printf("[CTRL] Sent 200 OK reply\n");
            }
            fflush(stdout);
        } else if (n == 0) {
            printf("[CTRL] iPhone closed ctrl channel (FIN)\n");
            break;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                printf("[CTRL] Ctrl channel idle (120s), still alive\n");
                fflush(stdout);
                continue;
            }
            printf("[CTRL] Ctrl channel recv error: %s\n", strerror(errno));
            break;
        }
    }

done:
    close(sock);
    g_ctrlConnected = false;
    printf("[CTRL] Control channel closed\n");
    fflush(stdout);
}

static void ctrl_connect_thread(void *ctx) {
    (void)ctx;

    /* ── Phase 1: Wait for iPhone to actually be on the network ──
     * mDNS browse returns cached results from previous sessions, so we
     * often fire before the BT handshake has even happened. We probe
     * silently with short timeouts until the host responds. */
    printf("[CTRL] iPhone service found (likely cached). "
           "Waiting for BT handshake...\n");
    fflush(stdout);

    int waitSecs = 0;
    while (1) {
        ResolveResult rr = { .resolved = false };
        if (!resolve_ctrl_port(&rr)) {
            sleep(1); waitSecs += 1;
            if (waitSecs % 30 == 0)
                printf("[CTRL] Still waiting for iPhone... (%ds)\n", waitSecs);
            continue;
        }

        /* Ports change between sessions. Re-resolve promptly so a cached
         * endpoint cannot stall the new Bluetooth-to-Wi-Fi handoff. */
        int sock = try_connect(rr.host, rr.port, g_ctrlIfIndex, false, 1);
        if (sock >= 0) {
            /* Connected on first probe! */
            ctrl_send_connect(sock, rr.host);
            return;
        }

        int connectError = errno;
        printf("[CTRL] Probe %s:%u failed: %s\n", rr.host,
               (unsigned)rr.port, strerror(connectError));
        fflush(stdout);
        if (connectError == ECONNREFUSED) {
            /* iPhone IS on the network (TCP RST = host reachable).
             * This port is stale — move to Phase 2 with re-resolve. */
            printf("[CTRL] iPhone is online! (port %u stale, re-resolving)\n",
                   (unsigned)rr.port);
            break;
        }

        /* EHOSTDOWN / ETIMEDOUT / EHOSTUNREACH — not on network yet */
        sleep(1); waitSecs += 1;
        if (waitSecs % 30 == 0 && waitSecs > 0) {
            printf("[CTRL] Still waiting for iPhone... (%ds)\n", waitSecs);
            fflush(stdout);
        }
    }

    /* ── Phase 2: iPhone is reachable — resolve & connect ──
     * Now we do the verbose re-resolve loop since we know the
     * iPhone is actually on the network. */
    for (int round = 1; round <= CTRL_RESOLVE_ROUNDS; round++) {
        ResolveResult rr = { .resolved = false };
        printf("[CTRL] Resolve round %d/%d...\n", round, CTRL_RESOLVE_ROUNDS);

        if (!resolve_ctrl_port(&rr)) {
            printf("[CTRL] Resolve failed, retrying in %ds...\n", CTRL_RETRY_SEC * 2);
            sleep(CTRL_RETRY_SEC * 2);
            continue;
        }

        printf("[CTRL] Resolved: %s:%u\n", rr.host, (unsigned)rr.port);

        for (int attempt = 1; attempt <= CTRL_CONNECT_ATTEMPTS; attempt++) {
            printf("[CTRL] Connect attempt %d/%d to %s:%u\n",
                   attempt, CTRL_CONNECT_ATTEMPTS,
                   rr.host, (unsigned)rr.port);

            int sock = try_connect(rr.host, rr.port, g_ctrlIfIndex, true, 5);
            if (sock >= 0) {
                ctrl_send_connect(sock, rr.host);
                return;
            }

            if (errno == ECONNREFUSED) {
                printf("[CTRL] Port %u refused — re-resolving\n",
                       (unsigned)rr.port);
                break;
            }
            if (attempt < CTRL_CONNECT_ATTEMPTS) {
                printf("[CTRL] Retrying in %ds...\n", CTRL_RETRY_SEC);
                sleep(CTRL_RETRY_SEC);
            }
        }

        if (round < CTRL_RESOLVE_ROUNDS) {
            sleep(CTRL_RETRY_SEC);
        }
    }
    printf("[CTRL] *** ALL RESOLVE ROUNDS EXHAUSTED ***\n");
}

/* ═══════════════════════════════════════════════════════════════
 * mDNS Callbacks
 * ═══════════════════════════════════════════════════════════════ */

static void reg_callback(DNSServiceRef ref, DNSServiceFlags flags,
                         DNSServiceErrorType err, const char *name,
                         const char *regtype, const char *domain, void *ctx) {
    (void)ref; (void)flags; (void)ctx;
    if (err == kDNSServiceErr_NoError)
        printf("[MDNS] Registered: %s.%s%s\n", name, regtype, domain);
    else
        printf("[MDNS] Register failed: err=%d\n", err);
}

static void browse_callback(DNSServiceRef ref, DNSServiceFlags flags,
                            uint32_t ifIndex, DNSServiceErrorType err,
                            const char *name, const char *regtype,
                            const char *domain, void *ctx) {
    (void)ref; (void)ctx;
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] Browse error: %d\n", err);
        return;
    }
    if (flags & kDNSServiceFlagsAdd) {
        printf("\n[MDNS] *** FOUND: %s.%s%s (if=%u) ***\n",
               name, regtype, domain, ifIndex);

        /* Store service info for re-resolution */
        snprintf(g_ctrlName, sizeof(g_ctrlName), "%s", name);
        snprintf(g_ctrlRegType, sizeof(g_ctrlRegType), "%s", regtype);
        snprintf(g_ctrlDomain, sizeof(g_ctrlDomain), "%s", domain);
        g_ctrlIfIndex = ifIndex;

        /* Only spawn ctrl thread once */
        if (!g_ctrlFound) {
            g_ctrlFound = true;
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                ctrl_connect_thread(NULL);
            });
        }
    } else {
        printf("[MDNS] Removed: %s.%s%s\n", name, regtype, domain);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * TXT Record Builder — _airplay._tcp
 * ═══════════════════════════════════════════════════════════════ */

static TXTRecordRef build_airplay_txt(void) {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);

    const char *ft = g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK;

    /* Apple SDK order: deviceid, features, fv, flags, model, protovers, pi, pk, srcvers */
    TXTRecordSetValue(&txt, "deviceid",    strlen(DEVICE_ID),      DEVICE_ID);
    TXTRecordSetValue(&txt, "features",    strlen(ft),             ft);
    TXTRecordSetValue(&txt, "flags",       strlen("0x4"),          "0x4");
    TXTRecordSetValue(&txt, "model",       strlen(MODEL_NAME),    MODEL_NAME);
    TXTRecordSetValue(&txt, "protovers",   3,                      "1.1");
    TXTRecordSetValue(&txt, "pi",          strlen(HK_PI),         HK_PI);
    TXTRecordSetValue(&txt, "pk",          strlen(HK_PK),         HK_PK);
    TXTRecordSetValue(&txt, "srcvers",     strlen(SOURCE_VERSION), SOURCE_VERSION);
    return txt;
}

/* ═══════════════════════════════════════════════════════════════
 * TXT Record Builder — _raop._tcp
 * Every working AirPlay 2 receiver registers BOTH _airplay._tcp
 * AND _raop._tcp. Without _raop._tcp, the iPhone sees an
 * incomplete advertisement and never connects to port 7000.
 * ═══════════════════════════════════════════════════════════════ */

static TXTRecordRef build_raop_txt(void) {
    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);

    const char *ft = g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK;

    TXTRecordSetValue(&txt, "txtvers",  1,                      "1");
    TXTRecordSetValue(&txt, "ch",       1,                      "2");
    TXTRecordSetValue(&txt, "cn",       7,                      "0,1,2,3");
    TXTRecordSetValue(&txt, "da",       4,                      "true");
    TXTRecordSetValue(&txt, "et",       5,                      "0,3,5");
    TXTRecordSetValue(&txt, "md",       5,                      "0,1,2");
    TXTRecordSetValue(&txt, "pw",       5,                      "false");
    TXTRecordSetValue(&txt, "sv",       5,                      "false");
    TXTRecordSetValue(&txt, "sr",       5,                      "44100");
    TXTRecordSetValue(&txt, "ss",       2,                      "16");
    TXTRecordSetValue(&txt, "tp",       3,                      "UDP");
    TXTRecordSetValue(&txt, "vn",       5,                      "65537");
    TXTRecordSetValue(&txt, "vs",       strlen(SOURCE_VERSION), SOURCE_VERSION);
    TXTRecordSetValue(&txt, "am",       strlen(MODEL_NAME),     MODEL_NAME);
    TXTRecordSetValue(&txt, "sf",       3,                      "0x0");
    TXTRecordSetValue(&txt, "ft",       strlen(ft),             ft);
    TXTRecordSetValue(&txt, "pk",       strlen(HK_PK),          HK_PK);
    return txt;
}


/* ═══════════════════════════════════════════════════════════════
 * Wire-level unsolicited mDNS announcer
 *
 * DNSServiceUpdateRecord() can return success without putting a fresh
 * multicast announcement on bridge100. The failing iOS 26 sender joins the
 * hotspot but never queries _airplay._tcp, so it must receive an unsolicited
 * announcement after DHCP/ARP. This helper sends the minimum AirPlay/RAOP
 * records directly to 224.0.0.251:5353 during the handoff window.
 * ═══════════════════════════════════════════════════════════════ */

static bool mdns_put_u16(uint8_t *buf, size_t cap, size_t *off, uint16_t v) {
    if (*off + 2 > cap) return false;
    buf[(*off)++] = (uint8_t)(v >> 8);
    buf[(*off)++] = (uint8_t)(v & 0xff);
    return true;
}

static bool mdns_put_u32(uint8_t *buf, size_t cap, size_t *off, uint32_t v) {
    if (*off + 4 > cap) return false;
    buf[(*off)++] = (uint8_t)(v >> 24);
    buf[(*off)++] = (uint8_t)(v >> 16);
    buf[(*off)++] = (uint8_t)(v >> 8);
    buf[(*off)++] = (uint8_t)(v & 0xff);
    return true;
}

static bool mdns_put_bytes(uint8_t *buf, size_t cap, size_t *off,
                           const void *data, size_t len) {
    if (*off + len > cap) return false;
    memcpy(buf + *off, data, len);
    *off += len;
    return true;
}

static bool mdns_put_name(uint8_t *buf, size_t cap, size_t *off,
                          const char *name) {
    const char *p = name;
    while (*p) {
        const char *dot = strchr(p, '.');
        size_t len = dot ? (size_t)(dot - p) : strlen(p);
        if (len > 63 || *off + 1 + len > cap) return false;
        buf[(*off)++] = (uint8_t)len;
        memcpy(buf + *off, p, len);
        *off += len;
        if (!dot) break;
        p = dot + 1;
    }
    if (*off + 1 > cap) return false;
    buf[(*off)++] = 0;
    return true;
}

static bool mdns_put_ptr(uint8_t *buf, size_t cap, size_t *off,
                         const char *name, const char *target, uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, name)) return false;
    if (!mdns_put_u16(buf, cap, off, 12)) return false;      /* PTR */
    if (!mdns_put_u16(buf, cap, off, 1)) return false;       /* IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    size_t rdlen_at = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;
    size_t rstart = *off;
    if (!mdns_put_name(buf, cap, off, target)) return false;
    uint16_t rdlen = (uint16_t)(*off - rstart);
    buf[rdlen_at] = (uint8_t)(rdlen >> 8);
    buf[rdlen_at + 1] = (uint8_t)(rdlen & 0xff);
    return true;
}

static bool mdns_put_srv(uint8_t *buf, size_t cap, size_t *off,
                         const char *name, const char *target,
                         uint16_t port, uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, name)) return false;
    if (!mdns_put_u16(buf, cap, off, 33)) return false;      /* SRV */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    size_t rdlen_at = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;
    size_t rstart = *off;
    if (!mdns_put_u16(buf, cap, off, 0)) return false;       /* priority */
    if (!mdns_put_u16(buf, cap, off, 0)) return false;       /* weight */
    if (!mdns_put_u16(buf, cap, off, port)) return false;
    if (!mdns_put_name(buf, cap, off, target)) return false;
    uint16_t rdlen = (uint16_t)(*off - rstart);
    buf[rdlen_at] = (uint8_t)(rdlen >> 8);
    buf[rdlen_at + 1] = (uint8_t)(rdlen & 0xff);
    return true;
}

static bool mdns_put_txt_bytes(uint8_t *buf, size_t cap, size_t *off,
                               const char *name, const void *txt,
                               uint16_t txt_len, uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, name)) return false;
    if (!mdns_put_u16(buf, cap, off, 16)) return false;      /* TXT */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    if (!mdns_put_u16(buf, cap, off, txt_len)) return false;
    return mdns_put_bytes(buf, cap, off, txt, txt_len);
}

static bool mdns_put_a(uint8_t *buf, size_t cap, size_t *off,
                       const char *name, uint32_t addr_be, uint32_t ttl) {
    if (!mdns_put_name(buf, cap, off, name)) return false;
    if (!mdns_put_u16(buf, cap, off, 1)) return false;       /* A */
    if (!mdns_put_u16(buf, cap, off, 0x8001)) return false;  /* cache flush + IN */
    if (!mdns_put_u32(buf, cap, off, ttl)) return false;
    if (!mdns_put_u16(buf, cap, off, 4)) return false;
    return mdns_put_bytes(buf, cap, off, &addr_be, 4);
}

static uint32_t bridge100_ipv4_addr(void) {
    struct ifaddrs *ifas = NULL;
    uint32_t out = inet_addr("172.20.10.1");
    if (getifaddrs(&ifas) == 0) {
        for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_name || !ifa->ifa_addr) continue;
            if (strcmp(ifa->ifa_name, "bridge100") != 0) continue;
            if (ifa->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            out = sin->sin_addr.s_addr;
            break;
        }
        freeifaddrs(ifas);
    }
    return out;
}

static void local_mdns_target_name(char *out, size_t out_len) {
    char host[128] = {0};
    if (gethostname(host, sizeof(host) - 1) != 0 || !host[0]) {
        snprintf(host, sizeof(host), "Carplay-Receiver");
    }
    /* Strip an existing .local suffix if present, then append exactly once. */
    char *dotlocal = strstr(host, ".local");
    if (dotlocal) *dotlocal = '\0';
    snprintf(out, out_len, "%s.local", host);
}

static int send_unsolicited_mdns_airplay_announcement(void) {
    char airplay_inst[128];
    char raop_inst[160];
    char target[160];
    snprintf(airplay_inst, sizeof(airplay_inst), "%s._airplay._tcp.local", g_instance_name);
    snprintf(raop_inst, sizeof(raop_inst), "%s._raop._tcp.local", g_raop_name);
    local_mdns_target_name(target, sizeof(target));

    TXTRecordRef apTxt = build_airplay_txt();
    TXTRecordRef raopTxt = build_raop_txt();

    uint8_t pkt[1800];
    size_t off = 0;
    bool ok = true;

    /* DNS header: response, authoritative answer, no questions, 7 answers. */
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0x0000);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0x8400);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 7);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);
    ok &= mdns_put_u16(pkt, sizeof(pkt), &off, 0);

    ok &= mdns_put_ptr(pkt, sizeof(pkt), &off, "_airplay._tcp.local", airplay_inst, 4500);
    ok &= mdns_put_srv(pkt, sizeof(pkt), &off, airplay_inst, target, AIRPLAY_PORT, 120);
    ok &= mdns_put_txt_bytes(pkt, sizeof(pkt), &off, airplay_inst,
                             TXTRecordGetBytesPtr(&apTxt),
                             TXTRecordGetLength(&apTxt), 4500);
    ok &= mdns_put_ptr(pkt, sizeof(pkt), &off, "_raop._tcp.local", raop_inst, 4500);
    ok &= mdns_put_srv(pkt, sizeof(pkt), &off, raop_inst, target, AIRPLAY_PORT, 120);
    ok &= mdns_put_txt_bytes(pkt, sizeof(pkt), &off, raop_inst,
                             TXTRecordGetBytesPtr(&raopTxt),
                             TXTRecordGetLength(&raopTxt), 4500);
    ok &= mdns_put_a(pkt, sizeof(pkt), &off, target, bridge100_ipv4_addr(), 120);

    TXTRecordDeallocate(&apTxt);
    TXTRecordDeallocate(&raopTxt);

    if (!ok) {
        printf("[MDNS] wire announce build failed\n");
        return -1;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        printf("[MDNS] wire announce socket failed: %s\n", strerror(errno));
        return -1;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = htons(5353);
    local.sin_addr.s_addr = bridge100_ipv4_addr();
    if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        /* Do not fail the announcement solely because mDNSResponder owns 5353.
         * A 5353 source port is preferred, but the packet still helps as a
         * multicast hint on some iOS builds. */
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_port = 0;
        local.sin_addr.s_addr = bridge100_ipv4_addr();
        bind(fd, (struct sockaddr *)&local, sizeof(local));
    }

    uint8_t ttl = 255;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
    uint8_t loop = 0;
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof(loop));

    struct in_addr ifaddr;
    ifaddr.s_addr = bridge100_ipv4_addr();
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifaddr, sizeof(ifaddr));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(5353);
    inet_aton("224.0.0.251", &dst.sin_addr);

    ssize_t n = sendto(fd, pkt, off, 0, (struct sockaddr *)&dst, sizeof(dst));
    close(fd);
    if (n < 0) {
        printf("[MDNS] wire announce send failed: %s\n", strerror(errno));
        return -1;
    }
    return (int)n;
}

static DNSServiceErrorType update_registered_txt(DNSServiceRef ref, TXTRecordRef *txt) {
    if (!ref) return kDNSServiceErr_BadReference;
    return DNSServiceUpdateRecord(ref, NULL, 0,
                                  TXTRecordGetLength(txt),
                                  TXTRecordGetBytesPtr(txt),
                                  0);
}

static void start_mdns_reannounce_loop(DNSServiceRef airplayRef,
                                       DNSServiceRef raopRef) {
    if (!airplayRef && !raopRef) return;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        int ticks = MDNS_REANNOUNCE_SECONDS / MDNS_REANNOUNCE_INTERVAL;
        printf("[MDNS] Reannounce loop: every %ds for %ds\n",
               MDNS_REANNOUNCE_INTERVAL, MDNS_REANNOUNCE_SECONDS);

        for (int i = 1; i <= ticks; i++) {
            sleep(MDNS_REANNOUNCE_INTERVAL);

            DNSServiceErrorType apErr = kDNSServiceErr_NoError;
            DNSServiceErrorType raopErr = kDNSServiceErr_NoError;

            if (airplayRef) {
                TXTRecordRef apTxt = build_airplay_txt();
                apErr = update_registered_txt(airplayRef, &apTxt);
                TXTRecordDeallocate(&apTxt);
            }
            if (raopRef) {
                TXTRecordRef raopTxt = build_raop_txt();
                raopErr = update_registered_txt(raopRef, &raopTxt);
                TXTRecordDeallocate(&raopTxt);
            }

            int wireBytes = send_unsolicited_mdns_airplay_announcement();

            if (i == 1 || i % 5 == 0 || apErr || raopErr || wireBytes < 0) {
                printf("[MDNS] Reannounce tick %d/%d: airplay=%d raop=%d wire=%d\n",
                       i, ticks, apErr, raopErr, wireBytes);
            }
        }
        printf("[MDNS] Reannounce loop finished\n");
    });
}

/* ═══════════════════════════════════════════════════════════════
 * Main
 * ═══════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[]) {
    /* Line-buffered stdout/stderr so logs survive SIGTERM (default is
     * fully-buffered when stdout is a file, which loses everything). */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    /* Parse car name (--name X) early so g_instance_name/g_raop_name are set */
    parse_args(argc, argv);

    /* Parse remaining flags */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--hk") == 0) {
            g_useHK = true;
            printf("[SVC] HomeKit pairing ENABLED (features: %s)\n",
                   FEATURES_WITH_HK);
        }
    }

    signal(SIGPIPE, SIG_IGN);
    if (g_baa_broker_mode) {
        printf("[SVC] Starting pre-hotspot BAA broker mode\n");
        return run_baa_broker();
    }
    g_event_send_lock = dispatch_semaphore_create(1);
    g_app_send_lock = dispatch_semaphore_create(1);
    g_video_config_lock = dispatch_semaphore_create(1);
    g_hid_send_queue = dispatch_queue_create(
        "com.reng.showcase.hid", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(g_hid_send_queue,
                              dispatch_get_global_queue(
                                  DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    if (!ensure_pair_context()) {
        printf("[SVC] FATAL: could not initialize pairing context\n");
        return 1;
    }

    printf("[SVC] CarPlay Network Services v5.1 (real Ed25519 pk, no HK)\n");
    printf("[SVC] DeviceID:  %s\n", DEVICE_ID);
    printf("[SVC] Features:  %s\n", g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK);
    printf("[SVC] Model:     %s\n", MODEL_NAME);
    printf("[SVC] srcvers:   %s\n", SOURCE_VERSION);
    printf("[SVC] HK:        %s\n", g_useHK ? "YES" : "NO");
    printf("[SVC] RAOP name: %s\n", g_raop_name);
    printf("[SVC] Display:   %ux%u @ %u FPS\n",
           g_display_width, g_display_height, g_display_fps);
    printf("[SVC] pi:        %s\n", HK_PI);
    printf("[SVC] pk:        %s\n", HK_PK);
    printf("[SVC] Ed25519:   REAL keypair (sk stored for pair-verify)\n");

    /* Load the certificate preheated by the long-lived broker helper. */
    load_baa_from_broker();

    /* Prefer bridge100 when it is already present. Personal Hotspot can
     * briefly remove and recreate the bridge during the Bluetooth-to-Wi-Fi
     * transition; DNS-SD interface 0 safely advertises on eligible
     * interfaces instead of killing the receiver during that race. */
    unsigned int br = if_nametoindex("bridge100");
    if (br == 0) {
        printf("[SVC] WARN: bridge100 is transiently unavailable; "
               "registering DNS-SD on all eligible interfaces\n");
    } else {
        printf("[SVC] bridge100 ifIndex = %u\n", br);
    }

    /* Start AirPlay HTTP/RTSP server on port 7000 */
    if (!start_airplay_server(AIRPLAY_PORT)) {
        printf("[SVC] FATAL: cannot listen on AirPlay port %d; aborting\n",
               AIRPLAY_PORT);
        return 1;
    }

    /* ── Register _airplay._tcp ── */
    printf("[MDNS] Registering _airplay._tcp on port %d (if=%u)...\n",
           AIRPLAY_PORT, br);
    DNSServiceRef regRef = NULL;
    TXTRecordRef apTxt = build_airplay_txt();
    DNSServiceErrorType err = DNSServiceRegister(
        &regRef, kDNSServiceFlagsKnownUnique, br,
        g_instance_name, "_airplay._tcp",
        NULL, SRV_HOSTNAME, htons(AIRPLAY_PORT),
        TXTRecordGetLength(&apTxt), TXTRecordGetBytesPtr(&apTxt),
        reg_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] _airplay._tcp register FAILED: %d\n", err);
    } else {
        DNSServiceProcessResult(regRef);
        printf("[MDNS] _airplay._tcp registered\n");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(regRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] _airplay._tcp error: %d\n", e);
                    break;
                }
            }
        });
    }
    TXTRecordDeallocate(&apTxt);

    /* ── Register _raop._tcp ──
     * CRITICAL: Every working AirPlay 2 receiver needs BOTH services.
     * Name format: AABBCCDDEEFF@DeviceName (MAC without colons @ name)
     * Port: same as AirPlay (7000). */
    printf("[MDNS] Registering _raop._tcp as '%s' on port %d (if=%u)...\n",
           g_raop_name, AIRPLAY_PORT, br);
    DNSServiceRef raopRef = NULL;
    TXTRecordRef raopTxt = build_raop_txt();
    err = DNSServiceRegister(
        &raopRef, kDNSServiceFlagsKnownUnique, br,
        g_raop_name, "_raop._tcp",
        NULL, SRV_HOSTNAME, htons(AIRPLAY_PORT),
        TXTRecordGetLength(&raopTxt), TXTRecordGetBytesPtr(&raopTxt),
        reg_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] _raop._tcp register FAILED: %d\n", err);
    } else {
        DNSServiceProcessResult(raopRef);
        printf("[MDNS] _raop._tcp registered\n");
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(raopRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] _raop._tcp error: %d\n", e);
                    break;
                }
            }
        });
    }
    TXTRecordDeallocate(&raopTxt);

    /* iOS can join the Personal Hotspot after our first unsolicited mDNS
     * advertisements have already gone out. Keep nudging mDNSResponder to
     * re-announce _airplay/_raop while the phone is expected to join. */
    start_mdns_reannounce_loop(regRef, raopRef);

    /* Browse for _carplay-ctrl._tcp on bridge100.
     * Browse fires immediately with cached results, but ctrl_connect_thread
     * re-resolves with kDNSServiceFlagsForceMulticast on each round,
     * so stale ports get refreshed automatically. */
    printf("[MDNS] Browsing for _carplay-ctrl._tcp on bridge100 (if=%u)...\n", br);
    DNSServiceRef browseRef = NULL;
    err = DNSServiceBrowse(&browseRef, 0, br,
                           "_carplay-ctrl._tcp", NULL,
                           browse_callback, NULL);
    if (err != kDNSServiceErr_NoError) {
        printf("[MDNS] Browse failed: %d\n", err);
    } else {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            while (1) {
                DNSServiceErrorType e = DNSServiceProcessResult(browseRef);
                if (e != kDNSServiceErr_NoError) {
                    printf("[MDNS] Browse error: %d\n", e);
                    break;
                }
            }
        });
    }

    printf("[SVC] All services running. Ctrl-C to stop.\n\n");
    while (1) sleep(60);
    return 0;
}
