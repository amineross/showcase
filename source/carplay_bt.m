/*
 * carplay_bt40.m — iPadPlay v40+ss
 *
 * v40+ss3 = v40 + undeclared 0x4301 attempt (kept as harmless fallback)
 *
 * Strategy: Identification unchanged from working v40. 0x4300/0x4301 cannot
 * be declared on iOS 18 (both cause IdentificationRejected). 0x4301 is sent
 * undeclared after 0x4E0E — may be ignored by iPhone but costs nothing.
 * The REAL fix is likely on the AirPlay/Bonjour side (features, flags, etc).
 *
 * The theory (from CarPlay Simulator RE): the iPhone waits for a higher-layer
 * CarPlay start-session message carrying the receiver's IP, port 7000,
 * device ID, public key, and source version before it connects to AirPlay.
 *
 * Changes from v40:
 *   1. Added send_carplay_start_session() — sends 0x4301 with WirelessAttributes
 *      group (SSID, passphrase, channel, IPv6 address) + port + deviceid + pk + srcvers.
 *   2. Triggered after 0x4E0E (DeviceTransportIdentifierNotification).
 *   3. Also handles inbound 0x4300 (CarPlayAvailability) even though undeclared.
 *   4. Identification adds 0x4300 to msgs_recv (+2 bytes) but NOT 0x4301 to msgs_sent.
 *
 * Compile:
 *   clang -fobjc-arc -o /tmp/carplay_bt40 /tmp/carplay_bt40.m \
 *         -L/usr/lib -lBTstack -framework Foundation -framework Security
 *   ldid -S/tmp/cp23_ent.xml /tmp/carplay_bt40
 *
 * Run:
 *   sh /tmp/reset.sh && sleep 2 && /tmp/carplay_bt40
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <time.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>

/* ══════════════════════════════════════════════════
 *  Configuration — populated from argv at startup.
 *  CLI args:  --name <car>   --ssid <hotspot>   --pass <password>
 *  Defaults are kept in case the binary is run standalone.
 * ══════════════════════════════════════════════════ */
static char kDeviceName[32]    = "RoadLink";
static char kWifiSSID[64]      = "RoadLink-CarPlay";
static char kWifiPassword[64]  = "roadlink1234";
static const uint8_t kWifiSecurityType = 2;   /* 0=None, 1=WEP, 2=WPA/WPA2 */
static const uint8_t kWifiChannel      = 1;   /* iPad hotspot is on channel 1 */
/* AP BSSID (ap1 MAC — locally administered version of WiFi MAC) */
static const uint8_t kApBSSID[6] = { 0xB2, 0xB9, 0x31, 0xAC, 0x86, 0x9F };

static void parse_args(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) {
            strncpy(kDeviceName, argv[i+1], sizeof(kDeviceName) - 1);
            kDeviceName[sizeof(kDeviceName) - 1] = '\0';
        } else if (!strcmp(argv[i], "--ssid") || !strcmp(argv[i], "-s")) {
            strncpy(kWifiSSID, argv[i+1], sizeof(kWifiSSID) - 1);
            kWifiSSID[sizeof(kWifiSSID) - 1] = '\0';
        } else if (!strcmp(argv[i], "--pass") || !strcmp(argv[i], "-p")) {
            strncpy(kWifiPassword, argv[i+1], sizeof(kWifiPassword) - 1);
            kWifiPassword[sizeof(kWifiPassword) - 1] = '\0';
        }
    }
}

/* ══════════════════════════════════════════════════
 *  AirPlay receiver identity — must match carplay_services_v5.m
 * ══════════════════════════════════════════════════ */
static const char *kAirPlayDeviceId    = "90:B9:31:AC:86:A0";
static const char *kAirPlayPublicKey   = "1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f";
static const char *kAirPlaySourceVer   = "280.33.8";
static const uint32_t kAirPlayPort     = 7000;
static const char *kWifiInterface      = "bridge100";

/* ── BTstack API ── */
typedef uint8_t bd_addr_t[6];
extern int  bt_open(void);
extern int  bt_send_cmd(const void *cmd, ...);
extern int  bt_send_rfcomm(uint16_t cid, uint8_t *data, uint16_t len);
extern void bt_register_packet_handler(void(*)(uint8_t,uint16_t,uint8_t*,uint16_t));
extern void run_loop_init(int);
extern void run_loop_execute(void);

extern const void *btstack_set_power_mode, *btstack_set_discoverable;
extern const void *btstack_set_system_bluetooth_enabled;
extern const void *hci_write_local_name, *hci_write_class_of_device;
extern const void *hci_write_extended_inquiry_response, *hci_write_simple_pairing_mode;
extern const void *hci_accept_connection_request;
extern const void *hci_io_capability_request_reply, *hci_user_confirmation_request_reply;
extern const void *rfcomm_register_service, *rfcomm_accept_connection;
extern const void *sdp_register_service_record;
extern const void *hci_read_bd_addr;

#define R16(b,p) (((uint16_t)(b)[(p)+1])<<8|(b)[(p)])

/* ── Globals ── */
static uint8_t sdp_rec[512];
static uint8_t did_sdp_rec[256];
static int setup_done = 0;
static uint16_t active_cid = 0;
static uint16_t rfcomm_mtu = 1007;
static int iap2_detected = 0, link_established = 0, detect_count = 0;
static uint8_t my_initial_psn = 0, my_next_psn = 0, peer_psn = 0;

/* ── Local BT address ── */
static uint8_t local_bd_addr[6] = {0};
static int have_local_addr = 0;

/* ── BAA state ── */
static SecKeyRef baa_private_key = NULL;
static uint8_t *baa_leaf_der = NULL, *baa_inter_der = NULL;
static int baa_leaf_len = 0, baa_inter_len = 0, baa_ready = 0;

static uint8_t iap2_detect[] = { 0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10 };

/* ── State tracking ── */
static int wifi_config_sent = 0;
static int start_session_sent = 0;
static int transport_notification_seen = 0;
static char wifi_ipv6[INET6_ADDRSTRLEN] = "";
static int packet_debug_count = 0;

/* ═══════════════════════════════════════════════
 *  Parameter builder
 * ═══════════════════════════════════════════════ */
typedef struct { uint8_t *buf; int off, cap; } PB;

static void pb_init(PB *pb, int cap) { pb->buf = malloc(cap); pb->off = 0; pb->cap = cap; }
static void pb_ensure(PB *pb, int n) {
    while (pb->off + n > pb->cap) { pb->cap *= 2; pb->buf = realloc(pb->buf, pb->cap); }
}
static void pb_free(PB *pb) { free(pb->buf); }

