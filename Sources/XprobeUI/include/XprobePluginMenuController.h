//
//  XprobePluginMenuController.h
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  $Id: //depot/Xprobe/Sources/XprobeUI/include/XprobePluginMenuController.h#2 $
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface XprobePluginMenuController : NSObject <NSApplicationDelegate>

@property Class injectionPlugin;
@property NSString *dotTmp;

- (IBAction)graph:(id)sender;
- (void)execJS:(NSString *)js;

@end

extern XprobePluginMenuController *xprobePlugin;
