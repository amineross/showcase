/*
 * carplay_services_v5.m — AirPlay receiver + mDNS for wireless CarPlay
 *
 * v5 changes (over v4):
 *  1. Added _raop._tcp mDNS service (CRITICAL — iPhone needs BOTH services)
 *  2. Fixed features bitmask for the software BAA-backed auth path.
 *  3. Added missing _airplay._tcp TXT fields: vv, acl, protovers
 *  4. Changed model from RoadLink1,1 to AppleTV3,2 (recognized model)
 *  5. Changed pi from MAC format to UUID format
 *  6. Removed non-standard 'seed' TXT field
 *  7. Added _raop._tcp TXT record (txtvers, ch, cn, da, et, md, etc.)
 *
 * Compile:
 *   clang -fobjc-arc -isysroot /tmp/iPhoneOS10.3.sdk \
 *         -o /tmp/carplay_services /tmp/carplay_services_v5.m \
 *         -framework Foundation
 *   ldid -S/tmp/ap_ent.xml /tmp/carplay_services
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
#include <sys/time.h>
#include <fcntl.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonCrypto.h>
#include <Security/Security.h>
#include <sys/un.h>
#include <signal.h>
#include "carplay_pair.h"

/* ── Forward declarations for IPC status events
 * (defined fully below near the IPC machinery, but used earlier in
 * pair-setup / pair-verify handlers). ── */
#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04
static void app_send_status(uint8_t code);

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

static void parse_args(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) {
            strncpy(g_instance_name, argv[i+1], sizeof(g_instance_name) - 1);
            g_instance_name[sizeof(g_instance_name) - 1] = '\0';
            snprintf(g_raop_name, sizeof(g_raop_name),
                     "%s@%s", DEVICE_ID_RAW, g_instance_name);
        }
        /* (other flags ignored; carplay_services only needs --name) */
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
#define FEATURES_WITH_HK   "0x44540380,0x61"
#define FEATURES_NO_HK     "0x44540380,0x21"

/* HK ON — bit 38 (HKPairingAndEncrypt). The newer Apple SDK unconditionally
 * sets this bit. iOS 18 may require it for CarPlay connections.
 * Without it, the iPhone may refuse to connect to port 7000. */
static bool g_useHK = true;

/* Global pairing context — initialized in main(), used by pair handlers */
static pair_ctx_t *g_pair = NULL;

/* ═══════════════════════════════════════════════════════════════
 * BAA Certificate (for auth-setup MFi-SAP response)
 * ═══════════════════════════════════════════════════════════════ */
static SecKeyRef  g_baa_key = NULL;
static uint8_t   *g_baa_leaf_der = NULL;
static int        g_baa_leaf_len = 0;
static uint8_t   *g_baa_inter_der = NULL;
static int        g_baa_inter_len = 0;
static bool       g_baa_ready = false;

static void issue_baa_cert(void) {
    printf("[BAA] Issuing certificate for auth-setup...\n");
    void *di = dlopen("/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity", RTLD_NOW);
    if (!di) di = dlopen("/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation", RTLD_NOW);
    if (!di) { printf("[BAA] Cannot load DeviceIdentity framework!\n"); return; }

    typedef void (^DIBlock)(id, id, id);
    typedef void (*DIFunc)(id, id, DIBlock);
    DIFunc fn = (DIFunc)dlsym(di, "DeviceIdentityIssueClientCertificateWithCompletion");
    if (!fn) { printf("[BAA] DeviceIdentityIssueClientCertificateWithCompletion not found!\n"); return; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    fn(nil, [NSDictionary dictionary], ^(id k, id c, id e) {
        if (e) { NSLog(@"[BAA] Error: %@", e); dispatch_semaphore_signal(sem); return; }
        NSArray *ca = (NSArray *)c;
        if ([ca count] < 2) { printf("[BAA] Not enough certs\n"); dispatch_semaphore_signal(sem); return; }

        g_baa_key = (SecKeyRef)CFBridgingRetain(k);

        CFDataRef d1 = SecCertificateCopyData((__bridge SecCertificateRef)ca[0]);
        g_baa_leaf_len = (int)CFDataGetLength(d1);
        g_baa_leaf_der = malloc(g_baa_leaf_len);
        memcpy(g_baa_leaf_der, CFDataGetBytePtr(d1), g_baa_leaf_len);
        CFRelease(d1);

        CFDataRef d2 = SecCertificateCopyData((__bridge SecCertificateRef)ca[1]);
        g_baa_inter_len = (int)CFDataGetLength(d2);
        g_baa_inter_der = malloc(g_baa_inter_len);
        memcpy(g_baa_inter_der, CFDataGetBytePtr(d2), g_baa_inter_len);
        CFRelease(d2);

        g_baa_ready = true;
        printf("[BAA] Leaf=%d Inter=%d — ready\n", g_baa_leaf_len, g_baa_inter_len);
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC));
    if (!g_baa_ready) printf("[BAA] Certificate issuance TIMED OUT\n");
}

/* ═══════════════════════════════════════════════════════════════
 * Encrypted Transport (ChaCha20-Poly1305) after pair-verify
 *
 * Frame format: [2-byte LE length][ciphertext][16-byte auth tag]
 * - The 2-byte length header is used as AAD
 * - 8-byte nonce counter (LE), starts at 0, increments per message
 * ═══════════════════════════════════════════════════════════════ */

#include <openssl/evp.h>

typedef struct {
    uint8_t readKey[32];
    uint8_t writeKey[32];
    uint64_t readNonce;
    uint64_t writeNonce;
    bool active;
} encrypted_ctx_t;

static encrypted_ctx_t g_enc = {0};
static encrypted_ctx_t g_event_enc = {0};

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
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { free(frame); return -1; }
    int ok = 1;
    int len = 0, pt_len = 0;

    ok &= (EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1);
    ok &= (EVP_DecryptInit_ex(ctx, NULL, NULL, enc->readKey, nonce12) == 1);
    /* AAD = 2-byte length header */
    ok &= (EVP_DecryptUpdate(ctx, NULL, &len, hdr, 2) == 1);
    /* Decrypt ciphertext */
    ok &= (EVP_DecryptUpdate(ctx, outBuf, &len, frame, ptLen) == 1);
    pt_len = len;
    /* Set auth tag */
    ok &= (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, frame + ptLen) == 1);
    int ret = EVP_DecryptFinal_ex(ctx, outBuf + pt_len, &len);
    EVP_CIPHER_CTX_free(ctx);
    free(frame);

    if (!ok || ret <= 0) {
        printf("[ENC] ChaCha20-Poly1305 decrypt FAILED (nonce=%llu)\n", enc->readNonce);
        return -1;
    }
    pt_len += len;
    enc->readNonce++;
    return pt_len;
}