/* NUL-terminated UTF-8 string (iAP2 spec encoding) */
static void pb_utf8(PB *pb, uint16_t id, const char *s) {
    int sl = (int)strlen(s) + 1;   /* +1 for NUL terminator */
    int pl = 4 + sl;
    pb_ensure(pb, pl);
    pb->buf[pb->off++] = (pl >> 8) & 0xFF;
    pb->buf[pb->off++] =  pl       & 0xFF;
    pb->buf[pb->off++] = (id >> 8) & 0xFF;
    pb->buf[pb->off++] =  id       & 0xFF;
    memcpy(&pb->buf[pb->off], s, sl - 1);
    pb->buf[pb->off + sl - 1] = 0x00;
    pb->off += sl;
}

static void pb_utf8_list(PB *pb, uint16_t id, const char * const *items, int n, int extra_final_nul) {
    int dl = extra_final_nul ? 1 : 0;
    for (int i = 0; i < n; i++) dl += (int)strlen(items[i]) + 1;
    int pl = 4 + dl;
    pb_ensure(pb, pl);
    pb->buf[pb->off++] = (pl >> 8) & 0xFF;
    pb->buf[pb->off++] =  pl       & 0xFF;
    pb->buf[pb->off++] = (id >> 8) & 0xFF;
    pb->buf[pb->off++] =  id       & 0xFF;
    for (int i = 0; i < n; i++) {
        int sl = (int)strlen(items[i]);
        memcpy(&pb->buf[pb->off], items[i], sl);
        pb->off += sl;
        pb->buf[pb->off++] = 0x00;
    }
    if (extra_final_nul) pb->buf[pb->off++] = 0x00;
}

static void pb_u8(PB *pb, uint16_t id, uint8_t v) {
    pb_ensure(pb, 5);
    pb->buf[pb->off++]=0; pb->buf[pb->off++]=5;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
    pb->buf[pb->off++]=v;
}
static void pb_u16(PB *pb, uint16_t id, uint16_t v) {
    pb_ensure(pb, 6);
    pb->buf[pb->off++]=0; pb->buf[pb->off++]=6;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
    pb->buf[pb->off++]=(v>>8); pb->buf[pb->off++]=v&0xFF;
}
static void pb_u32(PB *pb, uint16_t id, uint32_t v) {
    pb_ensure(pb, 8);
    pb->buf[pb->off++]=0; pb->buf[pb->off++]=8;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
    pb->buf[pb->off++]=(v>>24)&0xFF; pb->buf[pb->off++]=(v>>16)&0xFF;
    pb->buf[pb->off++]=(v>>8)&0xFF;  pb->buf[pb->off++]=v&0xFF;
}
static void pb_none(PB *pb, uint16_t id) {
    pb_ensure(pb, 4);
    pb->buf[pb->off++]=0; pb->buf[pb->off++]=4;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
}
static void pb_blob(PB *pb, uint16_t id, const uint8_t *d, int dl) {
    int pl=4+dl; pb_ensure(pb, pl);
    pb->buf[pb->off++]=(pl>>8); pb->buf[pb->off++]=pl&0xFF;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
    memcpy(&pb->buf[pb->off], d, dl); pb->off += dl;
}
static void pb_u16arr(PB *pb, uint16_t id, const uint16_t *v, int n) {
    int dl=n*2, pl=4+dl; pb_ensure(pb, pl);
    pb->buf[pb->off++]=(pl>>8); pb->buf[pb->off++]=pl&0xFF;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF;
    for (int i=0;i<n;i++) { pb->buf[pb->off++]=(v[i]>>8); pb->buf[pb->off++]=v[i]&0xFF; }
}
static int pb_grp_begin(PB *pb, uint16_t id) {
    pb_ensure(pb, 4); int lo=pb->off; pb->off+=2;
    pb->buf[pb->off++]=(id>>8); pb->buf[pb->off++]=id&0xFF; return lo;
}
static void pb_grp_end(PB *pb, int lo) {
    int t=pb->off-lo; pb->buf[lo]=(t>>8); pb->buf[lo+1]=t&0xFF;
}

/* ═══════════════════════════════════════════════
 *  BAA cert issuance
 * ═══════════════════════════════════════════════ */
