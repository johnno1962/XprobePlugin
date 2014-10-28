//
//  XprobeBundle.m
//  XprobeBundle
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "Xprobe.h"

#import <UIKit/UIKit.h>

@interface CCDirector
+ (CCDirector *)sharedDirector;
@end

@implementation Xprobe(Seeding)

+ (void)load {
    [self connectTo:"127.0.0.1" retainObjects:YES];
    [self search:@""];
}

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

@end

static char _inMainFilePath[] = __FILE__;
static const char *_inIPAddresses[] = {"127.0.0.1", NULL};

#define INJECTION_ENABLED
#import "BundleInjection.h"