/* Encrypt and send one frame.
 * Returns 0 on success, -1 on error. */
static int enc_send_frame(int sock, encrypted_ctx_t *enc, const uint8_t *data, size_t dataLen) {
    if (dataLen > 16384) {
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

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) { free(ct); return -1; }
    int ok = 1, len = 0, ct_len = 0;

    ok &= (EVP_EncryptInit_ex(ctx, EVP_chacha20_poly1305(), NULL, NULL, NULL) == 1);
    ok &= (EVP_EncryptInit_ex(ctx, NULL, NULL, enc->writeKey, nonce12) == 1);
    /* AAD = 2-byte length header */
    ok &= (EVP_EncryptUpdate(ctx, NULL, &len, hdr, 2) == 1);
    /* Encrypt plaintext */
    ok &= (EVP_EncryptUpdate(ctx, ct, &len, data, (int)dataLen) == 1);
    ct_len = len;
    ok &= (EVP_EncryptFinal_ex(ctx, ct + ct_len, &len) == 1);
    ct_len += len;
    ok &= (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, tag) == 1);
    EVP_CIPHER_CTX_free(ctx);

    if (!ok) { free(ct); return -1; }

    /* Send: header + ciphertext + tag */
    size_t totalLen = 2 + ct_len + 16;
    uint8_t *out = malloc(totalLen);
    if (!out) { free(ct); return -1; }
    memcpy(out, hdr, 2);
    memcpy(out + 2, ct, ct_len);
    memcpy(out + 2 + ct_len, tag, 16);
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

/* ═══════════════════════════════════════════════════════════════
 * HTTP Request Parser
 * ═══════════════════════════════════════════════════════════════ */