static void issue_baa_cert(void) {
    printf("[BAA] Issuing certificate...\n");
    void *di = dlopen("/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity", RTLD_NOW);
    if (!di) di = dlopen("/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation", RTLD_NOW);
    if (!di) { printf("[BAA] Cannot load framework!\n"); return; }
    typedef void (^DIBlock)(id, id, id);
    typedef void (*DIFunc)(id, id, DIBlock);
    DIFunc fn = (DIFunc)dlsym(di, "DeviceIdentityIssueClientCertificateWithCompletion");
    if (!fn) { printf("[BAA] No issuance func!\n"); return; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    fn(nil, [NSDictionary dictionary], ^(id k, id c, id e) {
        if (e) { NSLog(@"[BAA] Error: %@", e); dispatch_semaphore_signal(sem); return; }
        NSArray *ca = (NSArray *)c;
        if ([ca count] < 2) { dispatch_semaphore_signal(sem); return; }
        baa_private_key = (SecKeyRef)CFBridgingRetain(k);
        CFDataRef d1 = SecCertificateCopyData((__bridge SecCertificateRef)ca[0]);
        baa_leaf_len = (int)CFDataGetLength(d1);
        baa_leaf_der = malloc(baa_leaf_len); memcpy(baa_leaf_der, CFDataGetBytePtr(d1), baa_leaf_len);
        CFRelease(d1);
        CFDataRef d2 = SecCertificateCopyData((__bridge SecCertificateRef)ca[1]);
        baa_inter_len = (int)CFDataGetLength(d2);
        baa_inter_der = malloc(baa_inter_len); memcpy(baa_inter_der, CFDataGetBytePtr(d2), baa_inter_len);
        CFRelease(d2);
        baa_ready = 1;
        printf("[BAA] Leaf=%d Inter=%d — ready\n", baa_leaf_len, baa_inter_len);
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC));
}

/* ═══════════════════════════════════════════════
 *  EIR / SDP / DID
 * ═══════════════════════════════════════════════ */
static void build_eir(uint8_t *e) {
    int p=0; memset(e,0,240);
    e[p++]=2; e[p++]=0x01; e[p++]=0x06;
    e[p++]=33; e[p++]=0x07;
    uint8_t c[]={0xD3,0x1F,0xBF,0x50,0x5D,0x57,0x27,0x97,0xA2,0x40,0x41,0xCD,0x48,0x43,0x88,0xEC};
    memcpy(&e[p],c,16); p+=16;
    uint8_t a[]={0xFF,0xCA,0xCA,0xDE,0xAF,0xDE,0xCA,0xDE,0xDE,0xFA,0xCA,0xDE,0x00,0x00,0x00,0x00};
    memcpy(&e[p],a,16); p+=16;
    /* Complete Local Name: TLV [length=1+nameLen] [type=0x09] [name bytes] */
    {
        uint8_t nameLen = (uint8_t)strlen(kDeviceName);
        if (nameLen > 30) nameLen = 30; /* keep EIR under 240 */
        e[p++] = 1 + nameLen;
        e[p++] = 0x09;
        memcpy(&e[p], kDeviceName, nameLen);
        p += nameLen;
    }
    e[p++]=2; e[p++]=0x0A; e[p++]=0;
}

static int build_sdp(uint8_t *r, int ch) {
    int p=0;
    r[p++]=0x36; int lp=p; p+=2;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x00;
    r[p++]=0x0A; r[p++]=0; r[p++]=1; r[p++]=0; r[p++]=1;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x01;
    r[p++]=0x35; r[p++]=17; r[p++]=0x1C;
    uint8_t u[]={0x00,0x00,0x00,0x00,0xDE,0xCA,0xFA,0xDE,0xDE,0xCA,0xDE,0xAF,0xDE,0xCA,0xCA,0xFF};
    memcpy(&r[p],u,16); p+=16;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x04;
    r[p++]=0x35; r[p++]=12;
    r[p++]=0x35; r[p++]=3; r[p++]=0x19; r[p++]=0x01; r[p++]=0x00;
    r[p++]=0x35; r[p++]=5; r[p++]=0x19; r[p++]=0x00; r[p++]=0x03;
    r[p++]=0x08; r[p++]=(uint8_t)ch;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x05;
    r[p++]=0x35; r[p++]=3; r[p++]=0x19; r[p++]=0x10; r[p++]=0x02;
    r[p++]=0x09; r[p++]=0x01; r[p++]=0x00;
    r[p++]=0x25; r[p++]=12; memcpy(&r[p],"Wireless iAP",12); p+=12;
    int t=p-3; r[lp]=(t>>8)&0xFF; r[lp+1]=t&0xFF;
    return p;
}

static int build_did_sdp(uint8_t *r) {
    int p = 0;
    r[p++] = 0x36; int lp = p; p += 2;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x00;
    r[p++]=0x0A; r[p++]=0x00; r[p++]=0x01; r[p++]=0x00; r[p++]=0x02;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x01;
    r[p++]=0x35; r[p++]=3; r[p++]=0x19; r[p++]=0x12; r[p++]=0x00;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x00;
    r[p++]=0x09; r[p++]=0x01; r[p++]=0x03;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x01;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0xD1;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x02;
    r[p++]=0x09; r[p++]=0x01; r[p++]=0x00;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x03;
    r[p++]=0x09; r[p++]=0x01; r[p++]=0x00;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x04;
    r[p++]=0x28; r[p++]=0x01;
    r[p++]=0x09; r[p++]=0x02; r[p++]=0x05;
    r[p++]=0x09; r[p++]=0x00; r[p++]=0x02;
    int t = p - 3;
    r[lp] = (t >> 8) & 0xFF; r[lp+1] = t & 0xFF;
    printf("[DID] SDP record: %d bytes (DID 1.3, Version=1.0.0)\n", p);
    return p;
}

/* ═══════════════════════════════════════════════
 *  iAP2 link helpers
 * ═══════════════════════════════════════════════ */
static uint8_t ck(uint8_t *d, int l) {
    uint8_t s=0; for(int i=0;i<l;i++) s+=d[i]; return 0x100-s;
}

static void rfcomm_send_chunked(uint8_t *data, int len) {
    int s=0;
    while(s<len) {
        int c=len-s; if(c>rfcomm_mtu) c=rfcomm_mtu;
        int rc=bt_send_rfcomm(active_cid,&data[s],c); s+=c;
        if(rc!=c) usleep(50000);
    }
}

static void send_ack(void) {
    uint8_t p[9]={0xFF,0x5A,0x00,0x09,0x40,my_next_psn,peer_psn,0x00,0};
    p[8]=ck(p,8);
    bt_send_rfcomm(active_cid,p,9);
}

static void send_syn(void) {
    uint8_t payload[] = {
        0x01, 0x05, 0x08, 0x00, 0x05, 0xDC, 0x00, 0x49,
        0x1E, 0x03,
        0x01, 0x00, 0x02,   /* Session 1: Control, version 2 */
        0x03, 0x02, 0x01,   /* Session 3: ExternalAccessory, version 1 */
    };
    int pl=sizeof(payload), total=9+pl+1;
    uint8_t p[64];
    p[0]=0xFF;p[1]=0x5A;p[2]=(total>>8);p[3]=(total&0xFF);
    p[4]=0x80;p[5]=my_initial_psn;p[6]=0x00;p[7]=0x00;p[8]=ck(p,8);
    memcpy(&p[9],payload,pl); p[9+pl]=ck(&p[9],pl);
    printf("[SYN] psn=0x%02x\n",my_initial_psn);
    bt_send_rfcomm(active_cid,p,total);
}

static void send_control_msg(uint16_t msg_id, uint8_t *params, int params_len) {
    int ml=6+params_len;
    uint8_t *msg=malloc(ml);
    msg[0]=0x40;msg[1]=0x40;msg[2]=(ml>>8);msg[3]=(ml&0xFF);
    msg[4]=(msg_id>>8);msg[5]=(msg_id&0xFF);
    if(params_len>0) memcpy(&msg[6],params,params_len);
    int total=9+ml+1;
    uint8_t *pkt=malloc(total);
    pkt[0]=0xFF;pkt[1]=0x5A;pkt[2]=(total>>8);pkt[3]=(total&0xFF);
    pkt[4]=0x40;pkt[5]=my_next_psn;pkt[6]=peer_psn;
    pkt[7]=0x01;  /* control session ID = 1 */
    pkt[8]=ck(pkt,8);
    memcpy(&pkt[9],msg,ml); pkt[9+ml]=ck(&pkt[9],ml);
    printf("[TX] msg=0x%04X len=%d seq=0x%02X ack=0x%02X sess=1\n",msg_id,total,my_next_psn,peer_psn);
    my_next_psn++;
    rfcomm_send_chunked(pkt,total);
    free(msg); free(pkt);
}

/* ═══════════════════════════════════════════════
 *  Auth
 * ═══════════════════════════════════════════════ */
static void send_auth_cert(void) {
    if(!baa_ready) return;
    PB pb; pb_init(&pb,2048);
    pb_blob(&pb,0x0000,baa_leaf_der,baa_leaf_len);
    pb_u8(&pb,0x0001,1);
    pb_blob(&pb,0x0002,baa_inter_der,baa_inter_len);
    send_control_msg(0xAA01,pb.buf,pb.off); pb_free(&pb);
}

static void send_auth_response(uint8_t *chal, int clen) {
    if(!baa_private_key) return;
    @autoreleasepool {
        NSData *cd=[NSData dataWithBytes:chal length:clen];
        CFErrorRef err=NULL;
        NSData *sig=(__bridge_transfer NSData*)SecKeyCreateSignature(
            baa_private_key,kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)cd,&err);
        if(!sig){NSLog(@"[AA03] Sign FAIL: %@",err); return;}
        printf("[AA03] Sig: %lu bytes\n",(unsigned long)[sig length]);
        PB pb; pb_init(&pb,256);
        pb_blob(&pb,0x0000,[sig bytes],(int)[sig length]);
        send_control_msg(0xAA03,pb.buf,pb.off); pb_free(&pb);
    }
}

