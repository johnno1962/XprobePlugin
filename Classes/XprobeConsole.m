//
//  XprobeConsole.m
//  XprobePlugin
//
//  Created by John Holdsworth on 18/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//

#import "XprobeConsole.h"

#import "XprobePluginMenuController.h"
#import "Xprobe.h"

#import <WebKit/WebKit.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <sys/stat.h>

__weak XprobeConsole *dotConsole;

static NSMutableDictionary *packagesOpen;

@interface XprobeConsole()

@property (nonatomic,strong) IBOutlet NSMenuItem *separator;
@property (nonatomic,strong) IBOutlet NSMenuItem *menuItem;

@property (nonatomic,assign) IBOutlet WebView *webView;
@property (nonatomic,assign) IBOutlet NSTextView *console;
@property (nonatomic,strong) IBOutlet NSSearchField *search;
@property (nonatomic,strong) IBOutlet NSSearchField *filter;
@property (nonatomic,strong) IBOutlet NSButton *paused;
@property (nonatomic,strong) IBOutlet NSButton *graph;
@property (nonatomic,strong) IBOutlet NSButton *print;

@property (strong) NSMutableArray *lineBuffer;
@property (strong) NSMutableString *incoming;
@property (strong) NSLock *lock;
@property int clientSocket;

@end

@implementation XprobeConsole

static int serverSocket;

+ (void)backgroundConnectionService {

    struct sockaddr_in serverAddr;

    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    serverAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (serverSocket = socket(AF_INET, SOCK_STREAM, 0)) < 0 )
        NSLog(@"XprobeConsole: Could not open service socket: %s", strerror( errno ));
    else if ( fcntl(serverSocket, F_SETFD, FD_CLOEXEC) < 0 )
        NSLog(@"XprobeConsole: Could not set close exec: %s", strerror( errno ));
    else if ( setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof optval) < 0 )
        NSLog(@"XprobeConsole: Could not set socket option: %s", strerror( errno ));
    else if ( setsockopt( serverSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog(@"XprobeConsole: Could not set socket option: %s", strerror( errno ));
    else if ( bind( serverSocket, (struct sockaddr *)&serverAddr, sizeof serverAddr ) < 0 )
        NSLog(@"XprobeConsole: Could not bind service socket: %s. "
              "Kill any \"ibtoold\" processes and restart.", strerror( errno ));
    else if ( listen( serverSocket, 5 ) < 0 )
        NSLog(@"XprobeConsole: Service socket would not listen: %s", strerror( errno ));
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];
}

+ (void)service {

    NSLog(@"XprobeConsole: Waiting for connections...");

    while ( serverSocket ) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof clientAddr;

        int clientSocket = accept( serverSocket, (struct sockaddr *)&clientAddr, &addrLen );
        uint32_t magic;

        NSLog(@"XprobeConsole: Connection from %s", inet_ntoa(clientAddr.sin_addr));

        if ( clientSocket > 0 &&
                read(clientSocket, &magic, sizeof magic)==sizeof magic && magic == XPROBE_MAGIC )
            dispatch_async(dispatch_get_main_queue(), ^{
                (void)[[XprobeConsole alloc] initClient:@(clientSocket)];
            });
        else {
            close( clientSocket );
            [NSThread sleepForTimeInterval:.5];
        }
    }
}

