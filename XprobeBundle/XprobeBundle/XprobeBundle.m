//
//  XprobeBundle.m
//  XprobeBundle
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "Xprobe.h"

#import <UIKit/UIKit.h>

@implementation Xprobe(roots)

+ (void)load {
    [self connectTo:"127.0.0.1"];
    [self search:@""];
}

+ (NSArray *)xprobeRoots {
    return @[[UIApplication sharedApplication]];
}

@end


