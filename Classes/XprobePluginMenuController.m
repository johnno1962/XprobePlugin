//
//  XprobePluginMenuController.m
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "XprobePluginMenuController.h"
#import "XprobeConsole.h"
#import "Xprobe.h"

@interface NSObject(INMethodsUsed)
+ (NSImage *)iconImage_pause;
@end

@interface XprobePluginMenuController()

@property (nonatomic,strong) IBOutlet NSMenuItem *xprobeMenu;

@property (nonatomic,retain) NSButton *pauseResume;
@property (nonatomic,retain) NSTextView *debugger;

@end

@implementation XprobePluginMenuController

+ (void)pluginDidLoad:(NSBundle *)plugin {
    static XprobePluginMenuController *xprobePlugin;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		xprobePlugin = [[self alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:xprobePlugin
                                                 selector:@selector(applicationDidFinishLaunching:)
                                                     name:NSApplicationDidFinishLaunchingNotification object:nil];
	});
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ( ![[NSBundle bundleForClass:[self class]] loadNibNamed:@"XprobePluginMenuController" owner:self topLevelObjects:NULL] )
        NSLog( @"XprobePluginMenuController: Could not load interface." );

	NSMenu *productMenu = [[[NSApp mainMenu] itemWithTitle:@"Product"] submenu];
    [productMenu addItem:[NSMenuItem separatorItem]];
    [productMenu addItem:self.xprobeMenu];

    [XprobeConsole backgroundConnectionService];
}

static __weak id lastKeyWindow;

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    return (lastKeyWindow = [NSApp keyWindow]) != nil &&
        [[lastKeyWindow delegate] respondsToSelector:@selector(document)];
}

- (IBAction)load:sender {
    [self findConsole:[lastKeyWindow contentView]];
    [lastKeyWindow makeFirstResponder:self.debugger];
    if ( ![[[self.pauseResume target] class] respondsToSelector:@selector(iconImage_pause)] ||
        [self.pauseResume image] == [[[self.pauseResume target] class] iconImage_pause] )
        [self.pauseResume performClick:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self performSelector:@selector(findLLDB) withObject:nil afterDelay:.5];
}

- (IBAction)xcode:(id)sender {
    lastKeyWindow = [NSApp keyWindow];
    [Xprobe connectTo:"127.0.0.1" retainObjects:YES];
    [Xprobe search:@""];
}

- (void)findConsole:(NSView *)view {
    for ( NSView *subview in [view subviews] ) {
        if ( [subview isKindOfClass:[NSButton class]] &&
            [(NSButton *)subview action] == @selector(pauseOrResume:) )
            self.pauseResume = (NSButton *)subview;
        if ( [subview class] == NSClassFromString(@"IDEConsoleTextView") )
            self.debugger = (NSTextView *)subview;
        [self findConsole:subview];
    }
}

- (void)findLLDB {

    // do we have lldb's attention?
    if ( [[self.debugger string] rangeOfString:@"27369872639733"].location == NSNotFound ) {
        [self performSelector:@selector(findLLDB) withObject:nil afterDelay:1.];
        [self keyEvent:@"p 27369872639632+101" code:0 after:.1];
        return;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    NSString *loader = [NSString stringWithFormat:@"p (void)[[NSBundle bundleWithPath:@\""
                        "%@/XprobeBundle.bundle\"] load]", [[NSBundle bundleForClass:[self class]] resourcePath]];

    float after = 0;
    [self keyEvent:loader code:0 after:after+=.5];
    [self keyEvent:@"c" code:0 after:after+=.5];
}

- (void)keyEvent:(NSString *)str code:(unsigned short)code after:(float)delay {
    NSEvent *event = [NSEvent keyEventWithType:NSKeyDown location:NSMakePoint(0, 0)
                                 modifierFlags:0 timestamp:0 windowNumber:0 context:0
                                    characters:str charactersIgnoringModifiers:nil
                                     isARepeat:YES keyCode:code];
    if ( [[self.debugger window] firstResponder] == self.debugger )
        [self performSelector:@selector(keyEvent:) withObject:event afterDelay:delay];
    if ( code == 0 )
        [self keyEvent:@"\r" code:36 after:delay+.1];
}

- (void)keyEvent:(NSEvent *)event {
    [[self.debugger window] makeFirstResponder:self.debugger];
    if ( [[self.debugger window] firstResponder] == self.debugger )
        [self.debugger keyDown:event];
}

@end

@implementation Xprobe(Seeding)

+ (NSArray *)xprobeSeeds {
    return @[lastKeyWindow];
}

@end