/* ═══════════════════════════════════════════════
 *  0x5703: AccessoryWiFiConfigurationInformation
 *
 *  v37: Added BSSID param so iPhone knows which AP to join
 *    Param 0x0001 = SSID (UTF-8 + NUL)
 *    Param 0x0002 = Passphrase (UTF-8 + NUL)
 *    Param 0x0003 = SecurityType (1 byte enum)
 *    Param 0x0004 = Channel (1 byte)
 *    Param 0x0005 = AccessoryBSSID (6 bytes, AP MAC)
 * ═══════════════════════════════════════════════ */
static void send_accessory_wifi_config(void) {
    PB pb; pb_init(&pb, 256);

    /* Param 1: SSID — NUL-terminated UTF-8 */
    pb_utf8(&pb, 0x0001, kWifiSSID);

    /* Param 2: Passphrase — NUL-terminated UTF-8 */
    pb_utf8(&pb, 0x0002, kWifiPassword);

    /* Param 3: SecurityType — 1 byte (0=None, 1=WEP, 2=WPA/WPA2) */
    pb_u8(&pb, 0x0003, kWifiSecurityType);

    /* Param 4: Channel — 1 byte */
    pb_u8(&pb, 0x0004, kWifiChannel);

    /* v38: REMOVED BSSID param (0x0005) — not in wiomoc reference impl.
     * iPhone may reject messages with unexpected/unknown params. */

    printf("[WIFI] Sending 0x5703: SSID=\"%s\" PASS=****** SEC=%d CH=%d\n",
           kWifiSSID, kWifiSecurityType, kWifiChannel);
    printf("[WIFI]   (no BSSID param — matching wiomoc reference)\n");

    printf("[WIFI] Payload redacted (%d bytes, contains hotspot credentials)\n", pb.off);

    send_control_msg(0x5703, pb.buf, pb.off);
    pb_free(&pb);
    wifi_config_sent = 1;
}

/* ═══════════════════════════════════════════════
 *  0x1D01: IdentificationInformation
 *  v39: CRITICAL FIX — match wiomoc reference impl message lists
 *       REMOVED 0x4300/0x4301 (consent-based CarPlay — wrong path!)
 *       ADDED vehicle status + EAP messages per wiomoc
 * ═══════════════════════════════════════════════ */
static void send_identification_info(void) {
    printf("[ID] Building IdentificationInformation (v40 — unchanged)...\n");
    PB pb; pb_init(&pb, 2048);

    pb_utf8(&pb, 0x0000, kDeviceName);
    pb_utf8(&pb, 0x0001, "RL-100");
    pb_utf8(&pb, 0x0002, "RoadLink Labs");
    pb_utf8(&pb, 0x0003, "RL100-0001");
    pb_utf8(&pb, 0x0004, "1.0");
    pb_utf8(&pb, 0x0005, "1.0");

    /* msgs_sent: what WE send to the iPhone
     * NOTE: 0x4301 (CarPlayStartSession) intentionally NOT declared here.
     * iPhone 16 Pro / iOS 18 rejects identification if 0x4301 is in msgs_sent.
     * We still SEND 0x4301 as an undeclared message after the handshake. */
    static const uint16_t msgs_sent[] = {
        0xAA01, 0xAA03,             /* Auth cert + response */
        0x4E01,                     /* BluetoothComponentInformation */
        0x5703,                     /* AccessoryWiFiConfigurationInformation */
        0xEA03,                     /* StatusExternalAccessoryProtocolSession */
    };
    pb_u16arr(&pb, 0x0006, msgs_sent, 5);

    /* msgs_recv: what we ACCEPT from iPhone
     * v40: added 0xEA00/0xEA01 (EAP session start/stop).
     * NOTE: 0x4300 CANNOT be added here — iPhone validates 0x4300/0x4301 as a
     *       mandatory pair and rejects msgs_sent if 0x4301 is missing. And
     *       0x4301 in msgs_sent is also rejected. So the entire 0x43xx path
     *       is blocked on iOS 18+. */
    static const uint16_t msgs_recv[] = {
        0xAA00, 0xAA02, 0xAA04, 0xAA05,  /* Auth flow */
        0x5702,                            /* RequestAccessoryWiFiConfigInfo */
        0x4E0B,                            /* DeviceTimeUpdate */
        0x4E0D,                            /* WirelessCarPlayUpdate */
        0x4E0E,                            /* DeviceTransportIdentifierNotification */
        0xEA00,                            /* StartExternalAccessoryProtocolSession */
        0xEA01,                            /* StopExternalAccessoryProtocolSession */
    };
    pb_u16arr(&pb, 0x0007, msgs_recv, 10);

    pb_u8(&pb, 0x0008, 0);
    pb_u16(&pb, 0x0009, 0);

    /* ExternalAccessoryProtocol (0x000A) — GROUP parameter.
     * Previously removed because it caused IdentificationRejected, but that was
     * due to encoding it as flat TLV instead of proper GROUP with sub-params.
     * wiomoc encodes: id=1, name="de.wiomoc.test", match_action=NONE(0)
     * We use "com.apple.carplay" as the protocol name.
     * Sub-params: 0x0000=id(u8), 0x0001=name(utf8), 0x0002=match_action(u8) */
    {
        int g = pb_grp_begin(&pb, 0x000A);
        pb_u8(&pb, 0x0000, 1);                     /* protocol id */
        pb_utf8(&pb, 0x0001, "com.apple.carplay");  /* protocol name */
        pb_u8(&pb, 0x0002, 0);                      /* match_action = NONE */
        pb_grp_end(&pb, g);
        printf("[ID] Added ExternalAccessoryProtocol (id=1, com.apple.carplay)\n");
    }

    pb_utf8(&pb, 0x000C, "en");
    {
        static const char *langs[] = { "en" };
        pb_utf8_list(&pb, 0x000D, langs, 1, 1);
    }

    {
        int g = pb_grp_begin(&pb, 0x0011);
        pb_u16(&pb, 0x0000, 0);
        pb_utf8(&pb, 0x0001, "RoadLink BT");
        pb_none(&pb, 0x0002);
        if (have_local_addr) {
            pb_blob(&pb, 0x0003, local_bd_addr, 6);
            printf("[ID] BT MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
                local_bd_addr[0],local_bd_addr[1],local_bd_addr[2],
                local_bd_addr[3],local_bd_addr[4],local_bd_addr[5]);
        }
        pb_grp_end(&pb, g);
    }

    /* WirelessCarPlayTransportComponent (0x0018) — tells iPhone we do WiFi CarPlay
     * wiomoc uses:
     *   param 0 = TransportComponentIdentifier (uint16)
     *   param 1 = TransportComponentName (utf8)
     *   param 2 = supports_iap2_connection (none/presence)
     *   param 4 = supports_car_play (none/presence)   ← WE WERE MISSING THIS
     */
    {
        int g = pb_grp_begin(&pb, 0x0018);
        pb_u16(&pb, 0x0000, 1);                /* TransportComponentIdentifier */
        pb_utf8(&pb, 0x0001, "RoadLink WiFi"); /* TransportComponentName */
        pb_none(&pb, 0x0002);                  /* supports_iap2_connection */
        pb_none(&pb, 0x0004);                  /* supports_car_play ← NEW */
        pb_grp_end(&pb, g);
        printf("[ID] Added WirelessCarPlayTransportComponent (id=1, iap2+carplay)\n");
    }

    printf("[ID] Sending 0x1D01 (%d bytes)\n", pb.off);
    send_control_msg(0x1D01, pb.buf, pb.off);
    pb_free(&pb);
}

