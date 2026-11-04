#import "MSSimulatorDisplay.h"
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <xpc/xpc.h>

NSErrorDomain const MSSimulatorErrorDomain = @"MSSimulatorErrorDomain";

static NSString *const kCoreSimulatorPath =
    @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
static NSString *const kDisplayPortIdentifier = @"com.apple.framebuffer.display";

// SimulatorKit's message builders (private, resolved with dlsym). Signatures come from the
// framework's own debug strings.
typedef void *(*MSMouseMessageFn)(CGPoint *point0, CGPoint *point1, uint32_t target,
                                  NSUInteger eventType, NSSize size, uint32_t edge);
typedef void *(*MSButtonMessageFn)(int keyCode, int operation, uint32_t target);
typedef void *(*MSKeyboardMessageFn)(int usage, int direction);
typedef void *(*MSKeyboardEventFn)(NSEvent *event);
typedef xpc_endpoint_t (*MSEndpointFn)(mach_port_t port);
typedef void (*MSEnableSim2HostFn)(xpc_connection_t connection);

// Xcode 27's CoreSimulator no longer delivers legacy Indigo keyboard events reliably. Keys go to the simulator's
// dtuhidd daemon instead, which is what Xcode's own tooling uses: a CoreDevice "universal HID" service reached
// through a mach lookup on the device. The wire format below was found by probing the daemon and reading its logs.
static NSString *const kUniversalHIDService = @"com.apple.coredevice.feature.remote.universalhidservice";
// The keyboard report is ID 1 followed by one bit per HID usage 0...239; the modifiers are usages 0xE0...0xE7.
static const uint8_t kKeyboardReportID = 1;
enum { kKeyBitmapBytes = 30 };
// What dtuhidd calls the keyboard service, in case it can't be found by name.
static const uint64_t kDefaultKeyboardServiceID = 0x200;

// Mac virtual key code to USB HID usage (US layout). Zero means unmapped.
static const int16_t kUsageForMacKeyCode[128] = {
    [0] = 0x04, [1] = 0x16, [2] = 0x07, [3] = 0x09, [4] = 0x0B, [5] = 0x0A, [6] = 0x1D, [7] = 0x1B, [8] = 0x06,
    [9] = 0x19, [11] = 0x05, [12] = 0x14, [13] = 0x1A, [14] = 0x08, [15] = 0x15, [16] = 0x1C, [17] = 0x17,
    [18] = 0x1E, [19] = 0x1F, [20] = 0x20, [21] = 0x21, [22] = 0x23, [23] = 0x22, [24] = 0x2E, [25] = 0x26,
    [26] = 0x24, [27] = 0x2D, [28] = 0x25, [29] = 0x27, [30] = 0x30, [31] = 0x12, [32] = 0x18, [33] = 0x2F,
    [34] = 0x0C, [35] = 0x13, [36] = 0x28, [37] = 0x0F, [38] = 0x0D, [39] = 0x34, [40] = 0x0E, [41] = 0x33,
    [42] = 0x31, [43] = 0x36, [44] = 0x38, [45] = 0x11, [46] = 0x10, [47] = 0x37, [48] = 0x2B, [49] = 0x2C,
    [50] = 0x35, [51] = 0x2A, [53] = 0x29, [115] = 0x4A, [116] = 0x4B, [117] = 0x4C, [119] = 0x4D, [121] = 0x4E,
    [123] = 0x50, [124] = 0x4F, [125] = 0x51, [126] = 0x52,
};

// Modifier keys arrive as flag changes: the key is down when its flag is now set.
static const struct { unsigned short code; int usage; NSEventModifierFlags flag; } kModifierKeys[] = {
    {56, 0xE1, NSEventModifierFlagShift}, {60, 0xE5, NSEventModifierFlagShift},
    {59, 0xE0, NSEventModifierFlagControl}, {62, 0xE4, NSEventModifierFlagControl},
    {58, 0xE2, NSEventModifierFlagOption}, {61, 0xE6, NSEventModifierFlagOption},
    {55, 0xE3, NSEventModifierFlagCommand}, {54, 0xE7, NSEventModifierFlagCommand},
};

// NSEventType values the mouse builder understands.
static const NSUInteger kMouseDown = 1, kMouseUp = 2, kMouseDragged = 6;
// Button key code and operations for the Home button.
static const int kHomeKeyCode = 0, kButtonDown = 1, kButtonUp = 2;
// The hardware buttons live on the internal display's target.
static const uint32_t kButtonTarget = 0x33;

