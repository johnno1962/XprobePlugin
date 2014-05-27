//
//  XprobePluginMenuController.m
//  XprobePlugin
//
//  Created by John Holdsworth on 01/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "XprobePluginMenuController.h"

#import <WebKit/WebKit.h>

#import "XprobeConsole.h"
#import "Xprobe.h"

XprobePluginMenuController *xprobePlugin;

@interface NSObject(INMethodsUsed)
+ (NSImage *)iconImage_pause;
@end

@interface XprobePluginMenuController()

@property (nonatomic,strong) IBOutlet NSMenuItem *xprobeMenu;
@property (nonatomic,retain) IBOutlet NSWindow *webWindow;
@property (nonatomic,retain) IBOutlet WebView *webView;

@property (nonatomic,retain) NSButton *pauseResume;
@property (nonatomic,retain) NSTextView *debugger;

@end

@implementation XprobePluginMenuController

+ (void)pluginDidLoad:(NSBundle *)plugin {
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

    [self.webWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

	NSMenu *productMenu = [[[NSApp mainMenu] itemWithTitle:@"Product"] submenu];
    [productMenu addItem:[NSMenuItem separatorItem]];
    [productMenu addItem:self.xprobeMenu];

    [XprobeConsole backgroundConnectionService];
}

- (NSString *)resourcePath {
    return [[NSBundle bundleForClass:[self class]] resourcePath];
}

static __weak id lastKeyWindow;

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ( [menuItem action] == @selector(graph:) )
        return YES;
    else
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
                        "%@/XprobeBundle.bundle\"] load]", [self resourcePath]];

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

- (IBAction)xcode:(id)sender {
    lastKeyWindow = [NSApp keyWindow];
    [Xprobe connectTo:"127.0.0.1" retainObjects:YES];
    [Xprobe search:@""];
}

- (IBAction)graph:(id)sender {
    static NSString *DOT_PATH = @"/usr/local/bin/dot";

    if ( sender )
        [self.webWindow makeKeyAndOrderFront:self];
    else if ( ![self.webWindow isVisible] )
        return;

    if ( ![[NSFileManager defaultManager] fileExistsAtPath:DOT_PATH] ) {
        if ( [[NSAlert alertWithMessageText:@"XprobePlugin" defaultButton:@"OK" alternateButton:@"Go to site"
                                otherButton:nil informativeTextWithFormat:@"Object Graphs of your application "
               "can be displayed if you install \"dot\" from http://www.graphviz.org/. An example object graph "
               "from the cocos2d application \"tweejump\" wil be displayed."] runModal] == NSAlertAlternateReturn )
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://www.graphviz.org/Download_macos.php"]];
    }
    else {
        NSTask *task = [NSTask new];
        task.launchPath = DOT_PATH;
        task.currentDirectoryPath = [self resourcePath];
        task.arguments = @[@"graph.gv", @"-Txdot", @"-ograph-xdot.gv"];

        [task launch];
        [task waitUntilExit];
    }

    NSURL *url = [NSURL fileURLWithPath:[[self resourcePath] stringByAppendingPathComponent:@"canviz.html"]];
    [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
    self.webWindow.title = [NSString stringWithFormat:@"%@ Object Graph", dotConsole ? dotConsole.package : @"Last"];
}

- (IBAction)graphviz:(id)sender {
    NSString *graph = [[self resourcePath] stringByAppendingPathComponent:@"graph.gv"];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:graph]];
}

- (IBAction)graphpng:(id)sender {
    NSString *graph = [[self resourcePath] stringByAppendingPathComponent:@"graph.png"];
    NSView *view = self.webView.mainFrame.frameView.documentView;
    NSSize imageSize = view.bounds.size;
    if ( !imageSize.width || !imageSize.height )
        return;

    NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
    NSData *data = [bir representationUsingType:NSPNGFileType properties:nil];
    [data writeToFile:graph atomically:NO];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:graph]];
}

- (NSString *)webView:(WebView *)sender runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WebFrame *)frame {
    [dotConsole writeString:prompt];
    [dotConsole writeString:defaultText];
    if ( [prompt isEqualToString:@"open:"] ) {
        NSString *scrollToVisble = [NSString stringWithFormat:@"window.scrollTo( 0, $('%@').offsetTop );", defaultText];
        [dotConsole performSelector:@selector(execJS:) withObject:scrollToVisble afterDelay:.1];
        [dotConsole.window makeKeyAndOrderFront:self];
    }
    return nil;
}

- (IBAction)print:sender {
    NSPrintOperation *po=[NSPrintOperation printOperationWithView:self.webView.mainFrame.frameView.documentView];
    [[po printInfo] setOrientation:NSPaperOrientationLandscape];
    //[po setShowPanels:flags];
    [po runOperation];
}

@end

@implementation Xprobe(Seeding)

+ (NSArray *)xprobeSeeds {
    return @[lastKeyWindow];
}

@end

