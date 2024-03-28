//
//  SwwepSeeding.m
//  XprobePlugin
//
//  Created by John Holdsworth on 20/03/2021.
//  Copyright (c) 2021 John Holdsworth. All rights reserved.
//
//  $Id: //depot/XprobePlugin/Sources/Xprobe/SweepSeeding.m#4 $
//

#if DEBUG || !SWIFT_PACKAGE
#import "Xprobe.h"

@implementation Xprobe(Seeding)
+ (NSArray *)xprobeSeeds {
    #ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
    #define XPApplication UIApplication
    #else
    #define XPApplication NSApplication
    #endif
    XPApplication *app = [XPApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    [seeds insertObject:app atIndex:0];
    return seeds;
}
@end
#endif