/* ═══════════════════════════════════════════════
 *  0x4E01: BluetoothComponentInformation
 * ═══════════════════════════════════════════════ */
static void send_bt_component_info(void) {
    printf("[BT] Sending BluetoothComponentInformation (0x4E01)...\n");
    PB pb; pb_init(&pb, 64);
    pb_u16(&pb, 0x0000, 0);
    send_control_msg(0x4E01, pb.buf, pb.off);
    pb_free(&pb);
}

/* ═══════════════════════════════════════════════
 *  0x4301: CarPlayStartSession ("stealth" — not declared in identification)
 *
 *  Based on CarPlay Simulator RE. The simulator sends this message with:
 *    0x0001 = WirelessAttributes (GROUP):
 *      0x0000 = WiFiSSID (utf8)
 *      0x0001 = Passphrase (utf8)
 *      0x0002 = Channel (u8)
 *      0x0003 = IPAddress (utf8, link-local IPv6)
 *    0x0002 = Port (u32, 7000)
 *    0x0003 = DeviceIdentifier (utf8, MAC)
 *    0x0004 = PublicKey (utf8, hex ed25519 pk)
 *    0x0005 = SourceVersion (utf8)
 * ═══════════════════════════════════════════════ */
static bool refresh_wifi_ipv6(void) {
    struct ifaddrs *ifa = NULL, *it = NULL;
    wifi_ipv6[0] = '\0';

    if (getifaddrs(&ifa) != 0) {
        perror("getifaddrs");
        return false;
    }

    const char *ifaces[] = {kWifiInterface, "ap1", "en0", NULL};
    for (int idx = 0; ifaces[idx] != NULL; idx++) {
        for (it = ifa; it != NULL; it = it->ifa_next) {
            if (!it->ifa_name || strcmp(it->ifa_name, ifaces[idx]) != 0 || !it->ifa_addr)
                continue;
            if (it->ifa_addr->sa_family == AF_INET6) {
                struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)it->ifa_addr;
                if (!IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) continue;
                inet_ntop(AF_INET6, &sin6->sin6_addr, wifi_ipv6, sizeof(wifi_ipv6));
                freeifaddrs(ifa);
                return true;
            }
        }
    }
    freeifaddrs(ifa);
    return false;
}

static void send_carplay_start_session(const char *reason) {
    if (start_session_sent) return;
    if (!wifi_config_sent) {
        printf("[SS] 0x4301 deferred (%s) — wifi config not yet sent\n", reason);
        return;
    }

    /* Try to get the link-local IPv6 address */
    if (wifi_ipv6[0] == '\0') refresh_wifi_ipv6();
    if (wifi_ipv6[0] == '\0') {
        printf("[SS] WARNING: no IPv6 on %s — sending 0x4301 without IPAddress\n", kWifiInterface);
    }

    PB pb; pb_init(&pb, 512);

    /* WirelessAttributes group */
    {
        int g = pb_grp_begin(&pb, 0x0001);
        pb_utf8(&pb, 0x0000, kWifiSSID);
        pb_utf8(&pb, 0x0001, kWifiPassword);
        pb_u8(&pb, 0x0002, kWifiChannel);
        if (wifi_ipv6[0] != '\0') {
            pb_utf8(&pb, 0x0003, wifi_ipv6);
        }
        pb_grp_end(&pb, g);
    }

    pb_u32(&pb, 0x0002, kAirPlayPort);
    pb_utf8(&pb, 0x0003, kAirPlayDeviceId);
    pb_utf8(&pb, 0x0004, kAirPlayPublicKey);
    pb_utf8(&pb, 0x0005, kAirPlaySourceVer);

    printf("[SS] *** Sending 0x4301 CarPlayStartSession (%s) ***\n", reason);
    printf("[SS]   deviceID: %s\n", kAirPlayDeviceId);
    printf("[SS]   port: %u\n", kAirPlayPort);
    printf("[SS]   wifi IPv6: %s\n", wifi_ipv6[0] ? wifi_ipv6 : "(none)");
    printf("[SS]   srcvers: %s\n", kAirPlaySourceVer);
    printf("[SS]   SSID: %s  channel: %d\n", kWifiSSID, kWifiChannel);

    send_control_msg(0x4301, pb.buf, pb.off);
    pb_free(&pb);
    start_session_sent = 1;
    printf("[SS] *** 0x4301 sent — iPhone should now connect to port 7000 ***\n");
}

/* ═══════════════════════════════════════════════
 *  Detect
 * ═══════════════════════════════════════════════ */
static void send_detect(void) {
    if(!active_cid||iap2_detected) return;
    detect_count++;
    bt_send_rfcomm(active_cid,iap2_detect,6);
    printf("[DET] #%d\n",detect_count);
}
static void alarm_handler(int sig) {
    (void)sig;
    if(active_cid&&!iap2_detected&&detect_count<10){send_detect();alarm(1);}
}

/* ═══════════════════════════════════════════════
 *  Control message handler
 * ═══════════════════════════════════════════════ */
