#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MSSimulatorErrorDomain;

typedef NS_ENUM(NSInteger, MSTouchPhase) {
    MSTouchPhaseBegan,
    MSTouchPhaseMoved,
    MSTouchPhaseEnded,
};

/// Live view of one booted iOS Simulator's screen.
///
/// Uses Apple's private CoreSimulator framework to attach to the device's framebuffer, the same
/// surface Simulator.app and Xcode draw from. The device does not need a Simulator.app window,
/// and no screen-recording permission is involved. Because the framework is private, this can
/// break when Xcode changes; every failure is reported as an NSError rather than a crash.
NS_SWIFT_SENDABLE
@interface MSSimulatorDisplay : NSObject

/// Called on the main queue with the newest frame. Frames that arrive while a previous one is
/// still being delivered are coalesced, so the handler always sees the latest image.
@property (atomic, copy, nullable) void (^frameHandler)(IOSurface *surface);

/// Pixel size of the most recent frame. Read on the main queue.
@property (atomic, readonly) CGSize pixelSize;

/// Number of frames delivered to `frameHandler` so far.
@property (atomic, readonly) uint64_t framesDelivered;

/// Whether touch and button input could be set up. The screen can still be shown without it.
@property (atomic, readonly) BOOL inputAvailable;

- (instancetype)initWithUDID:(NSString *)udid developerDir:(NSString *)developerDir NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Attaches to the device's display and starts delivering frames. The display can take a few
/// seconds to appear right after a boot, so this retries before giving up.
- (void)startWithCompletionHandler:(void (^)(NSError *_Nullable error))completionHandler;

- (void)stop;

/// Sends one touch event. `point` is normalized to the screen: (0,0) is the top-left corner and
/// (1,1) the bottom-right. A tap is Began then Ended; a swipe is Began, any number of Moved, Ended.
/// Does nothing if input is unavailable.
- (void)sendTouch:(MSTouchPhase)phase atPoint:(CGPoint)point NS_SWIFT_NAME(sendTouch(_:at:));

/// Presses and releases the hardware Home button.
- (void)pressHome;

@end

NS_ASSUME_NONNULL_END
