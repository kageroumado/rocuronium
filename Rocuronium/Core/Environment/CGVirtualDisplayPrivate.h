#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Private CoreGraphics virtual-display API (SkyLight-backed). The macOS 26 SDK exports all
// four class symbols in CoreGraphics.tbd, so they link normally — but no public header
// declares them anywhere in the framework, so this local declaration is what lets Swift
// message the classes. Implementations live in CoreGraphics at runtime.

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int rotation;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int vendorID;
@property(readonly, nonatomic) unsigned int productID;
@property(readonly, nonatomic) unsigned int serialNum;
@property(readonly, nonatomic) CGDirectDisplayID displayID;
@property(readonly, nonatomic) unsigned int hiDPI;
@property(readonly, nonatomic) CGSize sizeInMillimeters;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