static void handle_ctrl_msg(uint16_t msg_id, uint8_t *params, int plen) {
    printf("[CTRL] msg=0x%04X (%d bytes)\n", msg_id, plen);

    switch (msg_id) {
    /* ── Authentication ── */
    case 0xAA00:
        printf("[CP] *** RequestAuthCert ***\n");
        send_auth_cert();
        break;
    case 0xAA02: {
        printf("[CP] *** RequestAuthChallenge ***\n");
        if (plen>=4) {
            int dlen=((params[0]<<8)|params[1])-4;
            if (dlen>0&&dlen<=1024) send_auth_response(&params[4],dlen);
        }
        break;
    }
    case 0xAA04: printf("[CP] *** AUTH FAILED ***\n"); break;
    case 0xAA05: printf("[CP] *** AUTH SUCCEEDED! ***\n"); break;

    /* ── Identification ── */
    case 0x1D00:
        printf("[CP] *** StartIdentification ***\n");
        send_identification_info();
        break;
    case 0x1D02:
        printf("[CP] *** IdentificationAccepted! ***\n");
        send_bt_component_info();
        printf("[CP] Waiting for auth / WiFi request...\n");
        break;
    case 0x1D03:
        printf("[CP] *** IdentificationRejected! ***\n");
        {
            int off=0;
            while(off+4<=plen) {
                uint16_t pl=(params[off]<<8)|params[off+1];
                uint16_t pid=(params[off+2]<<8)|params[off+3];
                const char *names[]={
                    "Name","ModelIdentifier","Manufacturer","SerialNumber",
                    "FirmwareVersion","HardwareVersion","MessagesSentByAccessory",
                    "MessagesReceivedFromDevice","PowerProvidingCapability",
                    "MaximumCurrentDrawnFromDevice","SupportedExternalAccessoryProtocol",
                    "AppMatchTeamID","CurrentLanguage","SupportedLanguage",
                    "UARTTransportComponent","USBDeviceTransportComponent",
                    "USBHostTransportComponent","BluetoothTransportComponent",
                    "iAP2HIDComponent","?(19)","VehicleInformationComponent",
                    "VehicleStatusComponent","LocationInformationComponent",
                    "USBHostHIDComponent","WirelessCarPlayTransportComponent"
                };
                const char *name = pid<25 ? names[pid] : "?";
                printf("[REJECT] Param 0x%04X (%s)\n", pid, name);
                if (pl > 4) {
                    printf("  data:");
                    for (int i=4; i<pl && i<20; i++) printf(" %02X", params[off+i]);
                    printf("\n");
                }
                off += (pl>0?pl:4);
            }
        }
        break;

    /* ── Wi-Fi provisioning ── */
    case 0x5702:
        printf("[CP] *** RequestAccessoryWiFiConfigInfo ***\n");
        send_accessory_wifi_config();
        break;

    /* 0x4300 — CarPlayAvailability: not declared in identification, but handle
     * it anyway in case the iPhone sends it. This is the "stealth" approach. */
    case 0x4300: {
        printf("[CP] *** CarPlayAvailability (0x4300) ***\n");
        printf("[CP] Raw data (%d bytes):", plen);
        for(int i=0;i<plen&&i<128;i++) printf(" %02X",params[i]);
        printf("\n");
        /* Parse status if present */
        if (plen >= 5) {
            int off_ca = 0;
            while(off_ca + 4 <= plen) {
                uint16_t pl_ca = (params[off_ca]<<8)|params[off_ca+1];
                uint16_t pid_ca = (params[off_ca+2]<<8)|params[off_ca+3];
                if (pid_ca == 0x0000 && pl_ca >= 5) {
                    printf("[CP] CarPlay availability status = %d\n", params[off_ca+4]);
                }
                off_ca += (pl_ca > 0 ? pl_ca : 4);
            }
        }
        /* Try to send start-session in response */
        send_carplay_start_session("CarPlayAvailability");
        break;
    }

    case 0x4E0B:
        printf("[CP] DeviceTimeUpdate\n");
        break;

    /* ── Post-WiFi messages ── */
    case 0x4E0D: {
        printf("[CP] *** WirelessCarPlayUpdate ***\n");
        printf("[CP] Raw data (%d bytes):", plen);
        for(int i=0;i<plen&&i<128;i++) printf(" %02X",params[i]);
        printf("\n");
        if(plen>0){
            int off4e=0;
            while(off4e+4<=plen) {
                uint16_t pl4=(params[off4e]<<8)|params[off4e+1];
                uint16_t pid4=(params[off4e+2]<<8)|params[off4e+3];
                printf("[CP]   param 0x%04X len=%d", pid4, pl4-4);
                if (pid4==0x0000 && pl4>=5) {
                    uint8_t st = params[off4e+4];
                    const char *status_names[] = {
                        "Idle/NotReady", "Connecting", "Connected", "Error",
                        "Disconnecting", "Disconnected"
                    };
                    const char *sn = (st < 6) ? status_names[st] : "Unknown";
                    printf(" → WirelessCarPlay status = %d (%s)", st, sn);
                } else if (pid4==0x0001 && pl4>=6) {
                    uint16_t tid = (params[off4e+4]<<8)|params[off4e+5];
                    printf(" → TransportComponentID = %d", tid);
                }
                if (pl4 > 4) {
                    printf(" [");
                    for(int j=4;j<pl4&&j<20;j++) printf("%02X",params[off4e+j]);
                    printf("]");
                }
                printf("\n");
                off4e += (pl4>0?pl4:4);
            }
        }
        printf("[CP] → NETWORK PHASE — iPhone should be switching to WiFi\n");
        printf("[CP] → Our AP BSSID: %02X:%02X:%02X:%02X:%02X:%02X\n",
               kApBSSID[0], kApBSSID[1], kApBSSID[2],
               kApBSSID[3], kApBSSID[4], kApBSSID[5]);
        printf("[CP] → Waiting for iPhone to auto-join AP and discover _airplay._tcp\n");
        break;
    }

    case 0x4E0E: {
        printf("[CP] *** DeviceTransportIdentifierNotification ***\n");
        printf("[CP] Raw data (%d bytes):", plen);
        for(int i=0;i<plen&&i<128;i++) printf(" %02X",params[i]);
        printf("\n");
        if(plen>0){
            int off4e2=0;
            while(off4e2+4<=plen) {
                uint16_t pl4=(params[off4e2]<<8)|params[off4e2+1];
                uint16_t pid4=(params[off4e2+2]<<8)|params[off4e2+3];
                printf("[CP]   param 0x%04X len=%d", pid4, pl4-4);
                if (pid4==0x0000 && pl4>=6) {
                    /* TransportComponentIdentifier */
                    uint16_t tid = (params[off4e2+4]<<8)|params[off4e2+5];
                    printf(" → TransportComponentID = %d", tid);
                }
                if (pid4==0x0001 && pl4>=10) {
                    /* TransportIdentifier — should be iPhone's WiFi MAC */
                    printf(" → DeviceTransportID = ");
                    for(int j=4;j<pl4;j++) {
                        if(j>4) printf(":");
                        printf("%02X",params[off4e2+j]);
                    }
                }
                if (pl4 > 4) {
                    printf(" [");
                    for(int j=4;j<pl4&&j<20;j++) printf("%02X",params[off4e2+j]);
                    printf("]");
                }
                printf("\n");
                off4e2 += (pl4>0?pl4:4);
            }
        }
        printf("[CP] → iPhone told us its WiFi transport identifier\n");
        transport_notification_seen = 1;

        /* This is the key trigger point. After 0x4E0E, the iPhone is about to
         * join our WiFi. Send 0x4301 CarPlayStartSession with the receiver's
         * connection details so the iPhone knows WHERE to connect for AirPlay.
         * Send immediately — RFCOMM may close shortly after. */
        send_carplay_start_session("post-0x4E0E");
        break;
    }

    case 0x4E0F:
        printf("[CP] *** WirelessCarPlayTransportUpdate (0x4E0F) ***\n");
        printf("[CP] Data (%d bytes):", plen);
        for(int i=0;i<plen&&i<128;i++) printf(" %02X",params[i]);
        printf("\n");
        break;

    case 0x4E0C:
        printf("[CP] *** Msg 0x4E0C ***\n");
        printf("[CP] Data (%d bytes):", plen);
        for(int i=0;i<plen&&i<128;i++) printf(" %02X",params[i]);
        printf("\n");
        break;

    case 0xEA00: {
        printf("[EA] *** StartExternalAccessoryProtocolSession ***\n");
        if(plen>0){
            printf("[EA] Data:");
            for(int i=0;i<plen&&i<64;i++) printf(" %02X",params[i]);
            printf("\n");
        }
        /* Parse: param 0x0000=protocol_id(u8), param 0x0001=session_id(u16 BE) */
        uint8_t ea_protocol_id = 0;
        uint16_t ea_session_id = 0;
        {
            int off_ea = 0;
            while(off_ea + 4 <= plen) {
                uint16_t pl_ea = (params[off_ea]<<8)|params[off_ea+1];
                uint16_t pid_ea = (params[off_ea+2]<<8)|params[off_ea+3];
                if(pid_ea == 0x0000 && pl_ea >= 5) {
                    ea_protocol_id = params[off_ea+4];
                    printf("[EA] protocol_id = %d\n", ea_protocol_id);
                } else if(pid_ea == 0x0001 && pl_ea >= 6) {
                    ea_session_id = (params[off_ea+4]<<8)|params[off_ea+5];
                    printf("[EA] session_id = %d\n", ea_session_id);
                }
                off_ea += (pl_ea > 0 ? pl_ea : 4);
            }
        }
        /* Respond with 0xEA03 StatusExternalAccessoryProtocolSession
         * param 0x0000 = session_id (Uint16 BE)
         * param 0x0001 = status (1 byte, OK=0) */
        {
            PB rpb; pb_init(&rpb, 32);
            pb_u16(&rpb, 0x0000, ea_session_id);
            pb_u8(&rpb, 0x0001, 0); /* SessionStatus.OK = 0 */
            printf("[EA] Sending 0xEA03 StatusEAP (session=%d, status=OK)\n",
                   ea_session_id);
            send_control_msg(0xEA03, rpb.buf, rpb.off);
            pb_free(&rpb);
        }
        /* Also try start-session from EAP context */
        send_carplay_start_session("EAP-session-started");
        break;
    }

    case 0xEA01:
        printf("[EA] *** StopExternalAccessoryProtocolSession ***\n");
        break;

    /* ── Vehicle status (declared in v39 per wiomoc) ── */
    case 0xA100:
        printf("[VS] *** StartVehicleStatusUpdates ***\n");
        if(plen>0){
            printf("[VS] Data:");
            for(int i=0;i<plen&&i<64;i++) printf(" %02X",params[i]);
            printf("\n");
        }
        break;

    case 0xA102:
        printf("[VS] *** StopVehicleStatusUpdates ***\n");
        break;

    default:
        printf("[CTRL] Unhandled 0x%04X (%d bytes)\n", msg_id, plen);
        if(plen>0){
            printf("  ");
            for(int i=0;i<plen&&i<128;i++) printf("%02X ",params[i]);
            printf("\n");
        }
        break;
    }
}

