#import "MSSimulatorDisplay.h"
#import <objc/message.h>
#include <dlfcn.h>

NSErrorDomain const MSSimulatorErrorDomain = @"MSSimulatorErrorDomain";

static NSString *const kCoreSimulatorPath =
    @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
static NSString *const kDisplayPortIdentifier = @"com.apple.framebuffer.display";

// SimulatorKit's message builders (private, resolved with dlsym). Signatures come from the
// framework's own debug strings.
typedef void *(*MSMouseMessageFn)(CGPoint *point0, CGPoint *point1, uint32_t target,
                                  NSUInteger eventType, NSSize size, uint32_t edge);
typedef void *(*MSButtonMessageFn)(int keyCode, int operation, uint32_t target);

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
    uint32_t _touchTarget;
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

    _mouseMessage = mouse;
    _buttonMessage = button;
    _hidClient = client;
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