typedef struct {
    char method[16];
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
    const char *lineEnd = strstr(s, "\r\n");
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
    const char *bodyMark = strstr(lineEnd + 2, "\r\n\r\n");
    if (bodyMark) {
        r->headerLen = bodyMark - (const char *)r->headerStart;
        r->body = (const uint8_t *)(bodyMark + 4);
        r->bodyLen = (buf + len) - r->body;
    } else {
        r->headerLen = (buf + len) - (const uint8_t *)r->headerStart;
    }

    /* Parse key headers */
    const char *hp = (const char *)r->headerStart;
    const char *hend = hp + r->headerLen;
    while (hp < hend) {
        const char *le = strstr(hp, "\r\n");
        if (!le) break;
        const char *colon = memchr(hp, ':', le - hp);
        if (colon) {
            size_t nameLen = colon - hp;
            const char *val = colon + 1;
            while (val < le && *val == ' ') val++;
            size_t valLen = le - val;

            if (nameLen == 14 && strncasecmp(hp, "Content-Length", 14) == 0) {
                r->contentLength = (size_t)atol(val);
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
            /* Encrypted mode: build full response then encrypt as one frame */
            size_t totalPt = hLen + bodyLen;
            uint8_t *ptBuf = malloc(totalPt);
            if (ptBuf) {
                memcpy(ptBuf, h, hLen);
                if (body && bodyLen > 0) memcpy(ptBuf + hLen, body, bodyLen);
                printf("[ENC] Encrypting response: %zu bytes (nonce=%llu)\n", totalPt, g_enc.writeNonce);
                if (enc_send_frame(sock, &g_enc, ptBuf, totalPt) < 0) {
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

        uint64_t features = g_useHK ? 0x6144540380ULL : 0x2144540380ULL;

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

        info[@"keepAliveLowPower"] = @YES;
        info[@"keepAliveSendStatsAsBody"] = @YES;
        info[@"pi"] = @HK_PI;
        info[@"pk"] = hex_to_data(HK_PK);

        info[@"firmwareRevision"] = @"1.0.0";
        info[@"hardwareRevision"] = @"1.0";
        info[@"OSInfo"] = @"iPadOS 12.5.8";
        info[@"nightMode"] = @NO;
        info[@"rightHandDrive"] = @NO;
        info[@"extendedFeatures"] = @[@"vocoderInfo"];
        info[@"vehicleInformation"] = @{
            @"ElectronicTollCollection": @{ @"active": @NO }
        };
        info[@"limitedUI"] = @NO;

        /* Initial modes — tells iPhone which resources we want to claim.
         * Without this, iPhone doesn't know to set up screen/audio streams.
         * Reference: AirPlayCreateModesDictionary / kAirPlayProperty_Modes */
        info[@"modes"] = @{
            @"resources": @[
                @{  @"resourceID": @(1),       /* MainScreen */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(500), /* UserInitiated */
                    @"takeConstraint": @(100),   /* Anytime */
                    @"borrowConstraint": @(100)  /* Anytime */
                },
                @{  @"resourceID": @(2),       /* MainAudio */
                    @"transferType": @(1),      /* Take */
                    @"transferPriority": @(500), /* UserInitiated */
                    @"takeConstraint": @(100),
                    @"borrowConstraint": @(100)
                }
            ]
        };

        /* Display capabilities — CarPlay touchscreen */
        NSMutableDictionary *display = [NSMutableDictionary dictionary];
        display[@"uuid"] = @"e0ff8a27-6738-3d56-8a16-cc53ce1299b4";
        display[@"widthPixels"] = @800;
        display[@"heightPixels"] = @480;
        display[@"widthPhysical"] = @0;
        display[@"heightPhysical"] = @0;
        display[@"maxFPS"] = @30;
        /* Display feature bits (from reference):
         *   0x02 = Knobs
         *   0x04 = LowFidelityTouch
         *   0x08 = HighFidelityTouch (capacitive touchscreen)
         *   0x10 = Touchpad
         * Match simulator: Knobs + HighFidelityTouch + Touchpad = 0x1A */
        display[@"features"] = @(0x1A);
        display[@"primaryInputDevice"] = @(1);  /* 1=touchscreen */
        display[@"overscanned"] = @NO;
        info[@"displays"] = @[display];

        /* Audio formats — PCM and AAC-LC */
        NSDictionary *pcm = @{
            @"type": @(100),
            @"audioInputFormats": @(0x01000000),
            @"audioOutputFormats": @(0x01000000)
        };
        NSDictionary *aacLC = @{
            @"type": @(96),
            @"audioInputFormats": @(0x04000000),
            @"audioOutputFormats": @(0x04000000)
        };
        info[@"audioFormats"] = @[pcm, aacLC];

        NSDictionary *latency = @{
            @"type": @(100),
            @"audioType": @"default",
            @"inputLatencyMicros": @0,
            @"outputLatencyMicros": @0
        };
        info[@"audioLatencies"] = @[latency];

        info[@"initialVolume"] = @(-20.0);

        /* HID devices — single-finger touchscreen (Apple reference format).
         * Report = 5 bytes: [touch(1)][xLo][xHi][yLo][yHi]
         * Coordinates: absolute, 0-800 X, 0-480 Y */
        {
            static const uint8_t hidDesc[] = {
                0x05, 0x0D,        /* Usage Page (Digitizer) */
                0x09, 0x04,        /* Usage (Touch Screen) */
                0xA1, 0x01,        /* Collection (Application) */
                0x05, 0x0D,        /*   Usage Page (Digitizer) */
                0x09, 0x22,        /*   Usage (Finger) */
                0xA1, 0x02,        /*   Collection (Logical) */
                0x05, 0x0D,        /*     Usage Page (Digitizer) */
                0x09, 0x33,        /*     Usage (Touch) */
                0x15, 0x00,        /*     Logical Minimum (0) */
                0x25, 0x01,        /*     Logical Maximum (1) */
                0x75, 0x01,        /*     Report Size (1) */
                0x95, 0x01,        /*     Report Count (1) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x75, 0x07,        /*     Report Size (7) - padding */
                0x95, 0x01,        /*     Report Count (1) */
                0x81, 0x01,        /*     Input (Constant) */
                0x05, 0x01,        /*     Usage Page (Generic Desktop) */
                0x09, 0x30,        /*     Usage (X) */
                0x15, 0x00,        /*     Logical Minimum (0) */
                0x26, 0x20, 0x03,  /*     Logical Maximum (800) */
                0x75, 0x10,        /*     Report Size (16) */
                0x95, 0x01,        /*     Report Count (1) */
                0x81, 0x02,        /*     Input (Data, Variable, Absolute) */
                0x09, 0x31,        /*     Usage (Y) */
                0x15, 0x00,        /*     Logical Minimum (0) */
                0x26, 0xE0, 0x01,  /*     Logical Maximum (480) */
                0x75, 0x10,        /*     Report Size (16) */
                0x95, 0x01,        /*     Report Count (1) */
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

    /* Create pair context on first use.
     * The SRP state machine resets internally on each M1,
     * so we don't need to destroy/recreate the context. */
    if (!g_pair) {
        g_pair = pair_ctx_create(ed25519_sk, ed25519_pk, NULL);
    }

    if (!g_pair) {
        printf("[AP] ERROR: Failed to create pair context\n");
        send_response(sock, proto, 500, "Internal Error",
                     NULL, NULL, 0, r->cseq);
        return;
    }

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

    /* Use existing pair context (created during pair-setup) */
    if (!g_pair) {
        printf("[AP] WARNING: No pair context — creating fresh one for pair-verify\n");
        g_pair = pair_ctx_create(ed25519_sk, ed25519_pk, NULL);
    }

    if (!g_pair) {
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
        issue_baa_cert();
    }
    if (!g_baa_ready || !g_baa_key) {
        printf("[AP] auth-setup: BAA certificate unavailable\n");
        send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
        return;
    }

    /* Generate our Curve25519 keypair */
    EVP_PKEY_CTX *pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
    EVP_PKEY_keygen_init(pctx);
    EVP_PKEY *ourKey = NULL;
    EVP_PKEY_keygen(pctx, &ourKey);
    EVP_PKEY_CTX_free(pctx);

    uint8_t ourPK[32];
    size_t pkLen = 32;
    EVP_PKEY_get_raw_public_key(ourKey, ourPK, &pkLen);

    printf("[AP] auth-setup: our ECDH pk:");
    for (int i = 0; i < 32; i++) printf(" %02x", ourPK[i]);
    printf("\n");

    /* Compute ECDH shared secret */
    EVP_PKEY *peerKey = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, peerPK, 32);
    EVP_PKEY_CTX *dctx = EVP_PKEY_CTX_new(ourKey, NULL);
    EVP_PKEY_derive_init(dctx);
    EVP_PKEY_derive_set_peer(dctx, peerKey);
    uint8_t sharedSecret[32];
    size_t ssLen = 32;
    EVP_PKEY_derive(dctx, sharedSecret, &ssLen);
    EVP_PKEY_CTX_free(dctx);
    EVP_PKEY_free(peerKey);
    EVP_PKEY_free(ourKey);

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
        NSData *sigInput = [NSData dataWithBytes:digestData length:64];
        CFErrorRef cfErr = NULL;
        NSData *sig = (__bridge_transfer NSData *)SecKeyCreateSignature(
            g_baa_key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)sigInput, &cfErr);

        if (!sig) {
            NSLog(@"[AP] auth-setup: ECDSA sign FAILED: %@", cfErr);
            send_response(sock, proto, 403, "Forbidden", NULL, NULL, 0, r->cseq);
            return;
        }

        const uint8_t *sigBytes = (const uint8_t *)[sig bytes];
        size_t sigLen = [sig length];
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

/* Helper: bind a UDP socket to any port and return (fd, port) */
static int bind_udp_port(uint16_t *outPort) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    *outPort = ntohs(sa.sin_port);
    return fd;
}

/* Helper: bind a TCP listen socket to any port and return (fd, port) */
static int bind_tcp_port(uint16_t *outPort) {
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
    return fd;
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

/* Screen stream state */
static int      g_screen_listen_fd = -1;     /* TCP listen socket for screen data */
static uint16_t g_screen_data_port = 0;
static uint64_t g_screen_conn_id = 0;        /* streamConnectionID from SETUP Phase 2 */
static uint8_t  g_screen_key[32] = {0};      /* ChaCha20-Poly1305 decryption key */
static bool     g_screen_key_valid = false;

/* iPhone's timing port and IP — needed for server-initiated timing negotiation */
static uint16_t g_iphone_timing_port = 0;
static char     g_iphone_ip[64] = {0};
static int      g_rtsp_sock = -1;  /* current RTSP control socket, for getpeername */
static volatile int g_timing_sync_count = 0;  /* responses received during negotiation */

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
    struct timeval tv;
    gettimeofday(&tv, NULL);
    *sec  = (uint32_t)(tv.tv_sec + NTP_EPOCH_OFFSET);
    *frac = (uint32_t)((double)tv.tv_usec * 4294.967296);
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

        uint8_t pt = buf[1];

        if (pt == 210) {
            /* Timing request from iPhone — build response */
            printf("[TIMING] Received timing REQUEST (%zd bytes)\n", n);

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
            printf("[TIMING] Sent NTP response (%zd bytes)\n", sent);
        } else if (pt == 211) {
            /* Timing response from iPhone to our negotiation request */
            g_timing_sync_count++;
            printf("[TIMING] Received timing RESPONSE (pt=211) — sync #%d\n",
                   g_timing_sync_count);
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
        getnameinfo((struct sockaddr *)&ca, cl, host, sizeof(host),
                    serv, sizeof(serv), NI_NUMERICHOST | NI_NUMERICSERV);
        printf("[EVENT] *** Connection from %s:%s ***\n", host, serv);
        fflush(stdout);

        g_event_client_fd = client;

        /* TCP keepalive */
        int yes = 1;
        setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));

        /* Read loop — decrypt ChaCha20-Poly1305 framed messages */
        uint8_t buf[16384];
        struct timeval tv = { .tv_sec = 120, .tv_usec = 0 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        if (g_event_enc.active) {
            printf("[EVENT] Encrypted event channel active\n");
            fflush(stdout);
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
static bool g_screen_thread_running = false;

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

/* ── IPC to iPadPlay app via Unix socket ── */
#define IPADPLAY_SOCK "/tmp/ipadplay.sock"
#define MSG_VIDEO_CONFIG 0x01
#define MSG_VIDEO_FRAME  0x02
#define MSG_STATUS       0x04   /* services → app, 1 byte status code */
/* STATUS_* codes are forward-declared at the top of the file. */

static int g_app_sock = -1;
static void start_touch_reader(int fd);  /* forward declaration */

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

    return true;
}

static bool app_send_msg(uint8_t type, const uint8_t *data, uint32_t len) {
    if (!app_ensure_connected()) return false;
    uint8_t hdr[5] = {
        len & 0xFF, (len >> 8) & 0xFF,
        (len >> 16) & 0xFF, (len >> 24) & 0xFF, type
    };
    /* Send header */
    size_t sent = 0;
    while (sent < 5) {
        ssize_t n = write(g_app_sock, hdr + sent, 5 - sent);
        if (n <= 0) goto fail;
        sent += n;
    }
    /* Send payload */
    sent = 0;
    while (sent < len) {
        ssize_t n = write(g_app_sock, data + sent, len - sent);
        if (n <= 0) goto fail;
        sent += n;
    }
    return true;
fail:
    close(g_app_sock);
    g_app_sock = -1;
    return false;
}

/* ── Send a single-byte status update to the iPadPlay app (best-effort) ── */
static void app_send_status(uint8_t code) {
    app_send_msg(MSG_STATUS, &code, 1);
}

/* ── HID report sender — sends touch events to iPhone via event channel ── */
#define MSG_TOUCH 0x03
static int g_event_cmd_cseq = 10;
static dispatch_semaphore_t g_event_send_lock = NULL;

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
        [hdrStr appendFormat:@"CSeq: %d\r\n", g_event_cmd_cseq++];
        [hdrStr appendString:@"\r\n"];

        NSMutableData *msg = [NSMutableData dataWithBytes:hdrStr.UTF8String
                                                   length:strlen(hdrStr.UTF8String)];
        [msg appendData:plist];

        if (g_event_send_lock) dispatch_semaphore_wait(g_event_send_lock, DISPATCH_TIME_FOREVER);
        enc_send_frame(g_event_client_fd, &g_event_enc, msg.bytes, msg.length);
        if (g_event_send_lock) dispatch_semaphore_signal(g_event_send_lock);
    }
}

/* ── Touch reader thread — reads touch events from iPadPlay app via IPC ── */
static bool g_touch_reader_running = false;

static void touch_reader_func(void *arg) {
    int fd = (int)(intptr_t)arg;
    printf("[TOUCH] Reader started on fd=%d\n", fd);
    fflush(stdout);

    int touchCount = 0;

    while (1) {
        /* Read IPC header: [4 byte len LE][1 byte type] */
        uint8_t hdr[5];
        if (!tcp_read_exact(fd, hdr, 5)) break;

        uint32_t len = hdr[0] | (hdr[1]<<8) | (hdr[2]<<16) | (hdr[3]<<24);
        uint8_t type = hdr[4];

        if (type == MSG_TOUCH && len == 5) {
            uint8_t payload[5];
            if (!tcp_read_exact(fd, payload, 5)) break;

            uint8_t phase = payload[0];
            uint16_t x = payload[1] | (payload[2] << 8);
            uint16_t y = payload[3] | (payload[4] << 8);

            /* Map phase to HID button state */
            uint8_t buttons = (phase == 2) ? 0 : 1;  /* 0=down, 1=move → pressed; 2=up → released */

            /* Build HID report: [buttons][xLo][xHi][yLo][yHi] */
            uint8_t report[5];
            report[0] = buttons;
            report[1] = x & 0xFF;
            report[2] = x >> 8;
            report[3] = y & 0xFF;
            report[4] = y >> 8;

            send_hid_report(report, 5);

            touchCount++;
            if (touchCount <= 3 || touchCount % 100 == 0) {
                printf("[TOUCH] #%d: phase=%d x=%u y=%u → HID btn=%d\n",
                       touchCount, phase, x, y, buttons);
                fflush(stdout);
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
    printf("[SCREEN] Waiting for iPhone to connect on port %u (fd=%d)...\n",
           g_screen_data_port, g_screen_listen_fd);
    fflush(stdout);

    struct sockaddr_in peer;
    socklen_t peerLen = sizeof(peer);
    int clientFd = accept(g_screen_listen_fd, (struct sockaddr *)&peer, &peerLen);
    if (clientFd < 0) {
        printf("[SCREEN] ERROR: accept failed: %s\n", strerror(errno));
        fflush(stdout);
        return NULL;
    }
    close(g_screen_listen_fd);
    g_screen_listen_fd = -1;

    char peerIP[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &peer.sin_addr, peerIP, sizeof(peerIP));
    printf("[SCREEN] *** Connected from %s:%u ***\n", peerIP, ntohs(peer.sin_port));

    int rcvBuf = 512 * 1024;
    setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, sizeof(rcvBuf));

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

    while (1) {
        /* Read 128-byte header */
        if (!tcp_read_exact(clientFd, header, 128)) {
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
            if (!tcp_read_exact(clientFd, body, bodySize)) {
                printf("[SCREEN] Connection closed (body read, expected %u)\n", bodySize);
                break;
            }
        }

        totalBytes += 128 + bodySize;
        msgCount++;

        switch (opcode) {
            case 1: { /* VideoConfig — SPS/PPS (AVCC), display dimensions */
                float width = *(float *)(header + 8 + 8);   /* params[1].f32[0] */
                float height = *(float *)(header + 8 + 12);  /* params[1].f32[1] */
                printf("[SCREEN] VideoConfig: %.0fx%.0f, AVCC=%u bytes\n",
                       width, height, bodySize);

                /* Send config to iPadPlay app: [float width][float height][AVCC] */
                uint32_t msgLen = 8 + bodySize;
                uint8_t *msg = malloc(msgLen);
                memcpy(msg, &width, 4);
                memcpy(msg + 4, &height, 4);
                memcpy(msg + 8, body, bodySize);
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

                EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
                EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), NULL, NULL, NULL);
                EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, 12, NULL);
                EVP_DecryptInit_ex(ctx, NULL, NULL, g_screen_key, ietfNonce);

                /* AAD = 128-byte header */
                int outLen = 0;
                EVP_DecryptUpdate(ctx, NULL, &outLen, header, 128);

                /* Decrypt ciphertext in-place */
                EVP_DecryptUpdate(ctx, body, &outLen, body, ctLen);

                /* Set expected tag */
                EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, body + ctLen);

                int authOK = EVP_DecryptFinal_ex(ctx, body + outLen, &outLen);
                EVP_CIPHER_CTX_free(ctx);

                if (videoFrameCount <= 3) {
                    printf("[SCREEN] VideoFrame #%d: %u bytes ct, decrypt=%s, nonce=%llu\n",
                           videoFrameCount, ctLen, authOK > 0 ? "OK" : "FAIL", chachaNonce);
                    if (ctLen >= 8) {
                        printf("[SCREEN] Decrypted hex: ");
                        int dl = ctLen > 32 ? 32 : ctLen;
                        for (int i = 0; i < dl; i++) printf("%02x ", body[i]);
                        printf("...\n");
                    }
                    fflush(stdout);
                }

                chachaNonce++;

                if (authOK <= 0) break;

                /* Send decrypted frame to iPadPlay app */
                app_send_msg(MSG_VIDEO_FRAME, body, ctLen);
                break;
            }

            case 5: /* KeepAliveWithBody — encoder stats, ignore */
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
    if (g_app_sock >= 0) { close(g_app_sock); g_app_sock = -1; }
    close(clientFd);
    g_screen_thread_running = false;
    return NULL;
}

static void start_screen_thread(void) {
    if (g_screen_thread_running || g_screen_listen_fd < 0) return;
    g_screen_thread_running = true;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        screen_thread_func(NULL);
    });
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

    printf("[TIMING-NEG] Starting BLOCKING negotiation → %s:%u\n",
           g_iphone_ip, g_iphone_timing_port);
    fflush(stdout);

    struct sockaddr_in dest;
    memset(&dest, 0, sizeof(dest));
    dest.sin_family = AF_INET;
    dest.sin_port = htons(g_iphone_timing_port);
    if (inet_pton(AF_INET, g_iphone_ip, &dest.sin_addr) != 1) {
        printf("[TIMING-NEG] inet_pton failed for %s\n", g_iphone_ip);
        return false;
    }

    g_timing_sync_count = 0;

    /* Send 5 NTP requests with 100ms spacing, then wait for responses */
    for (int i = 0; i < 5; i++) {
        uint8_t pkt[32];
        memset(pkt, 0, 32);

        pkt[0] = 0x80;   /* version 2, no padding */
        pkt[1] = 0xD2;   /* packet type 210 = timing request */
        pkt[2] = 0x00;
        pkt[3] = 0x07;   /* length = 7 (8 words minus 1) */

        /* T3 (transmit) = our current NTP time */
        uint32_t sec, frac;
        get_ntp_time(&sec, &frac);
        pkt[24] = (sec >> 24) & 0xFF;
        pkt[25] = (sec >> 16) & 0xFF;
        pkt[26] = (sec >>  8) & 0xFF;
        pkt[27] = (sec >>  0) & 0xFF;
        pkt[28] = (frac >> 24) & 0xFF;
        pkt[29] = (frac >> 16) & 0xFF;
        pkt[30] = (frac >>  8) & 0xFF;
        pkt[31] = (frac >>  0) & 0xFF;

        ssize_t sent = sendto(g_timing_fd, pkt, 32, 0,
                              (struct sockaddr *)&dest, sizeof(dest));
        printf("[TIMING-NEG] Sent NTP request %d/5 (%zd bytes)\n", i + 1, sent);
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
                char host[NI_MAXHOST];
                getnameinfo((struct sockaddr *)&peerAddr, peerLen,
                           host, sizeof(host), NULL, 0, NI_NUMERICHOST);
                /* Strip ::ffff: prefix for IPv4-mapped IPv6 */
                const char *ip = host;
                if (strncmp(ip, "::ffff:", 7) == 0) ip += 7;
                snprintf(g_iphone_ip, sizeof(g_iphone_ip), "%s", ip);
                printf("[AP] iPhone IP: %s\n", g_iphone_ip);
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

            /* iPhone sent keepAliveLowPower=1 */
            if ([reqDict[@"keepAliveLowPower"] boolValue]) {
                respDict[@"keepAlivePort"] = @(g_keepalive_port);
            }

            printf("[AP] SETUP response: timingPort=%u eventPort=%u keepAlivePort=%u\n",
                   g_timing_port, g_event_port, g_keepalive_port);

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

                /* type 110 = screen/video (TCP), type 96 = main audio (UDP),
                 * type 100 = alt audio, others = UDP */
                if (type == 110) {
                    dataFd = bind_tcp_port(&dataPort);

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
                } else {
                    dataFd = bind_udp_port(&dataPort);
                }
                rs[@"dataPort"] = @(dataPort);

                /* For audio streams, also provide controlPort */
                if (type != 110) {
                    uint16_t ctrlPort = 0;
                    int ctrlFd = bind_udp_port(&ctrlPort);
                    rs[@"controlPort"] = @(ctrlPort);
                    /* Keep control fd alive — just log for now */
                    if (ctrlFd >= 0) {
                        printf("[AP] SETUP stream type=%d controlPort=%u (fd=%d, kept open)\n",
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

    /* ── Send requestUI on the encrypted event channel ──
     * The reference (AirPlayReceiverSessionRequestUI) sends a
     * POST /command with body {"type":"requestUI"} on the event channel
     * to tell the iPhone to start CarPlay UI streaming. Without this,
     * the iPhone doesn't know we want the CarPlay screen and tears down. */
    if (g_event_client_fd >= 0 && g_event_enc.active) {
        @autoreleasepool {
            /* Build the requestUI command plist */
            NSDictionary *cmd = @{ @"type": @"requestUI" };
            NSError *err = nil;
            NSData *plist = [NSPropertyListSerialization
                dataWithPropertyList:cmd
                              format:NSPropertyListBinaryFormat_v1_0
                             options:0
                               error:&err];
            if (plist) {
                /* Build HTTP POST request */
                NSMutableString *hdr = [NSMutableString string];
                [hdr appendString:@"POST /command RTSP/1.0\r\n"];
                [hdr appendFormat:@"Content-Length: %lu\r\n", (unsigned long)plist.length];
                [hdr appendString:@"Content-Type: application/x-apple-binary-plist\r\n"];
                [hdr appendString:@"CSeq: 1\r\n"];
                [hdr appendFormat:@"User-Agent: AirPlay/%s\r\n", SOURCE_VERSION];
                [hdr appendString:@"\r\n"];

                /* Concatenate header + body into one buffer */
                NSMutableData *msg = [NSMutableData dataWithBytes:hdr.UTF8String
                                                          length:strlen(hdr.UTF8String)];
                [msg appendData:plist];

                printf("[EVENT-CMD] Sending requestUI: %zu bytes\n", msg.length);
                fflush(stdout);

                int ret = enc_send_frame(g_event_client_fd, &g_event_enc,
                                         msg.bytes, msg.length);
                if (ret == 0) {
                    printf("[EVENT-CMD] *** requestUI sent successfully (nonce=%llu) ***\n",
                           g_event_enc.writeNonce - 1);
                } else {
                    printf("[EVENT-CMD] ERROR: Failed to send requestUI\n");
                }
                fflush(stdout);

                /* changeModes removed — initial modes are now in /info response.
                 * iPhone reads modes from /info to determine resource claims.
                 * changeModes is only for runtime mode changes after streams are set up. */
            } else {
                printf("[EVENT-CMD] ERROR: Failed to create requestUI plist: %s\n",
                       err.localizedDescription.UTF8String);
            }
        }
    } else {
        printf("[AP] WARNING: Cannot send requestUI — event fd=%d enc=%d\n",
               g_event_client_fd, g_event_enc.active);
    }
}

static void handle_teardown(int sock, const HTTPReq *r) {
    printf("[AP] -> TEARDOWN (CSeq=%d, bodyLen=%zu)\n", r->cseq, r->bodyLen);

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
            } else {
                printf("[AP] TEARDOWN hex (%zu):", r->bodyLen);
                size_t n = r->bodyLen > 256 ? 256 : r->bodyLen;
                for (size_t i = 0; i < n; i++) printf(" %02X", r->body[i]);
                printf("\n");
            }
        }
    }

    g_recording = false;

    send_response(sock, "RTSP/1.0", 200, "OK", NULL, NULL, 0, r->cseq);
    printf("[AP] Session torn down.\n");
    fflush(stdout);
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

static void handle_client(int c) {
    uint8_t buf[65536];
    size_t bufUsed = 0;

    /* Set recv timeout — must be long enough for iPhone to send SETUP Phase 2
     * after RECORD. Keepalive channel handles liveness detection. */
    struct timeval tv = { .tv_sec = 600, .tv_usec = 0 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* TCP keepalive */
    int yes = 1;
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));

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

            /* Parse decrypted plaintext as HTTP/RTSP */
            HTTPReq r;
            if (parse_http(ptBuf, ptLen, &r)) {
                if (r.contentLength == 0 || r.bodyLen >= r.contentLength) {
                    /* Route using encrypted send */
                    printf("\n[AP] ── %s %s %s (encrypted) ──\n", r.method, r.path, r.protocol);
                    fflush(stdout);

                    /* Temporarily swap send_response for encrypted sends */
                    bool rtsp = (strncmp(r.protocol, "RTSP", 4) == 0);
                    const char *proto = rtsp ? "RTSP/1.0" : "HTTP/1.1";

                    if (strcasecmp(r.method, "GET") == 0 && strstr(r.path, "/info")) {
                        handle_info(c, &r);
                    } else if (strcasecmp(r.method, "POST") == 0) {
                        if (strstr(r.path, "/pair-setup"))
                            handle_pair_setup(c, &r);
                        else if (strstr(r.path, "/pair-verify"))
                            handle_pair_verify(c, &r);
                        else if (strstr(r.path, "/fp-setup"))
                            handle_fp_setup(c, &r);
                        else if (strstr(r.path, "/auth-setup"))
                            handle_auth_setup(c, &r);
                        else
                            handle_post_generic(c, &r);
                    } else if (strcasecmp(r.method, "SETUP") == 0) {
                        handle_rtsp_setup(c, &r);
                    } else if (strcasecmp(r.method, "RECORD") == 0) {
                        handle_record(c, &r);
                    } else if (strcasecmp(r.method, "TEARDOWN") == 0) {
                        handle_teardown(c, &r);
                    } else if (strcasecmp(r.method, "OPTIONS") == 0) {
                        handle_options(c, &r);
                    } else {
                        handle_rtsp_generic(c, &r);
                    }
                    fflush(stdout);
                } else {
                    printf("[ENC] Incomplete body (have %zu, need %zu)\n",
                           r.bodyLen, r.contentLength);
                }
            } else {
                printf("[ENC] Could not parse decrypted data as HTTP/RTSP\n");
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

        /* Check if we have the full body */
        if (r.contentLength > 0 && r.bodyLen < r.contentLength) {
            /* Need more body data */
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
    close(c);
    printf("[AP] Connection closed\n");
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
            getnameinfo((struct sockaddr *)&ca, cl, host, sizeof(host),
                        serv, sizeof(serv), NI_NUMERICHOST | NI_NUMERICSERV);
            printf("\n[AP] *** NEW CONNECTION from %s:%s ***\n", host, serv);
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
        return -1;
    }

    for (const struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;

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
                getsockopt(s, SOL_SOCKET, SO_ERROR, &serr, &slen);
                if (serr == 0) ret = 0;
                else { errno = serr; ret = -1; }
            } else {
                errno = ETIMEDOUT;
                ret = -1;
            }
        }

        /* Restore blocking mode */
        fcntl(s, F_SETFL, flags);

        if (ret == 0) {
            printf("[CTRL] Connected %s:%s\n", addrStr, portS);
            freeaddrinfo(res);
            return s;
        }
        if (verbose)
            printf("[CTRL] Failed: %s\n", strerror(errno));
        close(s);
    }
    freeaddrinfo(res);
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
            sleep(5); waitSecs += 5;
            if (waitSecs % 30 == 0)
                printf("[CTRL] Still waiting for iPhone... (%ds)\n", waitSecs);
            continue;
        }

        /* Silent probe — 3s timeout, no log spam */
        int sock = try_connect(rr.host, rr.port, g_ctrlIfIndex, false, 3);
        if (sock >= 0) {
            /* Connected on first probe! */
            ctrl_send_connect(sock, rr.host);
            return;
        }

        if (errno == ECONNREFUSED) {
            /* iPhone IS on the network (TCP RST = host reachable).
             * This port is stale — move to Phase 2 with re-resolve. */
            printf("[CTRL] iPhone is online! (port %u stale, re-resolving)\n",
                   (unsigned)rr.port);
            break;
        }

        /* EHOSTDOWN / ETIMEDOUT / EHOSTUNREACH — not on network yet */
        sleep(8); waitSecs += 8;
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

            if (i == 1 || i % 5 == 0 || apErr || raopErr) {
                printf("[MDNS] Reannounce tick %d/%d: airplay=%d raop=%d\n",
                       i, ticks, apErr, raopErr);
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
    g_event_send_lock = dispatch_semaphore_create(1);

    printf("[SVC] CarPlay Network Services v5.1 (real Ed25519 pk, no HK)\n");
    printf("[SVC] DeviceID:  %s\n", DEVICE_ID);
    printf("[SVC] Features:  %s\n", g_useHK ? FEATURES_WITH_HK : FEATURES_NO_HK);
    printf("[SVC] Model:     %s\n", MODEL_NAME);
    printf("[SVC] srcvers:   %s\n", SOURCE_VERSION);
    printf("[SVC] HK:        %s\n", g_useHK ? "YES" : "NO");
    printf("[SVC] RAOP name: %s\n", g_raop_name);
    printf("[SVC] pi:        %s\n", HK_PI);
    printf("[SVC] pk:        %s\n", HK_PK);
    printf("[SVC] Ed25519:   REAL keypair (sk stored for pair-verify)\n");

    /* Issue BAA certificate for auth-setup */
    issue_baa_cert();

    /* Resolve bridge100 */
    unsigned int br = if_nametoindex("bridge100");
    if (br == 0) {
        printf("[SVC] FATAL: bridge100 not found! Is the hotspot active?\n");
        return 1;
    }
    printf("[SVC] bridge100 ifIndex = %u\n", br);

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
