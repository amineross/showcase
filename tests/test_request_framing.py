"""Compile the production RTSP parser and request framing without iOS headers."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/carplay_services.m').read_text()
struct_end = source.index('} HTTPReq;') + len('} HTTPReq;')
struct = source[source.rindex('typedef struct {', 0, struct_end):struct_end]
parser_start = source.index('static bool parse_http(const uint8_t *buf, size_t len, HTTPReq *r) {')
framing_end = source.index('/* END request framing */')
code = source[parser_start:framing_end]

harness = r'''
#define _GNU_SOURCE
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <assert.h>
#include <stdio.h>
''' + struct + '\n' + code + r'''
static uint8_t buf[65536];
static size_t used;

static void add(const char *bytes, size_t n) { memcpy(buf + used, bytes, n); used += n; }
#define ADD(lit) add(lit, sizeof(lit) - 1)
static RequestState take(HTTPReq *r, size_t *length) {
    RequestState s = take_request(buf, used, sizeof(buf), r, length);
    if (s != REQUEST_INCOMPLETE) { memmove(buf, buf + *length, used - *length); used -= *length; }
    return s;
}

int main(void) {
    HTTPReq r; size_t n;
    /* iOS 27: SETUP with an 832-byte body arrives as 816 + 16. */
    char head[] = "SETUP rtsp://x/1 RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 832\r\n\r\n";
    char body[832]; memset(body, 'b', sizeof(body)); body[831] = 'Z';
    add(head, strlen(head)); add(body, 816);
    assert(take(&r, &n) == REQUEST_INCOMPLETE);
    add(body + 816, 16);
    assert(take(&r, &n) == REQUEST_READY);
    assert(!strcmp(r.method, "SETUP") && r.cseq == 7 && r.bodyLen == 832 && r.body[831] == 'Z');
    assert(used == 0);

    /* Headers split mid-line, then two pipelined requests in one record. */
    ADD("GET /info RTSP/1.0\r\nCSe");
    assert(take(&r, &n) == REQUEST_INCOMPLETE);
    ADD("q: 1\r\n\r\nOPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\nPOST /feedback RTSP/1.0\r\nCSeq: 3\r\nContent-Length: 2\r\n\r\nok");
    assert(take(&r, &n) == REQUEST_READY && !strcmp(r.method, "GET") && r.cseq == 1);
    assert(take(&r, &n) == REQUEST_READY && !strcmp(r.method, "OPTIONS") && r.cseq == 2);
    assert(take(&r, &n) == REQUEST_READY && !strcmp(r.method, "POST") && r.cseq == 3 && !memcmp(r.body, "ok", 2));
    assert(used == 0);

    /* A request with no headers at all. */
    ADD("OPTIONS * RTSP/1.0\r\n\r\n");
    assert(take(&r, &n) == REQUEST_READY && !strcmp(r.method, "OPTIONS"));

    /* Garbage with a header end is skipped; the next request survives. */
    ADD("garbage\r\n\r\nTEARDOWN x RTSP/1.0\r\nCSeq: 9\r\n\r\n");
    assert(take(&r, &n) == REQUEST_INVALID && n == 11);
    assert(take(&r, &n) == REQUEST_READY && !strcmp(r.method, "TEARDOWN"));

    /* A body larger than the buffer is dropped instead of waited for. */
    ADD("SETUP x RTSP/1.0\r\nContent-Length: 99999999\r\n\r\n");
    assert(take(&r, &n) == REQUEST_INVALID && used == 0);

    /* Binary body bytes, including NUL and CRLFCRLF, do not confuse framing. */
    ADD("SETUP x RTSP/1.0\r\nContent-Length: 6\r\n\r\n\0\r\n\r\n\0");
    assert(take(&r, &n) == REQUEST_READY && r.bodyLen == 6 && used == 0);
    puts("request framing ok");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = Path(d) / 't.c'
    c.write_text(harness)
    subprocess.run(['cc', '-Wall', '-Wno-unused-function', '-fsanitize=address,undefined', '-o', str(Path(d) / 't'), str(c)], check=True)
    subprocess.run([str(Path(d) / 't')], check=True)