/* ═══════════════════════════════════════════════
 *  BTstack packet handler
 * ═══════════════════════════════════════════════ */
static void handler(uint8_t type, uint16_t ch, uint8_t *pkt, uint16_t sz) {
    if(packet_debug_count < 24) {
        printf("[BT] packet type=%u ch=0x%04x len=%u", type, ch, sz);
        int n = sz < 12 ? sz : 12;
        for(int i=0;i<n;i++) printf(" %02X", pkt[i]);
        printf("\n");
        packet_debug_count++;
    }

    if(type==4&&pkt[0]==0x6c) return;

    if(type==7) {
        if(sz>=6&&memcmp(pkt,iap2_detect,6)==0&&!iap2_detected) {
            printf("[CP] *** DETECT ECHO ***\n");
            iap2_detected=1; alarm(0);
            srand(time(NULL));
            my_initial_psn=(rand()%254)+1;
            if (my_initial_psn == 0xFF) my_initial_psn = 0x7F;
            my_next_psn=my_initial_psn+1;
            send_syn(); return;
        }
        if(sz>=5&&pkt[0]==0xFF&&pkt[1]==0x5A) {
            uint8_t ctrl=pkt[4],seq=pkt[5],ack=pkt[6],session=pkt[7];
            if(ctrl==0x10){
                printf("[CP] RST\n"); link_established=0; usleep(500000);
                my_initial_psn=(rand()%254)+1;
                if (my_initial_psn == 0xFF) my_initial_psn = 0x7F;
                my_next_psn=my_initial_psn+1;
                send_syn(); return;
            }
            if((ctrl&0xC0)==0xC0&&!link_established) {
                peer_psn=seq;
                printf("[SYN-ACK] seq=0x%02X ack=0x%02X\n", seq, ack);
                if(sz>9) {
                    printf("[SYN-ACK] payload(%d):", sz-9);
                    for(int i=9;i<sz&&i<40;i++) printf(" %02X",pkt[i]);
                    printf("\n");
                }
                if(ack==my_initial_psn){send_ack();link_established=1;printf("[CP] *** LINK UP ***\n");}
                return;
            }
            peer_psn=seq;
            if((ctrl&0x40)&&session!=0&&sz>10) {
                send_ack();
                uint8_t *m=&pkt[9]; int pl=sz-10;
                if(pl>=6&&m[0]==0x40&&m[1]==0x40) {
                    uint16_t mlen=(m[2]<<8)|m[3], mid=(m[4]<<8)|m[5];
                    handle_ctrl_msg(mid,&m[6],mlen-6);
                }
                return;
            }
            if(ctrl==0x40) return;
        }
        return;
    }

    if(type==5||type!=4) return;

    /* Capture BD_ADDR from HCI Read BD_ADDR command complete */
    if(pkt[0]==0x0E && sz>=12 && !have_local_addr) {
        uint16_t opcode = (uint16_t)pkt[3] | ((uint16_t)pkt[4]<<8);
        if(opcode == 0x1009 && pkt[5]==0) {
            for(int i=0;i<6;i++) local_bd_addr[i] = pkt[11-i];
            have_local_addr = 1;
            printf("[BT] Local BD_ADDR: %02X:%02X:%02X:%02X:%02X:%02X\n",
                local_bd_addr[0],local_bd_addr[1],local_bd_addr[2],
                local_bd_addr[3],local_bd_addr[4],local_bd_addr[5]);
        }
    }

    if(pkt[0]==0x0E||pkt[0]==0x13||pkt[0]==0x1B||pkt[0]==0x66||
       pkt[0]==0x61||pkt[0]==0x0f||pkt[0]==0x0b||pkt[0]==0xe0||
       pkt[0]==0x75||pkt[0]==0x85||pkt[0]==0x87||pkt[0]==0x73||
       pkt[0]==0x90||pkt[0]==0x74||pkt[0]==0x88||pkt[0]==0x84||
       pkt[0]==0x38) return;

    switch(pkt[0]) {
    case 0x60:
        if(pkt[2]==2&&!setup_done) {
            setup_done=1;
            /* hci_write_local_name expects a 248-byte fixed-size field per
             * HCI spec. libBTstack may read past strlen(). Pass a proper
             * 248-byte zero-padded buffer to avoid reading garbage. */
            {
                static char localNameBuf[248];
                memset(localNameBuf, 0, sizeof(localNameBuf));
                strncpy(localNameBuf, kDeviceName, sizeof(localNameBuf) - 1);
                bt_send_cmd(&hci_write_local_name, localNameBuf);
            }
            bt_send_cmd(&hci_write_class_of_device,0x200420);
            bt_send_cmd(&hci_write_simple_pairing_mode,1);
            bt_send_cmd(&hci_read_bd_addr);
            uint8_t eir[240]; build_eir(eir);
            bt_send_cmd(&hci_write_extended_inquiry_response,0,eir);
            bt_send_cmd(&rfcomm_register_service,3,0xffff);
            build_sdp(sdp_rec,3);
            bt_send_cmd(&sdp_register_service_record,sdp_rec);
            build_did_sdp(did_sdp_rec);
            bt_send_cmd(&sdp_register_service_record,did_sdp_rec);
            bt_send_cmd(&btstack_set_discoverable,1);
            printf("[CP] READY — identity: RoadLink / RL-100 / RoadLink Labs\n");
        }
        break;
    case 0x04: {
        bd_addr_t a;memcpy(a,&pkt[2],6);
        printf("[CP] CONN REQ\n");
        bt_send_cmd(&hci_accept_connection_request,a,0);
        break;
    }
    case 0x03: printf("[CP] Connected\n"); break;
    case 0x05:
        printf("[CP] Disconnected\n");
        active_cid=0;iap2_detected=0;link_established=0;wifi_config_sent=0;start_session_sent=0;transport_notification_seen=0;wifi_ipv6[0]='\0';
        break;
    case 0x08: printf("[CP] Encrypted\n"); break;
    case 0x31:{
        bd_addr_t a;memcpy(a,&pkt[2],6);
        bt_send_cmd(&hci_io_capability_request_reply,a,3,0,2);
        break;
    }
    case 0x33:{
        bd_addr_t a;memcpy(a,&pkt[2],6);
        bt_send_cmd(&hci_user_confirmation_request_reply,a);
        break;
    }
    case 0x82:{
        uint16_t c=R16(pkt,9);
        bt_send_cmd(&rfcomm_accept_connection,c);
        printf("[CP] RFCOMM IN\n");
        break;
    }
    case 0x80:
        if(pkt[2]==0){
            active_cid=R16(pkt,12);rfcomm_mtu=R16(pkt,14);
            iap2_detected=0;link_established=0;detect_count=0;wifi_config_sent=0;
            printf("[CP] RFCOMM OPEN cid=0x%04x mtu=%d\n",active_cid,rfcomm_mtu);
            usleep(100000);
            send_detect();
            signal(SIGALRM,alarm_handler);
            alarm(1);
        }
        break;
    case 0x81:
        printf("[CP] RFCOMM CLOSED\n");
        alarm(0);active_cid=0;iap2_detected=0;link_established=0;wifi_config_sent=0;start_session_sent=0;transport_notification_seen=0;wifi_ipv6[0]='\0';
        break;
    }
}

