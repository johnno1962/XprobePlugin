//
//  XprobeBundle.m
//  XprobeBundle
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "Xprobe.h"

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

@interface CCDirector
+ (CCDirector *)sharedDirector;
@end

static char _inMainFilePath[] = __FILE__;
static const char *_inIPAddresses[] = {"127.0.0.1", NULL};

#define INJECTION_ENABLED
#import "BundleInjection.h"

@implementation Xprobe(Seeding)

+ (void)load {
#if TARGET_IPHONE_SIMULATOR
    [self connectTo:"127.0.0.1" retainObjects:YES];
#else
    [self connectTo:NULL retainObjects:YES];
#endif
    [self search:@""];

    Class injection = NSClassFromString(@"BundleInjection");
    [injection loadedNotify:0 hook:NULL];
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
    return seeds;
}
#else
+ (NSArray *)xprobeSeeds {
    return [NSApp windows];
}
#endif
@end
