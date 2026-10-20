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
- (nullable instancetype)initWithName:(NSString *)name
                           pixelWidth:(NSUInteger)pixelWidth
                          pixelHeight:(NSUInteger)pixelHeight
                                  ppi:(double)ppi
                                hiDPI:(BOOL)hiDPI
                          refreshRate:(double)refreshRate
                         serialNumber:(uint32_t)serialNumber NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// CGDirectDisplayID of the created display (0 after -invalidate).
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSUInteger pixelWidth;
@property (nonatomic, readonly) NSUInteger pixelHeight;
@property (nonatomic, readonly) BOOL hiDPI;

/// Destroys the virtual display (releasing the underlying CGVirtualDisplay object).
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
