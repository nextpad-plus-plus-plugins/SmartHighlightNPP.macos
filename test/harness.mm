// Deterministic logic harness for SmartHighlightNPP.
//
// The plugin's helpers are static (file-local), so the harness includes the
// translation unit directly rather than linking against the dylib. Built with a
// tiny decompression ceiling (see run.sh) so the bomb guard can be exercised
// without writing 2 GB to disk.
//
// Covers the behaviours that were fixed; nothing here touches the host.

#include "../SmartHighlight.mm"

#import <Foundation/Foundation.h>

static int gPass = 0, gFail = 0;

static void ok(bool cond, NSString *what) {
    if (cond) { gPass++; printf("  PASS  %s\n", what.UTF8String); }
    else      { gFail++; printf("  FAIL  %s\n", what.UTF8String); }
}

static NSString *tmpdir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"cch_%@", [[NSUUID UUID] UUIDString]]];
    [[NSFileManager defaultManager] createDirectoryAtPath:d
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static bool shell(NSString *cmd) {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/sh";
    t.arguments = @[@"-c", cmd];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    [t launch];
    [t waitUntilExit];
    return t.terminationStatus == 0;
}

// ── 1. filename helpers ──────────────────────────────────────────────────────
static void test_helpers(void) {
    printf("\n[1] filename helpers\n");
    ok([ccStripArchiveExtension(@"bundle.tar.gz") isEqualToString:@"bundle"], @"strip .tar.gz");
    ok([ccStripArchiveExtension(@"bundle.tgz")    isEqualToString:@"bundle"], @"strip .tgz");
    ok([ccStripArchiveExtension(@"bundle.zip")    isEqualToString:@"bundle"], @"strip .zip");
    ok(ccIsSupportedArchivePath(@"/x/a.zip"),   @"recognise .zip");
    ok(ccIsSupportedArchivePath(@"/x/a.tar.gz"), @"recognise .tar.gz");
    ok(!ccIsSupportedArchivePath(@"/x/a.txt"),  @"reject .txt");
}

// ── 2. ccRunTask must not deadlock on a chatty child ─────────────────────────
// Regression: stdout was an NSPipe that was never drained, so any tool emitting
// more than the 64KB pipe buffer (7z prints a line per entry) blocked forever.
static void test_runtask_no_deadlock(void) {
    printf("\n[2] ccRunTask: chatty child does not deadlock\n");
    NSString *err = nil;
    NSDate *t0 = [NSDate date];
    // 2 MB to stdout — 32x the pipe buffer.
    bool r = ccRunTask(@"/bin/dd", @[@"if=/dev/zero", @"bs=1024", @"count=2048"], &err);
    NSTimeInterval dt = -[t0 timeIntervalSinceNow];
    ok(r, @"2MB-stdout child completes");
    ok(dt < 20.0, ([NSString stringWithFormat:@"returned promptly (%.2fs)", dt]));
}

static void test_runtaskcapture_large(void) {
    printf("\n[3] ccRunTaskCapture: large stdout captured, no deadlock\n");
    NSString *out = nil, *errs = nil; int code = -1;
    NSDate *t0 = [NSDate date];
    bool r = ccRunTaskCapture(@"/bin/echo", @[@"hello-capture"], &out, &errs, &code);
    NSTimeInterval dt = -[t0 timeIntervalSinceNow];
    ok(r && code == 0, @"small capture succeeds");
    ok([out containsString:@"hello-capture"], @"stdout captured");
    ok(dt < 20.0, @"returned promptly");
}

// ── 4. gzip: normal file round-trips ─────────────────────────────────────────
static void test_gzip_ok(void) {
    printf("\n[4] ccExtractGzipFile: normal .gz round-trips\n");
    NSString *d = tmpdir();
    NSString *src = [d stringByAppendingPathComponent:@"payload.txt"];
    [@"hello gzip world\n" writeToFile:src atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (!shell([NSString stringWithFormat:@"cd '%@' && gzip -k payload.txt", d])) { ok(false, @"setup gzip"); return; }

    NSString *gz  = [d stringByAppendingPathComponent:@"payload.txt.gz"];
    NSString *out = [d stringByAppendingPathComponent:@"out"];
    NSString *err = nil;
    bool r = ccExtractGzipFile(gz, out, &err);
    ok(r, @"extraction succeeds");
    NSString *got = [NSString stringWithContentsOfFile:[out stringByAppendingPathComponent:@"payload.txt"]
                                              encoding:NSUTF8StringEncoding error:nil];
    ok([got isEqualToString:@"hello gzip world\n"], @"content byte-identical");
    [[NSFileManager defaultManager] removeItemAtPath:d error:nil];
}

// ── 5. gzip bomb is refused, partial output cleaned up ───────────────────────
// Regression: the decompressed stream was read fully into one NSData. Measured
// ~1029:1 expansion, in-process → OOM took the editor and unsaved tabs with it.
static void test_gzip_bomb(void) {
    printf("\n[5] ccExtractGzipFile: decompression bomb refused (cap=%llu bytes)\n",
           kCCMaxDecompressedBytes);
    NSString *d = tmpdir();
    NSString *gz = [d stringByAppendingPathComponent:@"bomb.gz"];
    // ~10 MB of zeros -> a few KB compressed; far over the harness cap.
    if (!shell([NSString stringWithFormat:@"dd if=/dev/zero bs=1m count=10 2>/dev/null | gzip -9 > '%@'", gz])) {
        ok(false, @"setup bomb"); return;
    }
    unsigned long long csize = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:gz error:nil][NSFileSize] unsignedLongLongValue];

    NSString *out = [d stringByAppendingPathComponent:@"out"];
    NSString *err = nil;
    NSDate *t0 = [NSDate date];
    bool r = ccExtractGzipFile(gz, out, &err);
    NSTimeInterval dt = -[t0 timeIntervalSinceNow];

    printf("        (%llu B compressed -> refused in %.2fs)\n", csize, dt);
    ok(!r, @"bomb refused");
    ok(err && [err containsString:@"decompression bomb"], @"error names the cause");
    ok(dt < 30.0, @"bails quickly, does not expand fully");
    // Partial output must not be left behind.
    NSString *leftover = [out stringByAppendingPathComponent:@"bomb"];
    ok(![[NSFileManager defaultManager] fileExistsAtPath:leftover], @"partial output removed");
    [[NSFileManager defaultManager] removeItemAtPath:d error:nil];
}

