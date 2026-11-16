// Runs inside macOS on a Henge virtual Mac, as a LaunchAgent. It keeps the clipboard in step with the device,
// keeps the shared folder mounted, and keeps macOS's keyboard layout the device's. It talks to host/share.c at
// 10.0.2.4, which only exists inside Henge.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define HOST "10.0.2.4"

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = 40};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, HOST, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return nil;
    }
    NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: " HOST "\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, path,
                                                (unsigned long)body.length];
    const char *text = head.UTF8String;
    if (send_all(fd, text, strlen(text)) != 0 || (body.length && send_all(fd, body.bytes, body.length) != 0)) {
        close(fd);
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char piece[16384];
    for (;;) {
        ssize_t got = recv(fd, piece, sizeof piece, 0);
        if (got <= 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}

static NSInteger lastChange;

// The device's clipboard, as it changes. The server holds each request until there is something new.
static void followDevice(void) {
    unsigned long seq = 0;
    for (BOOL first = YES;; first = NO) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/clipboard?since=%lu", first ? ULONG_MAX >> 1 : seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = !first && status == 200 && now != seq;
        seq = now; // what the device had before this helper started isn't news
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            lastChange = board.changeCount;
        });
    }
}

// The Mac's clipboard goes to the device, unless the app that copied it marked it as secret.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount == lastChange) return;
    lastChange = board.changeCount;
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"]) return;
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/clipboard", data, &status, NULL);
    });
}

// ---- the keyboard layout ----

// What each key types on macOS's layout now, for Henge to type text with (Keys.type): a first line
// "layout\t<input source ID>\t<ANSI|ISO|JIS>", then one line per character: "<char>\t<vk> <mods>[ <vk> <mods>]",
// mods 1 for Shift and 2 for Option, two pairs for a dead key and the key after it. Fewest modifiers win.
static NSString *keymapText(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return nil;
    CFDataRef data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    NSString *sourceID = (__bridge NSString *)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
    if (!data) {
        CFRelease(source);
        return nil;
    }
    const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
    UInt32 kbd = LMGetKbdType();
    PhysicalKeyboardLayoutType physical = KBGetLayoutType((SInt16)kbd);
    NSString *shape = physical == kKeyboardISO ? @"ISO" : physical == kKeyboardJIS ? @"JIS" : @"ANSI";
    static const UInt32 modifiers[4] = {0, shiftKey, optionKey, shiftKey | optionKey};
    NSMutableDictionary<NSString *, NSString *> *best = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray<NSNumber *> *> *dead = [NSMutableArray array]; // vk, mods, state
    NSString *(^translate)(UInt16, int, UInt32 *) = ^NSString *(UInt16 vk, int mods, UInt32 *state) {
        UniChar chars[8];
        UniCharCount length = 0;
        if (UCKeyTranslate(layout, vk, kUCKeyActionDown, (modifiers[mods] >> 8) & 0xFF, kbd, 0, state, 8, &length, chars) != noErr) return nil;
        return length ? [NSString stringWithCharacters:chars length:length] : @"";
    };
    BOOL (^printable)(NSString *) = ^BOOL(NSString *t) {
        if (!t.length) return NO;
        unichar first = [t characterAtIndex:0];
        return first >= 0x20 && first != 0x7f && !(first >= 0xF700 && first <= 0xF8FF);
    };
    for (int mods = 0; mods < 4; mods++)
        for (UInt16 vk = 0; vk <= 50; vk++) {
            if (vk == 36 || vk == 48) continue; // Return and Tab
            UInt32 state = 0;
            NSString *t = translate(vk, mods, &state);
            if (state) [dead addObject:@[ @(vk), @(mods), @(state) ]];
            else if (printable(t) && !best[t]) best[t] = [NSString stringWithFormat:@"%u %d", vk, mods];
        }
    for (NSArray<NSNumber *> *d in dead) {
        UInt16 dvk = d[0].unsignedShortValue;
        int dmods = d[1].intValue;
        for (int mods = 0; mods < 4; mods++)
            for (UInt16 vk = 0; vk <= 50; vk++) {
                if (vk == 36 || vk == 48) continue;
                UInt32 state = d[2].unsignedIntValue;
                NSString *t = translate(vk, mods, &state);
                if (!state && printable(t) && t.length == 1 && !best[t])
                    best[t] = [NSString stringWithFormat:@"%u %d %u %d", dvk, dmods, vk, mods];
            }
    }
    CFRelease(source);
    NSMutableString *out = [NSMutableString stringWithFormat:@"layout\t%@\t%@\n", sourceID ?: @"?", shape];
    [best enumerateKeysAndObjectsUsingBlock:^(NSString *ch, NSString *keys, BOOL *stop) {
        (void)stop;
        [out appendFormat:@"%@\t%@\n", ch, keys];
    }];
    return out;
}

static void sendKeymap(void) {
    NSData *data = [keymapText() dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/keymap", data, &status, NULL);
    });
}

// Turns on and selects an input source, e.g. com.apple.keylayout.German. On the main thread.
static void selectLayout(NSString *sourceID) {
    NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID : sourceID};
    CFArrayRef list = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, true);
    if (!list) return;
    if (CFArrayGetCount(list) > 0) {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(list, 0);
        TISEnableInputSource(source);
        TISSelectInputSource(source);
    }
    CFRelease(list);
}

// The layout the device asks for, as it changes (at start, whatever it has now).
static void followKeyboard(void) {
    unsigned long seq = 0;
    for (;;) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/keyboard?since=%lu", seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = status == 200 && now != seq;
        seq = now;
        if (!news) continue;
        NSString *sourceID = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!sourceID.length) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            selectLayout(sourceID);
            sendKeymap(); // also sent by the change notification; this covers a layout that was already selected
        });
    }
}

static void layoutChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    (void)center, (void)observer, (void)name, (void)object, (void)info;
    sendKeymap();
}

static NSString *mountPoint(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge"]; }

// The shared folder, at ~/Henge. mount_webdav needs an empty folder it owns, and is a no-op failure if it is mounted.
static void keepMounted(void) {
    NSString *point = mountPoint();
    [NSFileManager.defaultManager createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0 || stat(NSHomeDirectory().fileSystemRepresentation, &parent) != 0) return;
    if (folder.st_dev != parent.st_dev) return; // already something else's volume: mounted
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/mount_webdav"];
    task.arguments = @[ @"-S", @"-v", @"Henge", @"http://" HOST "/", point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
}

int main(void) {
    @autoreleasepool {
        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followKeyboard(); });
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, layoutChanged,
                                        kTISNotifySelectedKeyboardInputSourceChanged, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        sendKeymap();
        keepMounted();
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
