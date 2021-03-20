//
//  SwwepSeeding.m
//  XprobePlugin
//
//  Created by John Holdsworth on 20/03/2021.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  $Id: //depot/Xprobe/Sources/Xprobe/SweepSeeding.m#2 $
//

#import "Xprobe.h"

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#define _Application UIApplication
#else
#define _Application NSApplication
#endif

@implementation Xprobe(Seeding)
+ (NSArray *)xprobeSeeds {
    _Application *app = [_Application sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    [seeds insertObject:app atIndex:0];
    return seeds;
}
@end