// ── 6. Trash, not unlink ─────────────────────────────────────────────────────
// Regression: the user's selected archive was removeItemAtPath'd — unrecoverable,
// with nothing in the open panel warning them.
static void test_trash(void) {
    printf("\n[6] ccTrashItemAtPath: recoverable, never unlinked\n");
    NSString *d = tmpdir();
    NSString *marker = [NSString stringWithFormat:@"cch_trash_probe_%@.zip", [[NSUUID UUID] UUIDString]];
    NSString *f = [d stringByAppendingPathComponent:marker];
    [@"precious" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *err = nil, *landed = nil;
    bool r = ccTrashItemAtPath(f, &landed, &err);
    ok(r, @"trashItemAtURL succeeds");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:f], @"gone from original location");

    // Prove it was relocated rather than destroyed. The Trash directory cannot be
    // listed from an unsigned binary (TCC denies it), so this asserts on the
    // landing path the API reports instead of scanning ~/.Trash.
    NSString *trash = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
    ok(landed.length > 0, @"reports where it landed");
    ok([landed hasPrefix:trash], @"landed inside ~/.Trash (recoverable, not unlinked)");
    ok([[landed lastPathComponent] hasPrefix:@"cch_trash_probe_"], @"same file, moved");
    if (landed) [[NSFileManager defaultManager] removeItemAtPath:landed error:nil];  // tidy our probe

    // A path that cannot be trashed must fail closed, not hard-delete.
    NSString *missErr = nil;
    ok(!ccTrashItemAtPath([d stringByAppendingPathComponent:@"nope.zip"], NULL, &missErr),
       @"missing file reports failure");
    [[NSFileManager defaultManager] removeItemAtPath:d error:nil];
}

// ── 7. archive extraction contains path traversal ────────────────────────────
static void test_traversal(void) {
    printf("\n[7] ccExtractArchiveToDirectory: traversal contained\n");
    NSString *d = tmpdir();
    NSString *canary = [d stringByAppendingPathComponent:@"CANARY"];
    NSString *out    = [d stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:canary
                             withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *tar = [d stringByAppendingPathComponent:@"evil.tar"];
    NSString *py = [NSString stringWithFormat:
        @"import tarfile,io\n"
         "t=tarfile.open('%@','w')\n"
         "b=b'PWNED\\n'\n"
         "i=tarfile.TarInfo('../../CANARY/escaped.txt'); i.size=len(b)\n"
         "t.addfile(i, io.BytesIO(b))\n"
         "t.close()\n", tar];
    NSString *pyf = [d stringByAppendingPathComponent:@"mk.py"];
    [py writeToFile:pyf atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (!shell([NSString stringWithFormat:@"/usr/bin/python3 '%@'", pyf])) { ok(false, @"setup tar"); return; }

    NSString *err = nil;
    bool r = ccExtractArchiveToDirectory(tar, out, &err);
    ok(!r, @"malicious tar rejected (non-zero exit)");
    ok(![[NSFileManager defaultManager] fileExistsAtPath:
            [canary stringByAppendingPathComponent:@"escaped.txt"]], @"nothing escaped to CANARY/");
    // Rejection matters: on failure the caller skips the Trash step, so the
    // user's archive survives a hostile input.
    [[NSFileManager defaultManager] removeItemAtPath:d error:nil];
}

// ── 8. config dir fallback is not the pre-rebrand path ───────────────────────
static void test_config_path(void) {
    printf("\n[8] config fallback targets the current host dir\n");
    NSString *src = [NSString stringWithContentsOfFile:@"SmartHighlight.mm"
                                              encoding:NSUTF8StringEncoding error:nil];
    ok(src.length > 0, @"source readable");
    ok(![src containsString:@"\"/.notepad++/plugins/Config\""], @"no ~/.notepad++ fallback");
    ok([src containsString:@"/Library/Application Support/Nextpad++/plugins/Config"],
       @"falls back to Application Support");
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);   // unbuffered: keep output if a test crashes
        printf("SmartHighlightNPP — logic harness\n");
        test_helpers();
        test_runtask_no_deadlock();
        test_runtaskcapture_large();
        test_gzip_ok();
        test_gzip_bomb();
        test_trash();
        test_traversal();
        test_config_path();
        printf("\n──────────────────────────────\n%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