- (NSString *)readString {
    uint32_t length;

    if ( read(_clientSocket, &length, sizeof length) != sizeof length ) {
        NSLog( @"XprobeConsole: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read(_clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"XprobeConsole: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = [NSString stringWithUTF8String:buff];
    free( buff );
    return str;
}

- (void)writeString:(NSString *)str {
    const char *data = [str UTF8String];
    uint32_t length = (uint32_t)strlen(data);

    if ( !_clientSocket )
        NSLog( @"XprobeConsole: Write to closed" );
    else if ( write(_clientSocket, &length, sizeof length ) != sizeof length ||
                write(_clientSocket, data, length ) != length )
        NSLog( @"XprobeConsole: Socket write error %s", strerror(errno) );
}

- (void)execJS:(NSString *)js {
    [[self.webView windowScriptObject] evaluateWebScript:js];
}

- (void)serviceClient {
    NSString *dhtmlOrDotOrTrace;

    while ( (dhtmlOrDotOrTrace = [self readString]) ) {

        if ( [dhtmlOrDotOrTrace hasPrefix:@"$("] )
            dispatch_async(dispatch_get_main_queue(), ^{
                [self execJS:dhtmlOrDotOrTrace];
            });
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"digraph "] ) {
            NSString *saveTo = [[[NSBundle bundleForClass:[self class]] resourcePath]
                                stringByAppendingPathComponent:@"graph.gv"];
            [dhtmlOrDotOrTrace writeToFile:saveTo atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            dotConsole = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [xprobePlugin graph:nil];
            });
        }
        else if ( [dhtmlOrDotOrTrace hasPrefix:@"updates: "] )
            dispatch_async(dispatch_get_main_queue(), ^{
                [[xprobePlugin.webView windowScriptObject] evaluateWebScript:[dhtmlOrDotOrTrace substringFromIndex:9]];
            });
        else {
            [self insertText:dhtmlOrDotOrTrace];
            [self insertText:@"\n"];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.title = [NSString stringWithFormat:@"Disconnected from: %@", self.package];
    });
}

- (id)initClient:(NSNumber *)client {

    if ( _clientSocket ) {
        close( _clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    _clientSocket = [client intValue];
    self.package = [self readString];
    if  ( !self.package )
        return nil;

    if ( !packagesOpen )
        packagesOpen = [NSMutableDictionary new];

    if ( !packagesOpen[self.package] ) {
        packagesOpen[self.package] = self = [super init];

        if ( ![[NSBundle bundleForClass:[self class]] loadNibNamed:@"XprobeConsole" owner:self topLevelObjects:NULL] )
            NSLog( @"XprobeConsole: Could not load interface" );

        [self.window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

        self.menuItem.title = self.package;
        NSMenu *windowMenu = [self windowMenu];
        NSInteger where = [windowMenu indexOfItemWithTitle:@"Bring All to Front"];
        if ( where <= 0 )
            NSLog( @"XprobeConsole: Could not locate Window menu item" );
        else {
            [windowMenu insertItem:self.separator atIndex:where+1];
            [windowMenu insertItem:self.menuItem atIndex:where+2];
        }

        NSRect frame = self.webView.frame;
        NSSize size = self.search.frame.size;
        frame.origin.x = frame.size.width - size.width - 20;
        frame.origin.y = frame.size.height - size.height - 20;
        frame.size = size;
        self.search.frame = frame;
        [self.webView addSubview:self.search];

        frame = self.webView.frame;
        size = self.print.frame.size;
        frame.origin.x = frame.size.width - size.width - 20;
        frame.origin.y = 4;
        frame.size = size;
        self.print.frame = frame;
        [self.webView addSubview:self.print];
        frame.origin.x -= size.width;
        self.graph.frame = frame;
        [self.webView addSubview:self.graph];
    }
    else {
        self = packagesOpen[self.package];
        _clientSocket = [client intValue]; ////
    }

    self.window.title = [NSString stringWithFormat:@"Connected to: %@", self.package];

    NSURL *pageURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"xprobe" withExtension:@"html"];
    [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:pageURL]];

    self.console.string = [NSString stringWithFormat:@"Method Trace output from %@ ...\n", self.package];
    [self.window makeFirstResponder:self.search];
    [self.window makeKeyAndOrderFront:self];
    self.lineBuffer = [NSMutableArray new];
    return self;
}

- (NSMenu *)windowMenu {
    return [[[NSApp mainMenu] itemWithTitle:@"Window"] submenu];
}

- (void)webView:(WebView *)aWebView didFinishLoadForFrame:(WebFrame *)frame {
    [self performSelectorInBackground:@selector(serviceClient) withObject:nil];
}

- (void)webView:(WebView *)webView addMessageToConsole:(NSDictionary *)message; {
    [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
         informativeTextWithFormat:@"JavaScript Error: %@", message] runModal];
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    [[NSAlert alertWithMessageText:@"XprobeConsole" defaultButton:@"OK" alternateButton:nil otherButton:nil
         informativeTextWithFormat:@"JavaScript Alert: %@", message] runModal];
}