int main(int argc, char *argv[]) {
    /* Line-buffered stdout/stderr so logs survive SIGTERM (default is
     * fully-buffered when stdout is a file, which loses everything). */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);
    parse_args(argc, argv);
    @autoreleasepool {
        printf("[CP] Showcase / carplay_bt\n");
        printf("[CP] Name=%s  SSID=\"%s\"\n", kDeviceName, kWifiSSID);
        printf("[CP] WiFi: SSID=\"%s\" SEC=%d CH=%d BSSID=%02X:%02X:%02X:%02X:%02X:%02X\n",
               kWifiSSID, kWifiSecurityType, kWifiChannel,
               kApBSSID[0], kApBSSID[1], kApBSSID[2],
               kApBSSID[3], kApBSSID[4], kApBSSID[5]);
        printf("[CP] AirPlay: deviceid=%s port=%u srcvers=%s\n",
               kAirPlayDeviceId, kAirPlayPort, kAirPlaySourceVer);
        printf("[CP] Strategy: identification unchanged (working v40)\n");
        printf("[CP]           0x4301 sent undeclared after 0x4E0E (harmless)\n");
        printf("[CP]           REAL FIX: HKPairingAndEncrypt enabled in services\n");
        printf("[CP] *** Ensure AP \"%s\" + carplay_services are running! ***\n\n",
               kWifiSSID);

        issue_baa_cert();
        if(!baa_ready){
            printf("[CP] FATAL: No BAA cert\n");
            return 1;
        }

        run_loop_init(1);
        int open_rc = bt_open();
        printf("[BT] bt_open rc=%d\n", open_rc);
        if(open_rc) return 1;
        bt_register_packet_handler(handler);
        int sysbt_rc = bt_send_cmd(&btstack_set_system_bluetooth_enabled,0);
        printf("[BT] btstack_set_system_bluetooth_enabled(0) rc=%d\n", sysbt_rc);
        sleep(3);
        int power_rc = bt_send_cmd(&btstack_set_power_mode,1);
        printf("[BT] btstack_set_power_mode rc=%d\n", power_rc);
        run_loop_execute();
    }
    return 0;
}
