//
//  XprobeConsole.h
//  SweeperApp
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface XprobeConsole : NSObject <NSWindowDelegate,NSTextViewDelegate>

+ (void)backgroundConnectionService;

@end
