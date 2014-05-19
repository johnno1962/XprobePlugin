//
//  XprobePluginMenuController.h
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface XprobePluginMenuController : NSObject

@property (nonatomic,strong) IBOutlet NSMenuItem *xprobeMenu;

@property (nonatomic,retain) NSButton *pauseResume;
@property (nonatomic,retain) NSTextView *debugger;

@end
