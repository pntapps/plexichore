//
//  PXVirtualDisplay.m
//  PlexiChore
//

#import "CVirtualDisplay.h"
#import "CGVirtualDisplayPrivate.h"

#if !__has_feature(objc_arc)
#error "PXVirtualDisplay.m must be compiled with ARC (-fobjc-arc)"
#endif

@implementation PXVirtualDisplay {
    // Strong reference: the virtual display lives exactly as long as this object is retained.
    id _display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(NSUInteger)pixelWidth
                          pixelHeight:(NSUInteger)pixelHeight
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                         serialNumber:(uint32_t)serialNumber {
    self = [super init];
    if (self == nil) { return nil; }
    if (![PXVirtualDisplay isSupported]) { return nil; }
    if (pixelWidth < 64 || pixelHeight < 64) { return nil; }

    if (ppi < 50.0) { ppi = 110.0; }
    if (refreshRate < 1.0) { refreshRate = 60.0; }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass    = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass       = NSClassFromString(@"CGVirtualDisplayMode");

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    if (descriptor == nil) { return nil; }

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
    // sRGB-ish primaries (same values Chromium uses).
    descriptor.redPrimary   = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary  = CGPointMake(0.1494, 0.0557);
    descriptor.whitePoint   = CGPointMake(0.3125, 0.3291);

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (display == nil) { return nil; }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    if (settings == nil) { return nil; }
    settings.hiDPI = hiDPI ? 1 : 0;

    // With hiDPI the mode is expressed in points (half the backing pixel size).
    unsigned int modeWidth  = (unsigned int)(hiDPI ? pixelWidth / 2 : pixelWidth);
    unsigned int modeHeight = (unsigned int)(hiDPI ? pixelHeight / 2 : pixelHeight);
    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:modeWidth
                                                           height:modeHeight
                                                      refreshRate:refreshRate];
    if (mode == nil) { return nil; }
    settings.modes = @[ mode ];

    if (![display applySettings:settings]) {
        // Retry once without HiDPI — some configurations reject a 2x mode.
        if (hiDPI) {
            CGVirtualDisplayMode *flat = [[modeClass alloc] initWithWidth:(unsigned int)pixelWidth
                                                                   height:(unsigned int)pixelHeight
                                                              refreshRate:refreshRate];
            settings.hiDPI = 0;
            settings.modes = flat ? @[ flat ] : @[];
            if (flat == nil || ![display applySettings:settings]) { return nil; }
            hiDPI = NO;
        } else {
            return nil;
        }
    }

    _display = display;
    _displayID = display.displayID;
    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    _hiDPI = hiDPI;
    if (_displayID == 0) { _display = nil; return nil; }
    return self;
}

- (void)invalidate {
    _display = nil;
    _displayID = 0;
}

- (void)dealloc {
    _display = nil;
}

@end