- (void)webView:(WebView *)aWebView decidePolicyForNavigationAction:(NSDictionary *)actionInformation
		request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id < WebPolicyDecisionListener >)listener {
    if ( [request.URL isFileURL] )
        [listener use];
    else {
        [[NSWorkspace sharedWorkspace] openURL:request.URL];
        [listener ignore];
    }
}

- (NSString *)webView:(WebView *)sender runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WebFrame *)frame {
    [self writeString:prompt];
    [self writeString:defaultText];
    return nil;
}

- (NSString *)filterLinesByCurrentRegularExpression:(NSArray *)lines
{
    NSMutableString *out = [[NSMutableString alloc] init];
    NSRegularExpression *filterRegexp = [NSRegularExpression regularExpressionWithPattern:self.filter.stringValue
                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    for ( NSString *line in lines ) {
        if ( !filterRegexp ||
            [filterRegexp rangeOfFirstMatchInString:line options:0
                                              range:NSMakeRange(0, [line length])].location != NSNotFound ) {
                [out appendString:line];
                [out appendString:@"\n"];
            }
    }

    return out;
}

- (IBAction)search:(NSSearchField *)sender {
    [self writeString:@"search:"];
    [self writeString:sender.stringValue];
}

- (IBAction)filterChange:sender {
    self.console.string = [self filterLinesByCurrentRegularExpression:self.lineBuffer];
}

- (void)insertText:(NSString *)output {
    if ( !self.lock )
        self.lock = [[NSLock alloc] init];

    [self.lock lock];
    if ( !self.incoming )
        self.incoming = [[NSMutableString alloc] init];
    [self.incoming appendString:output];
    [self.lock unlock];

    [self performSelectorOnMainThread:@selector(insertIncoming) withObject:nil waitUntilDone:NO];
}

- (void)insertIncoming {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];

    if ( !self.incoming )
        return;

    [self.lock lock];
    NSMutableArray *newLlines = [[self.incoming componentsSeparatedByString:@"\n"] mutableCopy];
    [self.incoming setString:@""];
    [self.lock unlock];

    NSUInteger lineCount = [newLlines count];
    if ( lineCount && [newLlines[lineCount-1] length] == 0 )
        [newLlines removeObjectAtIndex:lineCount-1];

    [self.lineBuffer addObjectsFromArray:newLlines];

    if ( ![self.paused state] ) {
        NSString *filtered = [self filterLinesByCurrentRegularExpression:newLlines];
        if ( [filtered length] )
            [self.console insertText:filtered];
    }
}

- (IBAction)pausePlay:sender {
    if ( [self.paused state] ) {
        [self.paused setImage:[self imageNamed:@"play"]];
    }
    else {
        [self.paused setImage:[self imageNamed:@"pause"]];
        [self filterChange:self];
    }
}

- (NSImage *)imageNamed:(NSString *)name {
    return [[NSImage alloc] initWithContentsOfFile:[[NSBundle bundleForClass:[self class]]
                                                    pathForResource:name ofType:@"png"]];
}

- (IBAction)graph:sender {
    [xprobePlugin graph:sender];
}

- (IBAction)print:sender {
    NSPrintOperation *po=[NSPrintOperation printOperationWithView:self.webView.mainFrame.frameView.documentView];
    //[po setShowPanels:flags];
    [po runOperation];
}

- (void)windowWillClose:(NSNotification *)notification {
    close( self.clientSocket );
    self.clientSocket = 0;
    self.webView.UIDelegate = nil;
    [self.webView close];

    NSMenu *windowMenu = [self windowMenu];
    if ( [windowMenu indexOfItem:self.separator] != -1 )
        [windowMenu removeItem:self.separator];
    if ( [windowMenu indexOfItem:self.menuItem] != -1 )
        [windowMenu removeItem:self.menuItem];

    [packagesOpen removeObjectForKey:self.package];
}

@end
