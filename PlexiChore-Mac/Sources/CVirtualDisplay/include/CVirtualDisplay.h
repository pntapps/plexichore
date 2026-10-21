//
//  CVirtualDisplay.h  (umbrella header of the CVirtualDisplay module)
//  PlexiChore
//
//  Small, safe Objective-C wrapper around the private CGVirtualDisplay API.
//  Swift only ever sees PXVirtualDisplay.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface PXVirtualDisplay : NSObject

/// YES when the running macOS exposes the private CGVirtualDisplay classes.
+ (BOOL)isSupported;

/// Creates a virtual display whose framebuffer is `pixelWidth` x `pixelHeight` pixels.
/// When `hiDPI` is YES the display is exposed as a 2x (Retina) display, i.e. the desktop
/// "looks like" pixelWidth/2 x pixelHeight/2 points while still rendering every pixel.
/// `ppi` is used to compute the physical size reported to macOS.
/// Returns nil if the private API is missing or refuses the configuration.
/// MUST be called on the main thread (returns nil otherwise): WindowServer display reconfiguration notifications
/// and the AppKit screen list are main-thread state, and every open-source user of the API creates it there.
- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(NSInteger)pixelWidth
                          pixelHeight:(NSInteger)pixelHeight
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                         serialNumber:(uint32_t)serialNumber NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// CGDirectDisplayID of the created display (0 after -invalidate or WindowServer termination).
/// Thread-safe.
@property (atomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSInteger pixelWidth;
@property (nonatomic, readonly) NSInteger pixelHeight;
@property (nonatomic, readonly) BOOL hiDPI;

/// Called on the main queue if WindowServer terminates the display on its own (not on -invalidate).
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);

/// Destroys the virtual display (releasing the underlying CGVirtualDisplay object). Idempotent and safe to call
/// from ANY thread (the main-thread-stall watchdog and signal handlers use it while the main thread is stuck).
/// Never calls the terminationHandler.
- (void)invalidate;

/// YES once -invalidate ran (from any thread) or WindowServer terminated the display.
@property (atomic, readonly, getter=isInvalidated) BOOL invalidated;

@end

NS_ASSUME_NONNULL_END
