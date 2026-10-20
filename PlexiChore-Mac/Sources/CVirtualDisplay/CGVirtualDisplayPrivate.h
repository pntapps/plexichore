//
//  CGVirtualDisplayPrivate.h
//  PlexiChore
//
//  Declarations for the PRIVATE CoreGraphics virtual display classes
//  (CGVirtualDisplayDescriptor / CGVirtualDisplaySettings / CGVirtualDisplayMode / CGVirtualDisplay),
//  available since macOS 11. Reconstructed from the CoreGraphics binary, matching the
//  declarations used by Chromium (ui/display/mac/test/virtual_display_util_mac.mm),
//  DeskPad and similar open-source projects.
//
//  NOTE: These are NOT public API. Never instantiate them with `[CGVirtualDisplay alloc]`
//  (that would emit a hard link-time reference to _OBJC_CLASS_$_CGVirtualDisplay);
//  always go through NSClassFromString() — see PXVirtualDisplay.m.
//
//  This header is intentionally NOT in include/, so Swift never sees it.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (strong, nonatomic) NSArray *modes;     // NSArray<CGVirtualDisplayMode *>
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (strong, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic, nullable) id terminationHandler;   // void (^)(id, CGVirtualDisplay *)
- (instancetype)init;
- (nullable dispatch_queue_t)dispatchQueue;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSArray *modes;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
