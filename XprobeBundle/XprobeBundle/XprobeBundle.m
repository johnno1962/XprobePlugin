//
//  XprobeBundle.m
//  XprobeBundle
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#if DEBUG || !SWIFT_PACKAGE
#import "../../Sources/Xprobe/include/Xprobe.h"

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>

@interface CCDirector
+ (CCDirector *)sharedDirector;
+ (id)sharedDeviceConnection;
+ (id)startRemoteInterface;
+ (id)sharedInstance;
@end
#else
#import <Cocoa/Cocoa.h>
#endif

#if 0
static char _inMainFilePath[] = __FILE__;
static const char *_inIPAddresses[] = {"127.0.0.1", NULL};

#define INJECTION_ENABLED
#import "BundleInjection.h"
#else
@interface BundleInjection
+ (float *)_inParameters;
+ (void)loadedNotify:(int)notify hook:(void *)hook;
@end
#endif

@implementation Xprobe(Seeding)

+ (void)load {
#ifdef XPROBE_IPADDR
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self connectTo:XPROBE_IPADDR retainObjects:NO];
    });
#else
#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
    [self connectTo:NULL retainObjects:YES];
#else
    [self connectTo:"127.0.0.1" retainObjects:YES];
#endif
    [self search:@""];

    Class injection = NSClassFromString(@"BundleInjection");
    if ( [injection respondsToSelector:@selector(_inParameters)] )
        [injection loadedNotify:0 hook:NULL];
#endif
}

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
+ (NSArray *)xprobeSeeds {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    [seeds insertObject:app atIndex:0];

    // support for cocos2d
    Class ccDirectorClass = NSClassFromString(@"CCDirector");
    CCDirector *ccDirector = [ccDirectorClass sharedDirector];
    if ( ccDirector )
        [seeds addObject:ccDirector];

    if ( !seeds ) {
        seeds = [NSMutableArray new];

        Class deviceClass = NSClassFromString(@"SPDeviceConnection");
        id deviceInstance = [deviceClass sharedDeviceConnection];
        if ( deviceInstance )
            [seeds addObject:deviceInstance];

        Class interfaceClass = NSClassFromString(@"SPRemoteInterface");
        id interfaceInstance = [interfaceClass startRemoteInterface];
        if ( interfaceInstance )
            [seeds addObject:interfaceInstance];

        Class cacheClass = NSClassFromString(@"SPCompanionAssetCache");
        id cacheInstance = [cacheClass sharedInstance];
        if ( cacheInstance )
            [seeds addObject:cacheInstance];
    }

    return seeds;
}
#else
+ (NSArray *)xprobeSeeds {
    NSApplication *app = [NSApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    if ( app.delegate )
        [seeds insertObject:app.delegate atIndex:0];
    return seeds;
}
#endif
@end
#endif
