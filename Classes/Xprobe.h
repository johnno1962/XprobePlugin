//
//  Xprobe.h
//  Sweeper
//
//  Created by John Holdsworth on 17/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface Xprobe : NSObject

+ (void)connectTo:(const char *)ipAddress;
+ (void)search:(NSString *)classNamePattern;
+ (BOOL)xprobeExclude:(const char *)className;

@end

@interface Xprobe(Seeding)

+ (NSArray *)xprobeSeeds;

@end