// The CoreSimulator objects are remote proxies that are not declared anywhere public, so they are
// driven by selector name. A missing selector surfaces as an error, not a crash (see `Call`).
static id Call(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:MSSimulatorErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation MSSimulatorDisplay {
    NSString *_udid;
    NSString *_developerDir;

    // Strong references keep the connection to the device alive while streaming.
    id _device;
    id _descriptor;
    NSUUID *_registration;
    dispatch_queue_t _callbackQueue;

    IOSurface *_latest;
    BOOL _deliveryPending;
    CGSize _pixelSize;
    uint64_t _framesDelivered;

    // Input
    id _hidClient;
    dispatch_queue_t _inputQueue;
    MSMouseMessageFn _mouseMessage;
    MSButtonMessageFn _buttonMessage;
    MSKeyboardMessageFn _keyboardMessage;
    MSKeyboardEventFn _keyboardEventMessage;
    uint32_t _touchTarget;

    // Keyboard transport (Xcode 27+). Only touched on _inputQueue.
    xpc_connection_t _keyboardConnection;
    uint64_t _keyboardServiceID;
    uint8_t _keyBitmap[kKeyBitmapBytes];
    NSDate *_lastKeyboardAttempt;
    BOOL _inputAvailable;
}

@synthesize frameHandler = _frameHandler;
@synthesize inputAvailable = _inputAvailable;

- (instancetype)initWithUDID:(NSString *)udid developerDir:(NSString *)developerDir {
    if ((self = [super init])) {
        _udid = [udid copy];
        _developerDir = [developerDir copy];
        _callbackQueue = dispatch_queue_create("com.leo.mobilestudio.simulator-frames", DISPATCH_QUEUE_SERIAL);
        _inputQueue = dispatch_queue_create("com.leo.mobilestudio.simulator-input", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (IOSurface *)latestFrame {
    @synchronized (self) { return _latest; }
}

- (CGSize)pixelSize {
    @synchronized (self) { return _pixelSize; }
}

- (uint64_t)framesDelivered {
    @synchronized (self) { return _framesDelivered; }
}

#pragma mark - Lookup

/// Finds the device's main display. A booted device exposes several ports with the display
/// identifier; only the real one answers with a framebuffer surface.
- (id)lookupDescriptor:(NSError **)error {
    if (!dlopen(kCoreSimulatorPath.UTF8String, RTLD_NOW)) {
        if (error) *error = MakeError(@"CoreSimulator was not found. Is Xcode installed?");
        return nil;
    }
    Class contextClass = NSClassFromString(@"SimServiceContext");
    SEL contextSel = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
    if (!contextClass || ![contextClass respondsToSelector:contextSel]) {
        if (error) *error = MakeError(@"This Xcode's CoreSimulator is not compatible with Mobile Studio.");
        return nil;
    }

    NSError *underlying = nil;
    id context = ((id (*)(Class, SEL, id, NSError **))objc_msgSend)(contextClass, contextSel, _developerDir, &underlying);
    SEL setSel = NSSelectorFromString(@"defaultDeviceSetWithError:");
    id set = [context respondsToSelector:setSel]
        ? ((id (*)(id, SEL, NSError **))objc_msgSend)(context, setSel, &underlying) : nil;
    if (!set) {
        if (error) *error = MakeError(underlying.localizedDescription ?: @"Could not reach the simulator service.");
        return nil;
    }

    id device = nil;
    for (id candidate in (NSArray *)Call(set, @"devices")) {
        NSUUID *uuid = Call(candidate, @"UDID");
        if ([uuid.UUIDString caseInsensitiveCompare:_udid] == NSOrderedSame) { device = candidate; break; }
    }
    if (!device) {
        if (error) *error = MakeError(@"That simulator no longer exists.");
        return nil;
    }
    _device = device;

    // A booted device lists several ports with the display identifier (the LCD, plus TV-out and
    // wireless displays). Use the internal one: screenType 0.
    id fallback = nil;
    for (id port in (NSArray *)Call(Call(device, @"io"), @"ioPorts")) {
        if (![Call(port, @"portIdentifier") isEqual:kDisplayPortIdentifier]) continue;
        id descriptor = Call(port, @"descriptor");
        if (!Call(descriptor, @"framebufferSurface")) continue;

        id properties = Call(descriptor, @"screenProperties");
        SEL typeSel = NSSelectorFromString(@"screenType"), idSel = NSSelectorFromString(@"screenID");
        if ([properties respondsToSelector:typeSel] && [properties respondsToSelector:idSel]) {
            NSUInteger screenType = ((NSUInteger (*)(id, SEL))objc_msgSend)(properties, typeSel);
            uint32_t screenID = ((uint32_t (*)(id, SEL))objc_msgSend)(properties, idSel);
            if (screenType == 0) {
                // Same rule SimulatorKit uses: external screens (types 1, 2) share target 1,
                // every other screen is addressed by its ID with bit 30 set.
                _touchTarget = screenID | 0x40000000;
                return descriptor;
            }
        }
        if (!fallback) fallback = descriptor;
    }
    if (fallback) { _touchTarget = 0x40000001; return fallback; }
    if (error) *error = MakeError(@"The simulator's display is not ready yet.");
    return nil;
}

#pragma mark - Start / stop

- (void)startWithCompletionHandler:(void (^)(NSError *_Nullable))completionHandler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        id descriptor = nil;
        // The display shows up a few seconds after boot finishes, so retry for a while.
        for (int attempt = 0; attempt < 40 && !descriptor; attempt++) {
            descriptor = [self lookupDescriptor:&error];
            if (!descriptor) [NSThread sleepForTimeInterval:0.25];
        }
        if (!descriptor) {
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(error ?: MakeError(@"Could not attach to the display.")); });
            return;
        }

        self->_descriptor = descriptor;
        self->_registration = [NSUUID UUID];

        // Blocks take no arguments on purpose: the parameters CoreSimulator passes to the
        // "surfaces changed" and "properties changed" callbacks are not needed, and ignoring
        // them is safe whatever their number or type.
        __weak MSSimulatorDisplay *weakSelf = self;
        void (^onFrame)(void) = ^{ [weakSelf frameArrived]; };
        void (^ignored)(void) = ^{};
        SEL registerSel = NSSelectorFromString(@"registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:");
        ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(descriptor, registerSel, self->_registration, self->_callbackQueue, onFrame, onFrame, ignored);

        [self setUpInput];
        [self frameArrived];   // show the current image without waiting for the next change
        dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil); });
    });
}

