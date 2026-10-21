//
//  PXVirtualDisplay.m
//  PlexiChore
//

#import "CVirtualDisplay.h"
#import "CGVirtualDisplayPrivate.h"
#import <os/lock.h>

#if !__has_feature(objc_arc)
#error "PXVirtualDisplay.m must be compiled with ARC (-fobjc-arc)"
#endif

@implementation PXVirtualDisplay {
    // Strong reference: the virtual display lives exactly as long as this object is retained.
    // Guarded by _lock (the watchdog / signal handlers may invalidate from a background thread).
    id _display;
    CGDirectDisplayID _displayID;
    BOOL _invalidated;
    os_unfair_lock _lock;
}

@synthesize displayID = _displayID;
@synthesize invalidated = _invalidated;

- (CGDirectDisplayID)displayID {
    os_unfair_lock_lock(&_lock);
    CGDirectDisplayID v = _displayID;
    os_unfair_lock_unlock(&_lock);
    return v;
}

- (BOOL)isInvalidated {
    os_unfair_lock_lock(&_lock);
    BOOL v = _invalidated;
    os_unfair_lock_unlock(&_lock);
    return v;
}

/// Detaches the CGVirtualDisplay under the lock and returns it so the caller releases it OUTSIDE the lock
/// (the release talks to WindowServer and may block). Returns nil when already detached.
- (nullable id)px_detach {
    os_unfair_lock_lock(&_lock);
    id d = _display;
    _display = nil;
    _displayID = 0;
    _invalidated = YES;
    os_unfair_lock_unlock(&_lock);
    return d;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(NSInteger)pixelWidth
                          pixelHeight:(NSInteger)pixelHeight
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                         serialNumber:(uint32_t)serialNumber {
    self = [super init];
    if (self == nil) { return nil; }
    _lock = OS_UNFAIR_LOCK_INIT;
    if (![NSThread isMainThread]) { return nil; }
    if (![PXVirtualDisplay isSupported]) { return nil; }
    if (pixelWidth < 64 || pixelHeight < 64) { return nil; }
    // A 2x mode needs maxPixels >= 2 x points exactly; odd sizes would silently fall back to 1x.
    if (hiDPI) { pixelWidth &= ~(NSInteger)1; pixelHeight &= ~(NSInteger)1; }

    // Autoreleased temporaries must not keep the CGVirtualDisplay (and so the screen) alive.
    @autoreleasepool {
        if (![self setUpWithName:name pixelWidth:pixelWidth pixelHeight:pixelHeight ppi:ppi
                            hiDPI:hiDPI refreshRate:refreshRate serialNumber:serialNumber]) {
            return nil;
        }
    }
    return self;
}

- (BOOL)setUpWithName:(NSString *)name
           pixelWidth:(NSInteger)pixelWidth
          pixelHeight:(NSInteger)pixelHeight
                  ppi:(double)ppi
                hiDPI:(BOOL)hiDPI
          refreshRate:(double)refreshRate
         serialNumber:(uint32_t)serialNumber {

    if (ppi < 50.0) { ppi = 110.0; }
    if (refreshRate < 1.0) { refreshRate = 60.0; }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass    = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass       = NSClassFromString(@"CGVirtualDisplayMode");

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    if (descriptor == nil) { return NO; }

    [descriptor setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)pixelWidth;
    descriptor.maxPixelsHigh = (unsigned int)pixelHeight;
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * (double)pixelWidth / ppi,
                                              25.4 * (double)pixelHeight / ppi);
    // macOS 14+ requires a non-zero vendor id and a serial number unique per display.
    descriptor.vendorID = 0x5058;   // 'PX'
    descriptor.productID = 0x0001;
    descriptor.serialNum = serialNumber == 0 ? 1 : serialNumber;
    __weak PXVirtualDisplay *weakSelf = self;
    // Runs on the descriptor's (global) queue; the block captures only a weak reference, so it never keeps the
    // wrapper (or, through it, the display) alive.
    descriptor.terminationHandler = ^(id _Nullable unused, id _Nullable display) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PXVirtualDisplay *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.isInvalidated) { return; }   // our own -invalidate: no callback
            @autoreleasepool {
                id dead = [strongSelf px_detach];
                dead = nil;   // release WindowServer's dead object now
            }
            void (^handler)(void) = strongSelf.terminationHandler;
            if (handler) { handler(); }
        });
    };
    // sRGB-ish primaries (same values Chromium uses).
    descriptor.redPrimary   = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary  = CGPointMake(0.1494, 0.0557);
    descriptor.whitePoint   = CGPointMake(0.3125, 0.3291);

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (display == nil) { return NO; }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    if (settings == nil) { return NO; }
    settings.hiDPI = hiDPI ? 1 : 0;

    // With hiDPI the mode is expressed in points (half the backing pixel size).
    unsigned int modeWidth  = (unsigned int)(hiDPI ? pixelWidth / 2 : pixelWidth);
    unsigned int modeHeight = (unsigned int)(hiDPI ? pixelHeight / 2 : pixelHeight);
    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:modeWidth
                                                           height:modeHeight
                                                      refreshRate:refreshRate];
    if (mode == nil) { return NO; }
    settings.modes = @[ mode ];

    if (![display applySettings:settings]) {
        // Retry once without HiDPI — some configurations reject a 2x mode.
        if (hiDPI) {
            CGVirtualDisplayMode *flat = [[modeClass alloc] initWithWidth:(unsigned int)pixelWidth
                                                                   height:(unsigned int)pixelHeight
                                                              refreshRate:refreshRate];
            settings.hiDPI = 0;
            settings.modes = flat ? @[ flat ] : @[];
            if (flat == nil || ![display applySettings:settings]) { return NO; }
            hiDPI = NO;
        } else {
            return NO;
        }
    }

    CGDirectDisplayID newID = display.displayID;
    if (newID == 0) { return NO; }   // `display` is released when the caller's autorelease pool drains
    os_unfair_lock_lock(&_lock);
    _display = display;
    _displayID = newID;
    os_unfair_lock_unlock(&_lock);
    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    _hiDPI = hiDPI;
    return YES;
}

- (void)invalidate {
    @autoreleasepool {
        id d = [self px_detach];
        d = nil;   // last strong reference: WindowServer removes the display here
    }
}

- (void)dealloc {
    // No lock needed: nothing else can reference us any more.
    _display = nil;
}

@end