- (void)stop {
    id descriptor = _descriptor;
    NSUUID *registration = _registration;
    _descriptor = nil;
    _registration = nil;
    _device = nil;
    _hidClient = nil;
    _inputAvailable = NO;
    dispatch_async(_inputQueue, ^{
        if (self->_keyboardConnection) xpc_connection_cancel(self->_keyboardConnection);
        self->_keyboardConnection = nil;
    });
    _frameHandler = nil;
    if (descriptor && registration) {
        SEL sel = NSSelectorFromString(@"unregisterScreenCallbacksWithUUID:");
        if ([descriptor respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(descriptor, sel, registration);
    }
}

#pragma mark - Input

/// Loads SimulatorKit's HID support. Failure is not fatal: the screen still streams, input is off.
- (void)setUpInput {
    NSArray<NSString *> *candidates = @[
        [_developerDir stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework/SimulatorKit"],
        [_developerDir stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"],
    ];
    void *handle = NULL;
    for (NSString *path in candidates) {
        handle = dlopen(path.stringByStandardizingPath.UTF8String, RTLD_NOW);
        if (handle) break;
    }
    if (!handle) return;

    MSMouseMessageFn mouse = (MSMouseMessageFn)dlsym(handle, "IndigoHIDMessageForMouseNSEvent");
    MSButtonMessageFn button = (MSButtonMessageFn)dlsym(handle, "IndigoHIDMessageForButton");
    Class clientClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    SEL initSel = NSSelectorFromString(@"initWithDevice:error:");
    if (!mouse || !button || !clientClass || ![clientClass instancesRespondToSelector:initSel]) return;

    NSError *error = nil;
    id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([clientClass alloc], initSel, _device, &error);
    if (!client) return;

    // Optional: without it the screen and touch still work, only typing is off.
    _keyboardMessage = (MSKeyboardMessageFn)dlsym(handle, "IndigoHIDMessageForKeyboardArbitrary");
    _keyboardEventMessage = (MSKeyboardEventFn)dlsym(handle, "IndigoHIDMessageForKeyboardNSEvent");
    _mouseMessage = mouse;
    _buttonMessage = button;
    _hidClient = client;
    // Without Simulator.app nothing tells the device a hardware keyboard is attached, and iOS then ignores every
    // key we send. Optional: touch still works if the call is missing.
    SEL keyboardSel = NSSelectorFromString(@"setHardwareKeyboardEnabled:keyboardType:error:");
    if ([_device respondsToSelector:keyboardSel]) {
        ((BOOL (*)(id, SEL, BOOL, long, NSError **))objc_msgSend)(_device, keyboardSel, YES, 0, NULL);
    }
    _inputAvailable = YES;
}

/// Hands a built message to the device. The client frees it once sent.
- (void)deliver:(void *)message {
    id client = _hidClient;
    if (!client || !message) return;
    SEL sendSel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    void (^completion)(id) = ^(id error) {};
    ((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(client, sendSel, message, YES, _inputQueue, completion);
}

- (void)sendTouch:(MSTouchPhase)phase atPoint:(CGPoint)point {
    if (!_inputAvailable) return;
    CGPoint clamped = CGPointMake(MIN(MAX(point.x, 0), 1), MIN(MAX(point.y, 0), 1));
    NSUInteger type = phase == MSTouchPhaseBegan ? kMouseDown : phase == MSTouchPhaseMoved ? kMouseDragged : kMouseUp;
    uint32_t target = _touchTarget;
    MSMouseMessageFn build = _mouseMessage;
    dispatch_async(_inputQueue, ^{
        CGPoint p = clamped;
        // A size of 1x1 means the point is already a 0...1 ratio of the screen.
        [self deliver:build(&p, NULL, target, type, NSMakeSize(1, 1), 0)];
    });
}

#pragma mark - Keyboard

/// Connects to dtuhidd's keyboard service when it hasn't yet. Runs on _inputQueue; NO when the runtime doesn't vend it
/// (an older Xcode), in which case the legacy Indigo path is used instead.
- (BOOL)ensureKeyboardTransport {
    if (_keyboardConnection) return YES;
    // Don't hammer a missing service on every key.
    if (_lastKeyboardAttempt && -[_lastKeyboardAttempt timeIntervalSinceNow] < 2) return NO;
    _lastKeyboardAttempt = [NSDate date];

    id device = _device;
    SEL lookup = NSSelectorFromString(@"lookup:error:");
    MSEndpointFn makeEndpoint = (MSEndpointFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    MSEnableSim2HostFn enableSim2Host = (MSEnableSim2HostFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!device || ![device respondsToSelector:lookup] || !makeEndpoint || !enableSim2Host) return NO;

    mach_port_t port = ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(device, lookup, kUniversalHIDService, NULL);
    if (port == MACH_PORT_NULL) return NO;
    xpc_connection_t connection = xpc_connection_create_from_endpoint(makeEndpoint(port));
    if (!connection) return NO;
    enableSim2Host(connection);

    // The daemon drops a peer it can't read, and a shut down device invalidates the connection: reconnect next time.
    __weak MSSimulatorDisplay *weakSelf = self;
    const void *identity = (__bridge const void *)connection;
    xpc_connection_set_target_queue(connection, _inputQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_ERROR) return;
        MSSimulatorDisplay *strongSelf = weakSelf;
        if (strongSelf && (__bridge const void *)strongSelf->_keyboardConnection == identity) {
            strongSelf->_keyboardConnection = nil;
            memset(strongSelf->_keyBitmap, 0, kKeyBitmapBytes);
        }
    });
    xpc_connection_resume(connection);
    _keyboardConnection = connection;
    _keyboardServiceID = kDefaultKeyboardServiceID;
    memset(_keyBitmap, 0, kKeyBitmapBytes);

    // Ask which service is the keyboard, so a renumbered runtime still works. The default is used until it answers.
    xpc_object_t list = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(list, "connectedServices", xpc_dictionary_create(NULL, NULL, 0));
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(request, "payload", list);
    xpc_connection_send_message_with_reply(connection, request, _inputQueue, ^(xpc_object_t reply) {
        if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) return;
        xpc_object_t services = xpc_dictionary_get_value(reply, "connectedServices");
        if (!services || xpc_get_type(services) != XPC_TYPE_ARRAY) return;
        xpc_array_apply(services, ^bool(size_t index, xpc_object_t service) {
            const char *product = xpc_get_type(service) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(service, "Product") : NULL;
            if (product && strstr(product, "keyboard")) {
                uint64_t found = xpc_dictionary_get_uint64(service, "_ServiceID");
                if (found) self->_keyboardServiceID = found;
                return false;
            }
            return true;
        });
    });
    return YES;
}

/// Sends the whole keyboard state as one report: the daemon turns changes between reports into key events.
- (void)sendKeyboardState {
    if (!_keyboardConnection) return;
    uint8_t report[1 + kKeyBitmapBytes];
    report[0] = kKeyboardReportID;
    memcpy(report + 1, _keyBitmap, kKeyBitmapBytes);
    xpc_object_t send = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(send, "_0", report, sizeof report);
    xpc_dictionary_set_uint64(send, "_1", _keyboardServiceID);
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "send", send);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(message, "payload", payload);
    xpc_connection_send_message(_keyboardConnection, message);
}

/// Presses or releases one HID usage. NO when the keyboard transport isn't available.
- (BOOL)setUsage:(int)usage down:(BOOL)down {
    if (usage <= 0 || usage >= kKeyBitmapBytes * 8 || ![self ensureKeyboardTransport]) return NO;
    uint8_t bit = (uint8_t)(1 << (usage % 8));
    if (down) _keyBitmap[usage / 8] |= bit; else _keyBitmap[usage / 8] &= (uint8_t)~bit;
    [self sendKeyboardState];
    return YES;
}

- (void)sendKeyEvent:(NSEvent *)event {
    if (!_inputAvailable) return;
    NSEventType type = event.type;
    int usage = 0;
    BOOL down = type == NSEventTypeKeyDown;
    if (type == NSEventTypeFlagsChanged) {
        for (size_t i = 0; i < sizeof kModifierKeys / sizeof kModifierKeys[0]; i++) {
            if (kModifierKeys[i].code != event.keyCode) continue;
            usage = kModifierKeys[i].usage;
            down = (event.modifierFlags & kModifierKeys[i].flag) != 0;
        }
    } else if (event.keyCode < 128) {
        usage = kUsageForMacKeyCode[event.keyCode];
    }
    MSKeyboardEventFn legacy = _keyboardEventMessage;
    dispatch_async(_inputQueue, ^{
        if (usage && [self setUsage:usage down:down]) return;
        if (legacy && type != NSEventTypeFlagsChanged) [self deliver:legacy(event)];
    });
}

- (void)pressKey:(int)usage shift:(BOOL)shift {
    MSKeyboardMessageFn legacy = _keyboardMessage;
    if (!_inputAvailable) return;
    dispatch_async(_inputQueue, ^{
        const int kLeftShift = 0xE1;
        // iOS drops a key that goes down and up in the same instant, so hold it for a moment like a finger would.
        const NSTimeInterval kHold = 0.05;
        if ([self ensureKeyboardTransport]) {
            if (shift) { [self setUsage:kLeftShift down:YES]; [NSThread sleepForTimeInterval:kHold]; }
            [self setUsage:usage down:YES];
            [NSThread sleepForTimeInterval:kHold];
            [self setUsage:usage down:NO];
            if (shift) [self setUsage:kLeftShift down:NO];
            return;
        }
        if (!legacy) return;
        const int kDown = 1, kUp = 2;
        if (shift) { [self deliver:legacy(kLeftShift, kDown)]; [NSThread sleepForTimeInterval:kHold]; }
        [self deliver:legacy(usage, kDown)];
        [NSThread sleepForTimeInterval:kHold];
        [self deliver:legacy(usage, kUp)];
        if (shift) [self deliver:legacy(kLeftShift, kUp)];
    });
}

- (void)pressHome {
    if (!_inputAvailable) return;
    MSButtonMessageFn build = _buttonMessage;
    dispatch_async(_inputQueue, ^{
        [self deliver:build(kHomeKeyCode, kButtonDown, kButtonTarget)];
        [NSThread sleepForTimeInterval:0.08];
        [self deliver:build(kHomeKeyCode, kButtonUp, kButtonTarget)];
    });
}

#pragma mark - Frames

/// Runs on the callback queue for every frame; hands the newest surface to the main queue.
- (void)frameArrived {
    id descriptor = _descriptor;
    if (!descriptor) return;
    IOSurface *surface = Call(descriptor, @"framebufferSurface");
    if (!surface) return;

    BOOL schedule;
    @synchronized (self) {
        _latest = surface;
        schedule = !_deliveryPending;
        _deliveryPending = YES;
    }
    if (!schedule) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        IOSurface *frame;
        void (^handler)(IOSurface *);
        @synchronized (self) {
            frame = self->_latest;
            self->_deliveryPending = NO;
            self->_pixelSize = CGSizeMake(frame.width, frame.height);
            self->_framesDelivered++;
            handler = self->_frameHandler;
        }
        if (handler && frame) handler(frame);
    });
}

@end
