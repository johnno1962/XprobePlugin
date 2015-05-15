//
//  Xprobe.m
//  XprobePlugin
//
//  Created by John Holdsworth on 17/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  For full licensing term see https://github.com/johnno1962/XprobePlugin
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

/*
 *  This is the source for the Xprobe memory scanner. While it connects as a client
 *  it effectively operates as a service for the Xcode browser window receiving
 *  the arguments to JavaScript "prompt()" calls. The first argument is the
 *  selector to be called in the Xprobe class. The second is an arugment 
 *  specifying the part of the page to be modified, generally the pathID 
 *  which also identifies the object the user action is related to. In 
 *  response, the selector sends back JavaScript to be executed in the
 *  browser window or, if an object has been traced, trace output.
 *
 *  The pathID is the index into the paths array which contain objects from which
 *  the object referred to can be determined rather than pass back and forward
 *  raw memory addresses. Initially, this is the number of the root object from
 *  the original search but as you browse through objects or ivars and arrays a
 *  path is built up of these objects so when the value of an ivar browsed to 
 *  changes it will be reflected in the browser when you next click on it.
 */

#ifdef DEBUG

#import "Xprobe.h"

//#import "Xtrace.h"
@interface Xtrace: NSObject
+ (void)setDelegate:delegate;
+ (void)traceClass:(Class)aClass;
+ (void)traceInstance:(id)instance;
+ (void)traceInstance:(id)instance class:(Class)aClass;
+ (void)notrace:(id)instance;
@end

@interface Xprobe(Seeding)
+ (NSArray *)xprobeSeeds;
@end

@interface XprobeSwift : NSObject
+ (NSString *)convert:(void *)stringPtr;
@end

#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <vector>
#import <map>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

static NSString *swiftPrefix = @"_TtC";

#pragma mark options

static BOOL logXprobeSweep = NO, retainObjects = YES;
static unsigned maxArrayItemsForGraphing = 20, currentMaxArrayIndex;

#pragma mark sweep state

struct _xsweep {
    unsigned sequence, depth;
    __unsafe_unretained id from;
    const char *source;
    std::map<__unsafe_unretained id,unsigned> owners;
};

static struct _xsweep sweepState;

static std::map<__unsafe_unretained id,struct _xsweep> instancesSeen;
static std::map<__unsafe_unretained Class,std::vector<__unsafe_unretained id> > instancesByClass;
static std::map<__unsafe_unretained id,BOOL> instancesTraced;

static NSMutableArray *paths;
static NSLock *writeLock;

#pragma mark "dot" object graph rendering

#define MESSAGE_POLL_INTERVAL .1
#define HIGHLIGHT_PERSIST_TIME 2

struct _animate {
    NSTimeInterval lastMessageTime;
    NSString *color;
    unsigned sequence, callCount;
    BOOL highlighted;
};

static std::map<__unsafe_unretained id,struct _animate> instancesLabeled;

typedef NS_OPTIONS(NSUInteger, XGraphOptions) {
    XGraphArrayWithoutLmit       = 1 << 0,
    XGraphInterconnections       = 1 << 1,
    XGraphAllObjects             = 1 << 2,
    XGraphWithoutExcepton        = 1 << 3,
    XGraphIncludedOnly           = 1 << 4,
};

static NSString *graphOutlineColor = @"#000000", *graphHighlightColor = @"#ff0000";

static XGraphOptions graphOptions;
static NSMutableString *dotGraph;

static unsigned graphEdgeID;
static BOOL graphAnimating;

#pragma mark snapshot capture

char snapshotInclude[] =
"<html><head>\n\
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n\
<style>\n\
\n\
body { background: #e0f0ff; }\n\
body, table { font: 10pt Arial; }\n\
\n\
span.typeStyle { color: green; }\n\
span.classStyle { color: blue; }\n\
\n\
span.protoStyle { }\n\
span.propsStyle { }\n\
span.methodStyle { }\n\
\n\
a.linkClicked { color: purple; }\n\
span.snapshotStyle { display: none; }\n\
\n\
form { margin: 0px }\n\
\n\
td.indent { width: 20px; }\n\
td.drilldown { border: 1px inset black; background-color:rgba(245,222,179,0.5); border-radius: 10px; padding: 10px; padding-top: 7px; box-shadow: 5px 5px 5px #888888; }\n\
\n\
.kitclass { display: none; }\n\
.kitclass > span > a:link { color: grey; }\n\
\n\
</style>\n\
<script>\n\
\n\
function $(id) {\n\
    return id ? document.getElementById(id) : document.body;\n\
}\n\
\n\
function sendClient(selector,pathID,ID,force) {\n\
    var element = $('ID'+ID);\n\
    if ( element ) {\n\
        if ( force || element.style.display != 'block' ) {\n\
            var el = element;\n\
            while ( element ) {\n\
                element.style.display = 'block';\n\
                element = element.parentElement;\n\
            }\n\
            if ( force )\n\
              var offsetY = 0;\n\
              while ( el ) {\n\
                offsetY += el.offsetTop;\n\
                el = el.offsetParent || el.parentElement;\n\
              }\n\
              if ( offsetY )\n\
                window.scrollTo( 0, offsetY );\n\
        }\n\
        else\n\
            element.style.display = 'none';\n\
    }\n\
    return false;\n\
}\n\
\n\
function kitswitch(checkbox) {\n\
    var divs = document.getElementsByTagName('DIV');\n\
\n\
    for ( var i=0 ; i<divs.length ; i++ )\n\
        if ( divs[i].className == 'kitclass' )\n\
            divs[i].style.display = checkbox.checked ? 'none' : 'block';\n\
}\n\
\n\
</script>\n\
</head>\n\
<body>\n\
<b>Application Memory Snapshot</b>\n\
(<input type=checkbox onclick='kitswitch(this);' checked/> - Filter out \"kit\" instances)<br/>\n";

@interface SnapshotString : NSObject {
    FILE *out;
}
- (void)appendFormat:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2);
@end

@implementation SnapshotString

- (instancetype)initPath:(NSString *)path {
    if ( (self = [super init]) ) {
        if ( !(out = fopen( [path UTF8String], "w" )) ) {
            NSLog( @"Xprobe: Could not save snapshot to path: %@", path );
            return nil;
        }
        [self write:snapshotInclude];
    }
    return self;
}

- (int)write:(const char *)chars {
  return fputs( chars, out );
}

- (void)appendString:(NSString *)aString {
    NSString *unescaped = [aString stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
    [self write:[unescaped UTF8String]];
}

- (void)appendFormat:(NSString *)format, ... {
    va_list argp; va_start(argp, format);
    return [self appendString:[[NSString alloc] initWithFormat:format arguments:argp]];
}

- (void)dealloc {
    if ( out )
        fclose( out );
}

@end

#define ZIPPED_SNAPSHOTS
#ifdef ZIPPED_SNAPSHOTS
#import <zlib.h>

@interface SnapshotZipped : SnapshotString {
    gzFile zout;
}
@end

@implementation SnapshotZipped

- (instancetype)initPath:(NSString *)path {
    if ( (self = [super init]) ) {
        if ( !(zout = gzopen( [path UTF8String], "w" )) ) {
            NSLog( @"Xprobe: Could not save snapshot to path: %@", path );
            return nil;
        }
        [self write:snapshotInclude];
    }
    return self;
}

- (int)write:(const char *)chars {
    return gzputs( zout, chars );
}

- (void)dealloc {
    if ( zout )
        gzclose( zout );
}

@end
#endif

static SnapshotString *snapshot;
static NSRegularExpression *snapshotExclusions;
static std::map<__unsafe_unretained Class,std::map<__unsafe_unretained id,int> > instanceIDs;
static int instanceID;

#pragma mark support for Objective-C++ reference classes

static const char *isOOType( const char *type ) {
    return strncmp( type, "{OO", 3 ) == 0 ? strstr( type, "\"ref\"" ) : NULL;
}

static BOOL isCFType( const char *type ) {
    return type && strncmp( type, "^{__CF", 6 ) == 0;
}

static NSString *utf8String( const char *chars ) {
    return chars ? [NSString stringWithUTF8String:chars] : @"";
}

template <class _M,typename _K>
static inline bool exists( const _M &map, const _K &key ) {
    return map.find(key) != map.end();
}

static const char *ivar_getTypeEncodingSwift( Ivar, Class );

@interface NSObject(Xprobe)

#pragma mark forward references

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html;

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar type:(const char *)type into:(NSMutableString *)html;
- (void)xopenPathID:(int)pathID into:(NSMutableString *)html;

- (NSString *)xlinkForProtocol:(NSString *)protocolName;
- (NSString *)xhtmlEscape;
- (void)xsweep;

#pragma mark ivar handling

- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value;
- (id)xvalueForIvar:(Ivar)ivar inClass:(Class)aClass;
- (NSString *)xtype:(const char *)type;
- (id)xvalueForKeyPath:(NSString *)key;
- (id)xvalueForMethod:(Method)method;
- (id)xvalueForKey:(NSString *)key;

@end

@interface NSObject(XprobeReferences)

#pragma mark external references

- (NSString *)base64EncodedStringWithOptions:(NSUInteger)options;
+ (const char *)connectedAddress;
- (NSArray *)getNSArray;
- (NSArray *)subviews;

- (void)onXprobeEval;
- (void)injected;

- (id)contentView;
- (id)document;
- (id)delegate;
- (SEL)action;
- (id)target;

@end

/*****************************************************
 ******** classes that go to make up a path **********
 *****************************************************/

static const char *seedName = "seed", *superName = "super";

@interface XprobePath : NSObject
@property int pathID;
@property const char *name;
@end

@implementation XprobePath

+ (id)withPathID:(int)pathID {
    XprobePath *path = [self new];
    path.pathID = pathID;
    return path;
}

- (int)xadd {
    int newPathID = (int)paths.count;
    [paths addObject:self];
    return newPathID;
}

- (int)xadd:(__unsafe_unretained id)obj {
    return instancesSeen[obj].sequence = [self xadd];
}

- (id)object {
    return [paths[self.pathID] object];
}

- (id)aClass {
    return object_getClass([self object]);
}

- (NSMutableString *)xpath {
    if ( self.name == seedName ) {
        NSMutableString *path = [NSMutableString new];
        [path appendFormat:@"%@", utf8String(seedName)];
        return path;
    }

    NSMutableString *path = [paths[self.pathID] xpath];
    if ( self.name != superName )
        [path appendFormat:@".%@", utf8String(self.name)];
    return path;
}

@end

// these two classes determine
// whether objects are retained

@interface XprobeRetained : XprobePath
@property (nonatomic,retain) id object;
@end

@implementation XprobeRetained
@end

@interface XprobeAssigned : XprobePath
@property (nonatomic,assign) id object;
@end

@implementation XprobeAssigned
@end

@interface XprobeIvar : XprobePath
@property Class iClass;
@end

@implementation XprobeIvar

- (id)object {
    id obj = [super object];
    Ivar ivar = class_getInstanceVariable(self.iClass, self.name);
    return [obj xvalueForIvar:ivar inClass:self.iClass];
}

@end

@interface XprobeMethod : XprobePath
@end

@implementation XprobeMethod

- (id)object {
    id obj = [super object];
    Method method = class_getInstanceMethod([obj class], sel_registerName(self.name));
    return [obj xvalueForMethod:method];
}

@end

@interface XprobeArray : XprobePath
@property NSUInteger sub;
@end

@implementation XprobeArray

- (NSArray *)array {
    return [super object];
}

- (id)object {
    NSArray *arr = [self array];
    if ( self.sub < [arr count] )
        return arr[self.sub];
    NSLog( @"Xprobe: %@ reference %d beyond end of array %d",
          NSStringFromClass([self class]), (int)self.sub, (int)[arr count] );
    return nil;
}

- (NSMutableString *)xpath {
    NSMutableString *path = [paths[self.pathID] xpath];
    [path appendFormat:@".%d", (int)self.sub];
    return path;
}

@end

@interface XprobeSet : XprobeArray
@end

@implementation XprobeSet

- (NSArray *)array {
    return [[paths[self.pathID] object] allObjects];
}

@end

@interface XprobeView : XprobeArray
@end

@implementation XprobeView

- (NSArray *)array {
    return [[paths[self.pathID] object] subviews];
}

@end

@interface XprobeDict : XprobePath
@property id sub;
@end

@implementation XprobeDict

- (id)object {
    return [[super object] objectForKey:self.sub];
}

- (NSMutableString *)xpath {
    NSMutableString *path = [paths[self.pathID] xpath];
    [path appendFormat:@".%@", self.sub];
    return path;
}

@end

@interface XprobeSuper : XprobePath
@property Class aClass;
@end

@implementation XprobeSuper
@end

// class without instance
@interface XprobeClass : XprobeSuper
@end

@implementation XprobeClass

- (id)object {
    return self;
}

@end

@implementation NSRegularExpression(Xprobe)

+ (NSRegularExpression *)xsimpleRegexp:(NSString *)pattern {
    NSError *error = nil;
    NSRegularExpression *regexp = [[NSRegularExpression alloc] initWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&error];
    if ( error && [pattern length] )
    NSLog( @"Xprobe: Filter compilation error: %@, in pattern: \"%@\"", [error localizedDescription], pattern );
    return regexp;
}

- (BOOL)xmatches:(NSString *)str  {
    return [self rangeOfFirstMatchInString:str options:0 range:NSMakeRange(0, [str length])].location != NSNotFound;
}

@end

/*****************************************************
 ********* implmentation of Xprobe service ***********
 *****************************************************/

#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>

static int clientSocket;

@implementation Xprobe

+ (NSString *)revision {
    return @"$Id: //depot/XprobePlugin/Classes/Xprobe.mm#204 $";
}

+ (BOOL)xprobeExclude:(NSString *)className {
    static NSRegularExpression *excluded;
    if ( !excluded )
        excluded = [NSRegularExpression xsimpleRegexp:@"^(_|NS|XC|IDE|DVT|Xcode3|IB|VK|WebHistory|UI(Input|Transition))"];
    return [excluded xmatches:className] && ![className hasPrefix:swiftPrefix];
}

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain {

    if ( !ipAddress ) {
        Class injectionLoader = NSClassFromString(@"BundleInjection");
        if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] )
            ipAddress = [injectionLoader connectedAddress];
    }

    if ( !ipAddress )
        ipAddress = "127.0.0.1";

    retainObjects = shouldRetain;

    NSLog( @"Xprobe: Connecting to %s", ipAddress );

    if ( clientSocket ) {
        close( clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    struct sockaddr_in loaderAddr;

    loaderAddr.sin_family = AF_INET;
	inet_aton( ipAddress, &loaderAddr.sin_addr );
	loaderAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (clientSocket = socket(loaderAddr.sin_family, SOCK_STREAM, 0)) < 0 )
        NSLog( @"Xprobe: Could not open socket for injection: %s", strerror( errno ) );
    else if ( connect( clientSocket, (struct sockaddr *)&loaderAddr, sizeof loaderAddr ) < 0 )
        NSLog( @"Xprobe: Could not connect: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog( @"Xprobe: Could not set TCP_NODELAY: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &optval, sizeof(optval) ) < 0 )
        NSLog( @"Xprobe: Could not set SO_NOSIGPIPE: %s", strerror( errno ) );
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];

#if 1 // Add xprobe NSObject methods to SwiftObject
    Class swiftRoot = objc_getClass( "SwiftObject" );
    if ( swiftRoot ) {
        unsigned mc;
        Method *methods = class_copyMethodList( [NSObject class], &mc );
        for ( unsigned i=0 ; i<mc ; i++ ) {
            Method method = methods[i];
            SEL methodSEL = method_getName( method );
            const char *methodName = sel_getName( methodSEL );
            if ( methodName[0] == 'x' || strncmp( methodName, "method", 6 ) == 0 ) {
                if ( !class_addMethod( swiftRoot, methodSEL,
                                      method_getImplementation( method ),
                                      method_getTypeEncoding( method ) ) )
                    NSLog( @"Xprobe: Could not add SwiftObject method: %s %p %s", methodName,
                          method_getImplementation( method ), method_getTypeEncoding( method ) );
            }
        }
        free( methods );
    }
#endif
}

+ (void)service {

    uint32_t magic = XPROBE_MAGIC;
    if ( write(clientSocket, &magic, sizeof magic ) != sizeof magic ) {
        close( clientSocket );
        return;
    }

    [self writeString:[[NSBundle mainBundle] bundleIdentifier]];

    while ( clientSocket ) {
        NSString *command = [self readString];
        if ( !command )
            break;
        NSString *argument = [self readString];
        if ( !argument )
            break;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:NSSelectorFromString( command ) withObject:argument];
#pragma clang diagnostic pop
    }

    NSLog( @"Xprobe: Service loop exits" );
    close( clientSocket );
}

+ (NSString *)readString {
    uint32_t length;

    if ( read( clientSocket, &length, sizeof length ) != sizeof length ) {
        NSLog( @"Xprobe: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read( clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"Xprobe: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        free( buff );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = utf8String( buff );
    free( buff );
    return str;
}

+ (void)writeString:(NSString *)str {
    const char *data = [str UTF8String];
    uint32_t length = (uint32_t)strlen(data);

    if ( !writeLock )
        writeLock = [NSLock new];
    [writeLock lock];

    if ( !clientSocket )
        NSLog( @"Xprobe: Write to closed" );
    else if ( write( clientSocket, &length, sizeof length ) != sizeof length ||
             write( clientSocket, data, length ) != length )
        NSLog( @"Xprobe: Socket write error %s", strerror(errno) );

    [writeLock unlock];
}

+ (void)xlog:(NSString *)message {
    NSString *output = [[message xhtmlEscape] stringByReplacingOccurrencesOfString:@"  " withString:@" \\&#160;"];
    [self writeString:[NSString stringWithFormat:@"$('OUTPUT%d').innerHTML += '%@<br/>';", lastPathID, output]];
}

static NSString *lastPattern;

+ (void)search:(NSString *)pattern {
    [self performSelectorOnMainThread:@selector(_search:) withObject:pattern waitUntilDone:NO];
}

+ (void)_search:(NSString *)pattern {

    pattern = [pattern stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ( [pattern hasPrefix:@"0x"] ) {

        // raw pointers entered as 0xNNN.. search
        XprobeRetained *path = [XprobeRetained new];
        path.object = [path xvalueForKeyPath:pattern];
        path.name = strdup( [[NSString stringWithFormat:@"%p", path.object] UTF8String] );
        [self open:[[NSNumber numberWithInt:[path xadd]] stringValue]];
        return;
    }
    else if ( [pattern hasPrefix:@"seed."] ) {

        // recovery of object from a KVO-like path
        @try {

            NSArray *keys = [pattern componentsSeparatedByString:@"."];
            id obj = [paths[0] object];

            for ( int i=1 ; i<[keys count] ; i++ ) {
                obj = [obj xvalueForKey:keys[i]];

                int pathID;
                if ( !exists( instancesSeen, obj ) ) {
                    XprobeRetained *path = [XprobeRetained new];
                    path.object = [[paths[0] object] xvalueForKeyPath:[pattern substringFromIndex:[@"seed." length]]];
                    path.name = strdup( [[NSString stringWithFormat:@"%p", path.object] UTF8String] );
                    pathID = [path xadd];
                }
                else
                    pathID = instancesSeen[obj].sequence;

                [self open:[[NSNumber numberWithInt:pathID] stringValue]];
            }
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: keyPath error: %@", e );
        }
        return;
    }

    NSLog( @"Xprobe: sweeping memory, filtering by '%@'", pattern );
    dotGraph = [NSMutableString stringWithString:@"digraph sweep {\n"
                "    node [href=\"javascript:void(click_node('\\N'))\" id=\"\\N\" fontname=\"Arial\"];\n"];

    if ( pattern != lastPattern ) {
        lastPattern = pattern;
        graphOptions = 0;
    }
    
    NSArray *seeds = [self xprobeSeeds];
    if ( !seeds.count )
        NSLog( @"Xprobe: no seeds returned from xprobeSeeds category" );

    [self performSweep:seeds];

    [dotGraph appendString:@"}\n"];
    [self writeString:dotGraph];
    dotGraph = nil;

    NSMutableString *html = [NSMutableString new];
    [html appendString:@"$().innerHTML = '<b>Application Memory Sweep</b> "
     "(<input type=checkbox onclick=\"kitswitch(this);\" checked> - Filter out \"kit\" instances)<p/>"];

    // various types of earches
    unichar firstChar = [pattern length] ? [pattern characterAtIndex:0] : 0;
    if ( (firstChar == '+' || firstChar == '-') && [pattern length] > 3 )
        [self findMethodsMatching:[pattern substringFromIndex:1] type:firstChar into:html];
    else
        [self filterSweepOutputBy:pattern into:html];

    [html appendString:@"';"];
    [self writeString:html];

    if ( graphAnimating )
        [self animate:@"1"];
}

+ (void)performSweep:(NSArray *)seeds {
    instancesSeen.clear();
    instancesByClass.clear();
    instancesLabeled.clear();

    sweepState.sequence = sweepState.depth = 0;
    sweepState.source = seedName;
    graphEdgeID = 1;

    paths = [NSMutableArray new];
    [seeds xsweep];

    NSLog( @"Xprobe: sweep complete, %d objects found", (int)paths.count );
}

+ (void)filterSweepOutputBy:(NSString *)pattern into:(NSMutableString *)html {
    // original search by instance's class name
    NSRegularExpression *classRegexp = [NSRegularExpression xsimpleRegexp:pattern];
    std::map<__unsafe_unretained id,int> matchedObjects;

    for ( const auto &byClass : instancesByClass )
        if ( !classRegexp || [classRegexp xmatches:NSStringFromClass(byClass.first)] )
            for ( const auto &instance : byClass.second )
                matchedObjects[instance]++;

    if ( !matchedObjects.empty() ) {

        for ( int pathID=0, count = (int)paths.count ; pathID < count ; pathID++ ) {
            id obj = [paths[pathID] object];

            if( matchedObjects[obj] ) {
                const char *className = class_getName([obj class]);
                BOOL isUIKit = className[0] == '_' || strncmp(className, "NS", 2) == 0 ||
                    strncmp(className, "UI", 2) == 0 || strncmp(className, "CA", 2) == 0;

                [html appendFormat:@"<div%@>", isUIKit ? @" class=\\'kitclass\\'" : @""];

                struct _xsweep &info = instancesSeen[obj];
                for ( unsigned i=1 ; i<info.depth ; i++ )
                    [html appendString:@"&#160; &#160; "];

                [obj xlinkForCommand:@"open" withPathID:info.sequence into:html];
                [html appendString:@"</div>"];
            }
        }
    }
    else
        if ( ![self findClassesMatching:classRegexp into:html] )
            [html appendString:@"No root objects or classes found, check class name pattern.<br/>"];
}

+ (NSUInteger)findClassesMatching:(NSRegularExpression *)classRegexp into:(NSMutableString *)html {

    unsigned ccount;
    Class *classes = objc_copyClassList( &ccount );
    NSMutableArray *classesFound = [NSMutableArray new];

    for ( unsigned i=0 ; i<ccount ; i++ ) {
        NSString *className = NSStringFromClass(classes[i]);
        if ( [classRegexp xmatches:className] && className.length > 1 && [className characterAtIndex:1] != '_' )
            [classesFound addObject:className];
    }

    free( classes );

    [classesFound sortUsingSelector:@selector(caseInsensitiveCompare:)];

    for ( NSString *className in classesFound ) {
        XprobeClass *path = [XprobeClass new];
        path.aClass = NSClassFromString(className);
        [path xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@"<br/>"];
    }

    return [classesFound count];
}

+ (void)findMethodsMatching:(NSString *)pattern type:(unichar)firstChar into:(NSMutableString *)html {

    NSRegularExpression *methodRegexp = [NSRegularExpression xsimpleRegexp:pattern];
    NSMutableDictionary *classesFound = [NSMutableDictionary new];

    unsigned ccount;
    Class *classes = objc_copyClassList( &ccount );
    for ( unsigned i=0 ; i<ccount ; i++ ) {
        Class aClass = firstChar=='+' ? object_getClass(classes[i]) : classes[i];
        NSMutableString *methodsFound = nil;

        unsigned mc;
        Method *methods = class_copyMethodList(aClass, &mc);
        for ( unsigned i=0 ; i<mc ; i++ ) {
            NSString *methodName = NSStringFromSelector(method_getName(methods[i]));
            if ( [methodRegexp xmatches:methodName] ) {
                if ( !methodsFound )
                    methodsFound = [NSMutableString stringWithString:@"<br/>"];
                [methodsFound appendFormat:@"&#160; &#160; %@%@<br/>", [NSString stringWithCharacters:&firstChar length:1], methodName];
            }
        }

        if ( methodsFound )
            classesFound[NSStringFromClass(classes[i])] = methodsFound;

        free( methods );
    }

    for ( NSString *className in [[classesFound allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] )
        if ( [className characterAtIndex:1] != '_' && [html length] < 500000 ) {
            XprobeClass *path = [XprobeClass new];
            path.aClass = NSClassFromString(className);
            [path xlinkForCommand:@"open" withPathID:[path xadd] into:html];
            [html appendString:classesFound[className]];
        }
}

+ (void)regraph:(NSString *)input {
    graphOptions = [input intValue];
    [self search:lastPattern];
}

+ (void)snapshot:(NSString *)filepath {
    dispatch_async( dispatch_get_main_queue(), ^{
        [self snapshot:filepath seeds:[self xprobeSeeds]];
    } );
}

+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds {
    return [self snapshot:filepath seeds:seeds excluding:SNAPSHOT_EXCLUSIONS];
}

+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds excluding:(NSString *)exclusions {

    if ( ![filepath hasPrefix:@"/"] ) {
        NSString *tmp = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0];
        filepath = [tmp stringByAppendingPathComponent:filepath];
    }

    instanceIDs.clear();
    [self performSweep:seeds];

    Class writer =
#ifdef ZIPPED_SNAPSHOTS
        [filepath hasSuffix:@".gz"] ? [SnapshotZipped class] :
#endif
        [SnapshotString class];
    snapshot = [[writer alloc] initPath:filepath];

    NSString *hostname  = @"";
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
    hostname = [[UIDevice currentDevice] name];
#endif
    [snapshot appendFormat:@"%@ &#160;%@ &#160;%@<p/>", [NSDate date],
     [NSBundle mainBundle].infoDictionary[@"CFBundleIdentifier"], hostname];

    snapshotExclusions = [NSRegularExpression xsimpleRegexp:exclusions];
    [self filterSweepOutputBy:@"" into:(NSMutableString *)snapshot];
    [snapshot appendString:@"</body></html>"];
    snapshot = nil;

    if ( clientSocket )
        [self writeString:[NSString stringWithFormat:@"snapshot: %@",
                           [[NSData dataWithContentsOfFile:filepath] base64EncodedStringWithOptions:0]]];
    return filepath;
}

static int lastPathID;

+ (void)open:(NSString *)input {
    lastPathID = [input intValue];
    XprobePath *path = paths[lastPathID];
    id obj = [path object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", lastPathID];
    [obj xlinkForCommand:@"close" withPathID:lastPathID into:html];

    [html appendString:@"<br/>"];
    [self xopen:obj withPathID:lastPathID into:html];
    [html appendString:@"';"];
    [self writeString:html];

    if ( ![path isKindOfClass:[XprobeSuper class]] )
        [self writeString:[path xpath]];
}

+ (void)xopen:(NSObject *)obj withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"<table><tr><td class=\\'indent\\'/><td class=\\'drilldown\\'>"];
    [obj xopenPathID:pathID into:html];
    [html appendString:@"</td></tr></table></span>"];
}

+ (void)eval:(NSString *)input {
    lastPathID = [input intValue];
}

+ (void)complete:(NSString *)input {
    Class aClass = [paths[[input intValue]] aClass];
    NSMutableString *html = [NSMutableString new];

    [html appendString:@"$(); window.properties = '"];

    unsigned pc;
    objc_property_t *props;
    do {
        props = class_copyPropertyList(aClass, &pc);
        aClass = class_getSuperclass(aClass);
    } while ( pc == 0 && aClass != [NSObject class] );

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *name = property_getName(props[i]);
        [html appendFormat:@"%s%@", i ? "," : "", utf8String( name )];
    }

    [html appendString:@"'.split(',');"];
    [self writeString:html];
}

+ (void)injectedClass:(Class)aClass {
    id lastObject = lastPathID < paths.count ? [paths[lastPathID] object] : nil;

    if ( (!aClass || [lastObject isKindOfClass:aClass]) ) {
        if ( [lastObject respondsToSelector:@selector(onXprobeEval)] )
            [lastObject onXprobeEval];
        else if ([lastObject respondsToSelector:@selector(injected)] )
            [lastObject injected];
    }

    if ( aClass )
        [self writeString:[NSString stringWithFormat:@"$('BUSY%d').hidden = true; "
                           "$('SOURCE%d').disabled = prompt('known:','%@') ? false : true;",
                           lastPathID, lastPathID, NSStringFromClass(aClass)]];
}

+ (void)close:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"open" withPathID:pathID into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)properties:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('P%d').outerHTML = '<span class=\\'propsStyle\\'><br/><br/>", pathID];

    unsigned pc;
    objc_property_t *props = class_copyPropertyList(aClass, &pc);
    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        NSString *utf8Name = utf8String( name );

        [html appendFormat:@"@property () %@ <span onclick=\\'this.id =\"P%d\"; "
            "sendClient( \"property:\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@</span>; // %@<br/>",
            [self xtype:attrs+1], pathID, pathID, utf8Name, utf8Name,
            utf8String( attrs )];
    }

    free( props );

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)methods:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('M%d').outerHTML = '<br/><span class=\\'methodStyle\\'>"
         "Method Filter: <input type=textfield size=10 onchange=\\'methodFilter(this);\\'>", pathID];

    Class stopClass = aClass == [NSObject class] ? Nil : [NSObject class];
    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
    [self dumpMethodType:"+" forClass:object_getClass(bClass) original:aClass pathID:pathID into:html];

    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
    [self dumpMethodType:"-" forClass:bClass original:aClass pathID:pathID into:html];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)dumpMethodType:(const char *)mtype forClass:(Class)aClass original:(Class)original
                pathID:(int)pathID into:(NSMutableString *)html {
    unsigned mc;
    Method *methods = class_copyMethodList(aClass, &mc);
    NSString *hide = aClass == original ? @"" :
    [NSString stringWithFormat:@" style=\\'display:none;\\' title=\\'%@\\'",
     NSStringFromClass(aClass)];

    if ( mc && ![hide length] )
        [html appendString:@"<br/>"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        NSString *utf8Name = utf8String( name );

        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse signature for %@, '%s': %@", utf8Name, type, e );
        }

        NSArray *bits = [utf8Name componentsSeparatedByString:@":"];
        [html appendFormat:@"<div sel=\\'%@\\'%@>%s (%@)",
         utf8Name, hide, mtype, [self xtype:[sig methodReturnType]]];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", bits[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"M%d\"; sendClient( \"method:\", \"%d,%@\" );"
                "event.cancelBubble = true;\\'>%@</span> ", pathID, pathID, utf8Name, utf8Name];

        [html appendString:@";</div>"];
    }

    free( methods );
}

+ (void)protocol:(NSString *)protoName {
    Protocol *protocol = NSProtocolFromString(protoName);
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%@').outerHTML = '<span id=\\'%@\\'><a href=\\'#\\' onclick=\\'sendClient( \"_protocol:\", \"%@\"); "
         "event.cancelBubble = true; return false;\\'>%@</a><p/><table><tr><td/><td class=\\'indent\\'/><td>"
         "<span class=\\'protoStyle\\'>@protocol %@", protoName, protoName, protoName, protoName, protoName];

    unsigned pc;
    Protocol *__unsafe_unretained *protos = protocol_copyProtocolList(protocol, &pc);
    if ( pc ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<pc ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protocolName]];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@"<br/>"];

    objc_property_t *props = protocol_copyPropertyList(protocol, &pc);

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ %@; // %@<br/>", [self xtype:attrs+1],
         utf8String( name ), utf8String( attrs )];
    }

    free( props );

    [self dumpMethodsForProtocol:protocol required:YES instance:NO into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:NO into:html];

    [self dumpMethodsForProtocol:protocol required:YES instance:YES into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:YES into:html];

    [html appendString:@"<br/>@end<p/></span></td></tr></table></span>';"];
    [self writeString:html];
}

// Thanks to http://bou.io/ExtendedTypeInfoInObjC.html !
extern "C" const char *_protocol_getMethodTypeEncoding(Protocol *,SEL,BOOL,BOOL);

+ (void)dumpMethodsForProtocol:(Protocol *)protocol required:(BOOL)required instance:(BOOL)instance into:(NSMutableString *)html {

    unsigned mc;
    objc_method_description *methods = protocol_copyMethodDescriptionList( protocol, required, instance, &mc );
    if ( !mc )
        return;

    [html appendFormat:@"<br/>@%@<br/>", required ? @"required" : @"optional"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(methods[i].name);
        const char *type;// = methods[i].types;
        NSString *utf8Name = utf8String( name );

        type = _protocol_getMethodTypeEncoding(protocol, methods[i].name, required,instance);
        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse protocol signature for %@, '%@': %@",
                  utf8Name, utf8String( type ), e );
        }

        NSArray *parts = [utf8Name componentsSeparatedByString:@":"];
        [html appendFormat:@"%s (%@)", instance ? "-" : "+", [self xtype:[sig methodReturnType]]];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", a-2 < [parts count] ? parts[a-2] : @"?",
                    [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"%@", utf8Name];

        [html appendString:@" ;<br/>"];
    }

    free( methods );
}

+ (void)_protocol:(NSString *)protocolName {
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%@').outerHTML = '%@';",
         protocolName, [html xlinkForProtocol:protocolName]];
    [self writeString:html];
}

+ (void)views:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('V%d').outerHTML = '<br/>", pathID];
    [self subviewswithPathID:pathID indent:0 into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)subviewswithPathID:(int)pathID indent:(int)indent into:(NSMutableString *)html {
    id obj = [paths[pathID] object];
    for ( int i=0 ; i<indent ; i++ )
        [html appendString:@"&#160; &#160; "];

    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"<br/>"];

    NSArray *subviews = [obj subviews];
    for ( int i=0 ; i<[subviews count] ; i++ ) {
        XprobeView *path = [XprobeView withPathID:pathID];
        path.sub = i;
        [self subviewswithPathID:[path xadd] indent:indent+1 into:html];
    }
}

static std::map<unsigned,NSTimeInterval> edgesCalled;
static OSSpinLock edgeLock;

+ (void)trace:(NSString *)input {
    int pathID = [input intValue];
    XprobePath *path = paths[pathID];
    id obj = [path object];
    Class aClass = [path aClass];

    Class xTrace = objc_getClass("Xtrace");
    [xTrace setDelegate:self];
    if ( [path class] == [XprobeClass class] ) {
        [xTrace traceClass:obj = aClass];
        [self writeString:[NSString stringWithFormat:@"Tracing [%@ class]", NSStringFromClass(aClass)]];
    }
    else {
        [xTrace traceInstance:obj class:aClass]; ///
        instancesTraced[obj] = YES;
        [self writeString:[NSString stringWithFormat:@"Tracing <%@ %p>", NSStringFromClass(aClass), obj]];
    }
}

+ (void)traceclass:(NSString *)input {
    XprobeClass *path = [XprobeClass new];
    path.aClass = [paths[[input intValue]] aClass];
    [self trace:[NSString stringWithFormat:@"%d", [path xadd]]];
}

+ (void)untrace:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];
    [objc_getClass("Xtrace") notrace:obj];
    auto i = instancesTraced.find(obj);
    if ( i != instancesTraced.end() )
        instancesTraced.erase(i);
}

+ (void)xtrace:(NSString *)trace forInstance:(void *)optr indent:(int)indent {
    __unsafe_unretained id obj = (__bridge __unsafe_unretained id)optr;

    if ( !graphAnimating || exists( instancesTraced, obj ) )
        [self writeString:trace];

    if ( graphAnimating && !dotGraph ) {
        OSSpinLockLock(&edgeLock);

        struct _animate &info = instancesLabeled[obj];
        info.lastMessageTime = [NSDate timeIntervalSinceReferenceDate];
        info.callCount++;

        static __unsafe_unretained id callStack[1000];
        if ( indent >= 0 && indent < sizeof callStack / sizeof callStack[0] ) {
            callStack[indent] = obj;

            __unsafe_unretained id caller = callStack[indent-1];
            std::map<__unsafe_unretained id,unsigned> &owners = instancesSeen[obj].owners;
            if ( indent > 0 && obj != caller && exists( owners, caller ) ) {
                edgesCalled[owners[caller]] = info.lastMessageTime;
            }
        }

        OSSpinLockUnlock(&edgeLock);
    }
}

+ (void)animate:(NSString *)input {
    BOOL wasAnimating = graphAnimating;
  Class xTrace = objc_getClass("Xtrace");
    if ( (graphAnimating = [input intValue]) ) {
        edgeLock = OS_SPINLOCK_INIT;
        [xTrace setDelegate:self];

        for ( const auto &graphing : instancesLabeled ) {
            const char *className = object_getClassName( graphing.first );
            if (
#if TARGET_OS_IPHONE
                strncmp( className, "NS", 2 ) != 0 &&
#endif
                strncmp( className, "__", 2 ) != 0 )
                [xTrace traceInstance:graphing.first];
        }

        if ( !wasAnimating )
            [self performSelectorInBackground:@selector(sendUpdates) withObject:nil];

        NSLog( @"Xprobe: traced %d objects", (int)instancesLabeled.size() );
    }
    else
        for ( const auto &graphing : instancesLabeled )
            if ( exists( instancesTraced, graphing.first ) )
                [xTrace notrace:graphing.first];
}

+ (void)sendUpdates {
    while ( graphAnimating ) {
        NSTimeInterval then = [NSDate timeIntervalSinceReferenceDate];
        [NSThread sleepForTimeInterval:MESSAGE_POLL_INTERVAL];

        if ( !dotGraph ) {
            NSMutableString *updates = [NSMutableString new];
            std::vector<unsigned> expired;

            OSSpinLockLock(&edgeLock);

            for ( auto &called : edgesCalled )
                if ( called.second > then )
                    [updates appendFormat:@" colorEdge('%u','%@');", called.first, graphHighlightColor];
                else if ( called.second < then - HIGHLIGHT_PERSIST_TIME ) {
                    [updates appendFormat:@" colorEdge('%u','%@');", called.first, graphOutlineColor];
                    expired.push_back(called.first);
                }

            for ( auto &edge : expired )
                edgesCalled.erase(edge);

            OSSpinLockUnlock(&edgeLock);

            if ( [updates length] ) {
                [updates insertString:@" startEdge();" atIndex:0];
                [updates appendString:@" stopEdge();"];
            }

            for ( auto &graphed : instancesLabeled )
                if ( graphed.second.lastMessageTime > then ) {
                    [updates appendFormat:@" $('%u').style.color = '%@'; $('%u').title = 'Messaged %d times';",
                        graphed.second.sequence, graphHighlightColor, graphed.second.sequence, graphed.second.callCount];
                    graphed.second.highlighted = TRUE;
                }
                else if ( graphed.second.highlighted && graphed.second.lastMessageTime < then - HIGHLIGHT_PERSIST_TIME ) {
                    [updates appendFormat:@" $('%u').style.color = '%@';", graphed.second.sequence, graphOutlineColor];
                    graphed.second.highlighted = FALSE;
                }

            if ( [updates length] )
                [self writeString:[@"updates:" stringByAppendingString:updates]];
        }
    }
}

struct _xinfo {
    int pathID;
    id obj;
    Class aClass;
    NSString *name, *value;
};

+ (struct _xinfo)parseInput:(NSString *)input {
    NSArray *parts = [input componentsSeparatedByString:@","];
    struct _xinfo info;

    info.pathID = [parts[0] intValue];
    info.obj = [paths[info.pathID] object];
    info.aClass = [paths[info.pathID] aClass];
    info.name = parts[1];

    if ( [parts count] >= 3 )
        info.value = parts[2];

    return info;
}

+ (void)ivar:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);
    const char *type = ivar_getTypeEncodingSwift(ivar,info.aClass);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('I%d').outerHTML = '", info.pathID];
    [info.obj xspanForPathID:info.pathID ivar:ivar type:type into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)edit:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '"
        "<span id=E%d><input type=textfield size=10 value=\\'%@\\' "
        "onchange=\\'sendClient(\"save:\", \"%d,%@,\"+this.value );\\'></span>';",
        info.pathID, info.pathID, [info.obj xvalueForIvar:ivar inClass:info.aClass],
        info.pathID, info.name];

    [self writeString:html];
}

+ (void)save:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    if ( !ivar )
        NSLog( @"Xprobe: could not find ivar \"%@\" in %@", info.name, info.obj);
    else
        if ( ![info.obj xvalueForIvar:ivar update:info.value] )
            NSLog( @"Xprobe: unable to update ivar \"%@\" in %@", info.name, info.obj);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '<span onclick=\\'this.id =\"E%d\"; "
        "sendClient( \"edit:\", \"%d,%@\" ); event.cancelBubble = true;\\'><i>%@</i></span>';",
        info.pathID, info.pathID, info.pathID, info.name, [info.obj xvalueForIvar:ivar inClass:info.aClass]];

    [self writeString:html];
}

+ (void)property:(NSString *)input {
    struct _xinfo info = [self parseInput:input];

    objc_property_t prop = class_getProperty(info.aClass, [info.name UTF8String]);
    char *getter = property_copyAttributeValue(prop, "G");

    SEL sel = sel_registerName( getter ? getter : [info.name UTF8String] );
    if ( getter )
        free( getter );

    Method method = class_getInstanceMethod(info.aClass, sel);
    [self methodLinkFor:info method:method prefix:"P" command:"property:"];
}

+ (void)method:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Method method = class_getInstanceMethod(info.aClass, NSSelectorFromString(info.name));
    [self methodLinkFor:info method:method prefix:"M" command:"method:"];
}

+ (void)methodLinkFor:(struct _xinfo &)info method:(Method)method
               prefix:(const char *)prefix command:(const char *)command {
    id result = method ? [info.obj xvalueForMethod:method] : @"nomethod";

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%s%d').outerHTML = '<span onclick=\\'"
         "this.id =\"%s%d\"; sendClient( \"%s\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@ = ",
         prefix, info.pathID, prefix, info.pathID, command, info.pathID, info.name, info.name];

    if ( result && method && method_getTypeEncoding(method)[0] == '@' ) {
        XprobeMethod *subpath = [XprobeMethod withPathID:info.pathID];
        subpath.name = sel_getName(method_getName(method));
        [result xlinkForCommand:@"open" withPathID:[subpath xadd] into:html];
    }
    else
        [html appendFormat:@"%@", result ? result : @"nil"];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)owners:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('O%d').outerHTML = '<p/>", pathID];

    for ( auto owner : instancesSeen[obj].owners ) {
        int pathID = instancesSeen[owner.first].sequence;
        [owner.first xlinkForCommand:@"open" withPathID:pathID into:html];
        [html appendString:@"&#160; "];
    }

    [html appendString:@"<p/>';"];
    [self writeString:html];
}

+ (void)siblings:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('S%d').outerHTML = '<p/>", pathID];

    for ( const auto &obj : instancesByClass[aClass] ) {
        XprobeRetained *path = [XprobeRetained new];
        path.object = obj;
        [obj xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@" "];
    }

    [html appendString:@"<p/>';"];
    [self writeString:html];
}

+ (void)render:(NSString *)input {
    int pathID = [input intValue];
    __block NSData *data = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        UIView *view = [paths[pathID] object];
        if ( ![view respondsToSelector:@selector(layer)] )
            return;

        UIGraphicsBeginImageContext(view.frame.size);
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        data = UIImagePNGRepresentation(image);
        UIGraphicsEndImageContext();
#else
        NSView *view = [paths[pathID] object];
        NSSize imageSize = view.bounds.size;
        if ( !imageSize.width || !imageSize.height )
            return;

        NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
        data = [bir representationUsingType:NSPNGFileType properties:nil];
#endif
    });

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '<span id=\\'R%d\\'><p/>"
         "<img src=\\'data:image/png;base64,%@\\' onclick=\\'sendClient(\"_render:\", \"%d\"); "
         "event.cancelBubble = true;\\'><p/></span>';", pathID, pathID,
         [data base64EncodedStringWithOptions:0], pathID];
    [self writeString:html];
}

+ (void)_render:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '", pathID];
    [html xlinkForCommand:@"render" withPathID:pathID into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)class:(NSString *)className {
    XprobeClass *path = [XprobeClass new];
    if ( !(path.aClass = NSClassFromString(className)) )
        return;

    int pathID = [path xadd];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%@').outerHTML = '", className];
    [path xlinkForCommand:@"close" withPathID:pathID into:html];

    [html appendString:@"<br/><table><tr><td class=\\'indent\\'/><td class=\\'drilldown\\'>"];
    [path xopenPathID:pathID into:html];
    
    [html appendString:@"</td></tr></table></span>';"];
    [self writeString:html];
}

@end

/*****************************************************
 ********* ivar_getTypeEncoding() for swift **********
 *****************************************************/

struct _swift_data {
    unsigned long flags;
    const char *className;
    int fieldcount, flags2;
    const char *ivarNames;
    struct _swift_field **(*get_field_data)();
};

struct _swift_class {
    union {
        Class meta;
        unsigned long flags;
    };
    Class supr;
    void *buckets, *vtable, *pdata;
    int f1, f2; // added for Beta5
    int size, tos, mdsize, eight;
    struct _swift_data *swiftData;
    IMP dispatch[1];
};

struct _swift_field {
    union {
        Class meta;
        unsigned long flags;
    };
    union {
        struct _swift_field *typeInfo;
        const char *typeIdent;
        Class objcClass;
    };
    void *unknown;
    struct _swift_field *optional;
};

static struct _swift_class *isSwift( Class aClass ) {
    struct _swift_class *swiftClass = (__bridge struct _swift_class *)aClass;
    return (uintptr_t)swiftClass->pdata & 0x1 ? swiftClass : NULL;
}

static const char *strfmt( NSString *fmt, ... ) NS_FORMAT_FUNCTION(1,2);
static const char *strfmt( NSString *fmt, ... ) {
    va_list argp;
    va_start(argp, fmt);
    return strdup([[[NSString alloc] initWithFormat:fmt arguments:argp] UTF8String]);
}

static const char *typeInfoForClass( Class aClass ) {
    return strfmt( @"@\"%@\"", NSStringFromClass(aClass) );
}

static const char *skipSwift( const char *typeIdent ) {
    while ( isalpha( *typeIdent ) )
        typeIdent++;
    while ( isnumber( *typeIdent ) )
        typeIdent++;
    return typeIdent;
}

static const char *ivar_getTypeEncodingSwift( Ivar ivar, Class aClass ) {
    struct _swift_class *swiftClass = isSwift( aClass );
    if ( !swiftClass )
        return ivar_getTypeEncoding( ivar );

    struct _swift_data *swiftData = swiftClass->swiftData;
    const char *nameptr = swiftData->ivarNames;
    const char *name = ivar_getName(ivar);
    int ivarIndex;

    for ( ivarIndex=0 ; ivarIndex<swiftData->fieldcount ; ivarIndex++ )
        if ( strcmp(name,nameptr) == 0 )
            break;
        else
            nameptr += strlen(nameptr)+1;

    if ( ivarIndex == swiftData->fieldcount )
        return NULL;

    struct _swift_field *field0 = swiftData->get_field_data()[ivarIndex], *field = field0;

    // unpack any optionals
    while ( field->flags == 0x2 ) {
        if ( field->optional )
            field = field->optional;
        else
            return field->typeInfo->typeIdent;
    }

    if ( field->flags == 0x1 ) { // rawtype
        const char *typeIdent = field->typeInfo->typeIdent;
        if ( typeIdent[0] == 'V' ) {
            if ( typeIdent[2] == 'C' )
                return strfmt(@"{%@}", utf8String( skipSwift( typeIdent ) ) );
            else
                return strfmt(@"{%@}", utf8String( skipSwift( skipSwift( typeIdent ) ) ) );
        }
        else
            return field->typeInfo->typeIdent+1;
    }
    else if ( field->flags == 0xa ) // function
        return "^{CLOSURE}";
    else if ( field->flags == 0xc ) // protocol
        return strfmt( @"@\"<%@>\"", utf8String( field->optional->typeIdent ) );
    else if ( field->flags == 0xe ) // objc class
        return typeInfoForClass(field->objcClass);
    else if ( field->flags == 0x10 ) // pointer
        return strfmt( @"^{%@}", utf8String( skipSwift( field->typeIdent ?: "??" ) ) );
    else if ( field->flags < 0x100 || field->flags & 0x3 ) // unknown/bad isa
        return strfmt( @"?FLAGS#%d", (int)field->flags );
    else // swift class
        return typeInfoForClass((__bridge Class)field);
}

@implementation NSObject(Xprobe)

/*****************************************************
 ********* sweep and object display methods **********
 *****************************************************/

+ (void)xsweep {
}

- (void)xsweep {
//    xsweep( self );
//}
//
//static void xsweep( NSObject *self ) {
    BOOL sweptAlready = exists( instancesSeen, self );
    __unsafe_unretained id from = sweepState.from;
    const char *source = sweepState.source;

    if ( !sweptAlready )
        instancesSeen[self] = sweepState;

//    if ( ![self isKindOfClass:[NSObject class]] )
//        return;
//
    BOOL didConnect = [from xgraphConnectionTo:self];

    if ( sweptAlready )
        return;

    XprobeRetained *path = retainObjects ? [XprobeRetained new] : (XprobeRetained *)[XprobeAssigned new];
    path.pathID = instancesSeen[sweepState.from].sequence;
    path.object = self;
    path.name = source;

    assert( [path xadd] == sweepState.sequence );

    sweepState.from = self;
    sweepState.sequence++;
    sweepState.depth++;

    Class aClass = object_getClass(self);
    NSString *className = NSStringFromClass(aClass);
    BOOL legacy = [Xprobe xprobeExclude:className];

    if ( logXprobeSweep )
        printf("Xprobe sweep %d %*s: <%s %p> %s %d\n", sweepState.sequence-1, sweepState.depth, "",
                                                    [className UTF8String], self, path.name, legacy);

    for ( ; aClass && aClass != [NSObject class] ; aClass = class_getSuperclass(aClass) ) {
        if ( className.length == 1 || (className.length > 1 && [className characterAtIndex:1] != '_') )
            instancesByClass[aClass].push_back(self);

        // avoid sweeping legacy classes ivars
        if ( legacy )
            continue;

        unsigned ic;
        Ivar *ivars = class_copyIvarList(aClass, &ic);
        __unused const char *currentClassName = class_getName(aClass);
        
        for ( unsigned i=0 ; i<ic ; i++ ) {
            __unused const char *ivarName = sweepState.source = ivar_getName( ivars[i] );
            const char *type = ivar_getTypeEncodingSwift( ivars[i],aClass );
            if ( strncmp( ivarName, "__", 2 ) != 0 && type && (type[0] == '@' || isOOType( type )) ) {
                id subObject = [self xvalueForIvar:ivars[i] type:type inClass:aClass];
                if ( [subObject respondsToSelector:@selector(xsweep)] ) {
                    const char *className = object_getClassName( subObject ); ////
                    if ( className[0] != '_' )
                        [subObject xsweep];////( subObject );
                }
            }
        }

        free( ivars );
    }

    sweepState.source = "target";
    if ( [self respondsToSelector:@selector(target)] ) {
        if ( [self respondsToSelector:@selector(action)] )
            sweepState.source = sel_getName([self action]);
        [[self target] xsweep];
    }
    sweepState.source = "delegate";
    if ( [self respondsToSelector:@selector(delegate)] &&
        ![className isEqualToString:@"UITransitionView"] )
        [[self delegate] xsweep];
    sweepState.source = "document";
    if ( [self respondsToSelector:@selector(document)] )
        [[self document] xsweep];

    sweepState.source = "contentView";
    if ( [self respondsToSelector:@selector(contentView)] )
        [[[self contentView] superview] xsweep];

    sweepState.source = "subview";
    if ( [self respondsToSelector:@selector(subviews)] )
        [[self subviews] xsweep];

    sweepState.source = "subscene";
    if ( [self respondsToSelector:@selector(getNSArray)] )
        [[self getNSArray] xsweep];

    sweepState.source = source;
    sweepState.from = from;
    sweepState.depth--;

    if ( !didConnect && graphOptions & XGraphInterconnections )
        [from xgraphConnectionTo:self];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    XprobePath *path = paths[pathID];
    Class aClass = [path aClass];

    NSString *closer = [NSString stringWithFormat:@"<span onclick=\\'sendClient(\"open:\",\"%d\"); "
                        "event.cancelBubble = true;\\'>%@</span>",
                        pathID, NSStringFromClass(aClass)];
    [html appendFormat:[self class] == aClass ? @"<b>%@</b>" : @"%@", closer];

    if ( [aClass superclass] ) {
        XprobeSuper *superPath = [path class] == [XprobeClass class] ? [XprobeClass new] :
            [XprobeSuper withPathID:[path class] == [XprobeSuper class] ? path.pathID : pathID];
        superPath.aClass = [aClass superclass];
        superPath.name = superName;

        [html appendString:@" : "];
        [self xlinkForCommand:@"open" withPathID:[superPath xadd] into:html];
    }

    unsigned c;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(aClass, &c);
    if ( c ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<c ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protocolName]];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@" {<br/>"];

    Ivar *ivars = class_copyIvarList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *type = ivar_getTypeEncodingSwift(ivars[i],aClass);
        [html appendFormat:@" &#160; &#160;%@ ", [self xtype:type]];
        [self xspanForPathID:pathID ivar:ivars[i] type:type into:html];
        [html appendString:@";<br/>"];
    }

    free( ivars );

    [html appendString:@"} "];
    if ( snapshot )
        return;

    [self xlinkForCommand:@"properties" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"methods" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"owners" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"siblings" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"trace" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"untrace" withPathID:pathID into:html];
    [html appendString:@" "];
    [self xlinkForCommand:@"traceclass" withPathID:pathID into:html];

    if ( [self respondsToSelector:@selector(subviews)] ) {
        [html appendString:@" "];
        [self xlinkForCommand:@"render" withPathID:pathID into:html];
        [html appendString:@" "];
        [self xlinkForCommand:@"views" withPathID:pathID into:html];
    }

    [html appendFormat:@" <a href=\\'#\\' onclick=\\'sendClient(\"close:\",\"%d\"); return false;\\'>close</a>", pathID];

    Class injectionLoader = NSClassFromString(@"BundleInjection");
    if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] ) {
        BOOL injectionConnected = [injectionLoader connectedAddress] != NULL;

        Class myClass = [self class];
        [html appendFormat:@"<br/><span><button onclick=\"evalForm(this.parentElement,%d,\\'%@\\',%d);"
            "return false;\"%@>Evaluate code against this instance..</button>%@</span>",
            pathID, NSStringFromClass(myClass), isSwift( myClass ) ? 1 : 0,
            injectionConnected ? @"" : @" disabled",
            injectionConnected ? @"" :@" (requires connection to "
            "<a href=\\'https://github.com/johnno1962/injectionforxcode\\'>injectionforxcode plugin</a>)"];
    }
}

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar type:(const char *)type into:(NSMutableString *)html {
    Class aClass = [paths[pathID] aClass];
    const char *name = ivar_getName( ivar );
    NSString *utf8Name = utf8String( name );

    [html appendFormat:@"<span onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { this.id =\"I%d\"; "
        "sendClient( \"ivar:\", \"%d,%@\" ); event.cancelBubble = true; }\\'>%@",
     pathID, pathID, utf8Name, utf8Name];

    if ( [paths[pathID] class] != [XprobeClass class] ) {
        [html appendString:@" = "];
        if ( !type || type[0] == '@' || isOOType( type ) || isCFType(type) )
            [self xprotect:^{
                id subObject = [self xvalueForIvar:ivar inClass:aClass];
                if ( subObject ) {
                    XprobeIvar *ivarPath = [XprobeIvar withPathID:pathID];
                    ivarPath.iClass = aClass;
                    ivarPath.name = name;
                    if ( [subObject respondsToSelector:@selector(xsweep)] )
                        [subObject xlinkForCommand:@"open" withPathID:[ivarPath xadd:subObject] into:html];
                    else
                        [html appendFormat:@"&lt;%@ %p&gt;",
                         NSStringFromClass([subObject class]), subObject];
                }
                else
                    [html appendString:@"nil"];
            }];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"E%d\"; sendClient( \"edit:\", \"%d,%@\" ); "
                "event.cancelBubble = true;\\'>%@</span>", pathID, pathID, utf8Name,
                [[self xvalueForIvar:ivar inClass:aClass] xhtmlEscape]];
    }

    [html appendString:@"</span>"];
}

static NSString *xclassName( NSObject *self ) {
    return NSStringFromClass([self class]);
}

+ (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendFormat:@"[%@ class]", NSStringFromClass(self)];
}


- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    if ( self == trapped || self == notype || self == invocationException ) {
        [html appendString:(NSString *)self];
        return;
    }

    XprobePath *path = paths[pathID];
    Class linkClass = [path aClass];
    NSString *linkClassName = NSStringFromClass(linkClass);
    BOOL basic = [which isEqualToString:@"open"] || [which isEqualToString:@"close"];
    NSString *linkLabel = !basic ? which : [self class] != linkClass ? linkClassName :
        [NSString stringWithFormat:@"&lt;%@&#160;%p&gt;", xclassName( self ), self];
    unichar firstChar = toupper( [which characterAtIndex:0] );

    BOOL notBeenSeen = !exists( instanceIDs[linkClass], self );
    if ( notBeenSeen )
        instanceIDs[linkClass][self] = instanceID++;

    int ID = instanceIDs[linkClass][self];

    BOOL excluded = snapshot && linkClassName && [snapshotExclusions xmatches:linkClassName];
    BOOL willExpand = snapshot && notBeenSeen && !excluded;

    if ( excluded )
        [html appendString:linkLabel];
    else
        [html appendFormat:@"<span id=\\'%@%d\\' onclick=\\'event.cancelBubble = true;\\'>"
            "<a href=\\'#\\' onclick=\\'sendClient( \"%@:\", \"%d\", %d, %d ); "
            "this.className = \"linkClicked\"; event.cancelBubble = true; return false;\\'%@>%@</a>%@",
            basic ? @"" : [NSString stringWithCharacters:&firstChar length:1],
            pathID, which, pathID, ID, !willExpand, path.name ?
            [NSString stringWithFormat:@" title=\\'%@\\'", utf8String( path.name )] : @"",
            linkLabel, [which isEqualToString:@"close"] || willExpand ? @"" : @"</span>"];

    if ( willExpand ) {
        [html appendFormat:@"</span></span><span><span><span id='ID%d' class='snapshotStyle'>", ID];
        [Xprobe xopen:self withPathID:pathID into:html];
        [html appendString:@"</span>"];
    }
}

/*****************************************************
 ********* dot object graph generation code **********
 *****************************************************/

static BOOL xgraphInclude( NSObject *self ) {
    NSString *className = NSStringFromClass([self class]);
    static NSRegularExpression *excluded;
    if ( !excluded )
        excluded = [NSRegularExpression xsimpleRegexp:@"^(?:_|NS|UI|CA|OS_|Web|Wak|FBS)"];
    return ![excluded xmatches:className];
}

static BOOL xgraphExclude( NSObject *self ) {
    NSString *className = NSStringFromClass([self class]);
    return ![className hasPrefix:swiftPrefix] &&
        ([className characterAtIndex:0] == '_' ||
         [className isEqual:@"CALayer"] || [className hasPrefix:@"NSIS"] ||
         [className hasSuffix:@"Constraint"] || [className hasSuffix:@"Variable"] ||
         [className hasSuffix:@"Color"]);
}

static NSString *outlineColorFor( NSObject *self, NSString *className ) {
    return graphOutlineColor;
}

static void xgraphLabelNode( NSObject *self ) {
    if ( !exists( instancesLabeled, self ) ) {
        NSString *className = NSStringFromClass([self class]);
        OSSpinLockLock(&edgeLock);
        instancesLabeled[self].sequence = instancesSeen[self].sequence;
        OSSpinLockUnlock(&edgeLock);
        NSString *color = instancesLabeled[self].color = outlineColorFor( self, className );
        [dotGraph appendFormat:@"    %d [label=\"%@\" tooltip=\"<%@ %p> #%d\"%s%s color=\"%@\"];\n",
             instancesSeen[self].sequence, xclassName( self ), className, self, instancesSeen[self].sequence,
             [self respondsToSelector:@selector(subviews)] ? " shape=box" : "",
             xgraphInclude( self ) ? " style=\"filled\" fillcolor=\"#e0e0e0\"" : "", color];
    }
}

- (BOOL)xgraphConnectionTo:(id)ivar {
    int edgeID = instancesSeen[ivar].owners[self] = graphEdgeID++;
    if ( dotGraph && (__bridge CFNullRef)ivar != kCFNull &&
            (graphOptions & XGraphArrayWithoutLmit || currentMaxArrayIndex < maxArrayItemsForGraphing) &&
            (graphOptions & XGraphAllObjects ||
                (graphOptions & XGraphIncludedOnly ?
                 xgraphInclude( self ) && xgraphInclude( ivar ) :
                 xgraphInclude( self ) || xgraphInclude( ivar )) ||
                (graphOptions & XGraphInterconnections &&
                 exists( instancesLabeled, self ) &&
                 exists( instancesLabeled, ivar ))) &&
            (graphOptions & XGraphWithoutExcepton || (!xgraphExclude( self ) && !xgraphExclude( ivar ))) ) {
        xgraphLabelNode( self );
        xgraphLabelNode( ivar );
        [dotGraph appendFormat:@"    %d -> %d [label=\"%@\" color=\"%@\" eid=\"%d\"];\n",
            instancesSeen[self].sequence, instancesSeen[ivar].sequence, utf8String( sweepState.source ),
            instancesLabeled[self].color, edgeID];
        return YES;
    }
    else
        return NO;
}

/*****************************************************
 ********* generic ivar/method/type access ***********
 *****************************************************/

- (id)xvalueForIvar:(Ivar)ivar inClass:(Class)aClass {
    //NSLog( @"%p %p %p %s %s %s", aClass, ivar, isSwift(aClass), ivar_getName(ivar), ivar_getTypeEncoding(ivar), ivar_getTypeEncodingSwift(ivar, aClass) );
    return [self xvalueForIvar:ivar type:ivar_getTypeEncodingSwift(ivar, aClass) inClass:aClass];
}

- (id)xvalueForIvar:(Ivar)ivar type:(const char *)type inClass:(Class)aClass {
    void *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    return [self xvalueForPointer:iptr type:type];
}

static NSString *invocationException;

- (id)xvalueForMethod:(Method)method {
    @try {
        const char *type = method_getTypeEncoding(method);
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setSelector:method_getName(method)];
        [invocation invokeWithTarget:self];

        NSUInteger size = 0, align;
        const char *returnType = [sig methodReturnType];
        NSGetSizeAndAlignment(returnType, &size, &align);

        char buffer[size];
        if ( returnType[0] != 'v' )
            [invocation getReturnValue:buffer];
        return [self xvalueForPointer:buffer type:returnType];
    }
    @catch ( NSException *e ) {
        NSLog( @"Xprobe: exception on invoke: %@", e );
        return invocationException = [e description];
    }
}

static NSString *trapped = @"#INVALID", *notype = @"#TYPE";

- (id)xvalueForPointer:(void *)iptr type:(const char *)type {
    if ( !type )
        return notype;
    switch ( type[0] ) {
        case 'V':
        case 'v': return @"void";

        case 'b': // for now, for swift
        case 'B': return @(*(bool *)iptr);

        case 'c': return @(*(char *)iptr);
        case 'C': return [NSString stringWithFormat:@"0x%x", *(unsigned char *)iptr];

        case 's': return @(*(short *)iptr);
        case 'S': return isSwift( [self class] ) ? [self xswiftString:iptr] :
            [NSString stringWithFormat:@"0x%x", *(unsigned short *)iptr];

        case 'f': return @(*(float *)iptr);
        case 'd': return @(*(double *)iptr);

        case 'I': return [NSString stringWithFormat:@"0x%x", *(unsigned *)iptr];
        case 'i':
#ifdef __LP64__
            if ( !isSwift( [self class] ) )
#endif
                return @(*(int *)iptr);

#ifndef __LP64__
        case 'q': return @(*(long long *)iptr);
#else
        case 'q':
#endif
        case 'l': return @(*(long *)iptr);
#ifndef __LP64__
        case 'Q': return @(*(unsigned long long *)iptr);
#else
        case 'Q':
#endif
        case 'L': return @(*(unsigned long *)iptr);

        case '@': {
            __block id out = trapped;

            [self xprotect:^{
                uintptr_t uptr = *(uintptr_t *)iptr;
                if ( !uptr )
                    out = nil;
                else if ( uptr & 0xffffffff ) {
                    id obj = *(const id *)iptr;
                    [obj description];
                    out = obj;
                }
            }];

            return out;
        }
        case ':': return [NSString stringWithFormat:@"@selector(%@)",
                          NSStringFromSelector(*(SEL *)iptr)];
        case '#': {
            Class aClass = *(const Class *)iptr;
            return aClass ? [NSString stringWithFormat:@"[%@ class]",
                             NSStringFromClass(aClass)] : @"Nil";
        }
        case '^':
            if ( isCFType( type ) ) {
                char buff[100];
                strcpy(buff, "@\"NS" );
                strcat(buff,type+6);
                strcpy(strchr(buff,'='),"\"");
                return [self xvalueForPointer:iptr type:buff];
            }
            return [NSValue valueWithPointer:*(void **)iptr];

        case '{': @try {
                const char *ooType = isOOType( type );
                if ( ooType )
                    return [self xvalueForPointer:iptr type:ooType+5];
                if ( type[1] == '?' )
                    return [self xvalueForPointer:iptr type:"I"];

                // remove names for valueWithBytes:objCType:
                char cleanType[1000], *tptr = cleanType;
                while ( *type )
                    if ( *type == '"' ) {
                        while ( *++type != '"' )
                            ;
                        type++;
                    }
                    else
                        *tptr++ = *type++;
                *tptr = '\000';

                // for incomplete Swift encodings
                if ( strchr( cleanType, '=' ) )
                    ;
                else if ( strcmp(cleanType,"{CGFloat}") == 0 )
                    return @(*(CGFloat *)iptr);
                else if ( strcmp(cleanType,"{CGPoint}") == 0 )
                    strcpy( cleanType, @encode(CGPoint) );
                else if ( strcmp(cleanType,"{CGSize}") == 0 )
                    strcpy( cleanType, @encode(CGSize) );
                else if ( strcmp(cleanType,"{CGRect}") == 0 )
                    strcpy( cleanType, @encode(CGRect) );
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
                else if ( strcmp(cleanType,"{NSPoint}") == 0 )
                    strcpy( cleanType, @encode(NSPoint) );
                else if ( strcmp(cleanType,"{NSSize}") == 0 )
                    strcpy( cleanType, @encode(NSSize) );
                else if ( strcmp(cleanType,"{NSRect}") == 0 )
                    strcpy( cleanType, @encode(NSRect) );
#else
                else if ( strcmp(cleanType,"{UIOffset}") == 0 )
                    strcpy( cleanType, @encode(UIOffset) );
                else if ( strcmp(cleanType,"{UIEdgeInsets}") == 0 )
                    strcpy( cleanType, @encode(UIEdgeInsets) );
#endif
                else if ( strcmp(cleanType,"{CGAffineTransform}") == 0 )
                    strcpy( cleanType, @encode(CGAffineTransform) );

                return [NSValue valueWithBytes:iptr objCType:cleanType];
            }
            @catch ( NSException *e ) {
                return @"raised exception";
            }
        case '*': {
            const char *ptr = *(const char **)iptr;
            return ptr ? utf8String( ptr ) : @"NULL";
        }
#if 0
        case 'b':
            return [NSString stringWithFormat:@"0x%08x", *(int *)iptr];
#endif
        default:
            return @"unknown";
    }
}

- (NSString *)xswiftString:(void *)iptr {
    static Class xprobeSwift;
    if ( !xprobeSwift ) {
        NSBundle *thisBundle = [NSBundle bundleForClass:[Xprobe class]];
        NSString *bundlePath = [[thisBundle bundlePath] stringByAppendingPathComponent:@"XprobeSwift.loader"];
        if ( ![[NSBundle bundleWithPath:bundlePath] load] )
            NSLog( @"Xprobe: Could not load XprobeSwift bundle: %@", bundlePath );
        xprobeSwift = objc_getClass("XprobeSwift");
    }
    return xprobeSwift ? [NSString stringWithFormat:@"\"%@\"", [xprobeSwift convert:iptr]] : @"unavailable";
}

static jmp_buf jmp_env;

static void handler( int sig ) {
	longjmp( jmp_env, sig );
}

- (int)xprotect:(void (^)())blockToProtect {
    void (*savetrap)(int) = signal( SIGTRAP, handler );
    void (*savesegv)(int) = signal( SIGSEGV, handler );
    void (*savebus )(int) = signal( SIGBUS,  handler );

    int signum;
    switch ( signum = setjmp( jmp_env ) ) {
        case 0:
            blockToProtect();
            break;
        default:
            [Xprobe writeString:[NSString stringWithFormat:@"SIGNAL: %d", signum]];
    }

    signal( SIGBUS,  savebus  );
    signal( SIGSEGV, savesegv );
    signal( SIGTRAP, savetrap );
    return signum;
}

- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value {
    const char *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    const char *type = ivar_getTypeEncodingSwift(ivar,[self class]);
    switch ( type[0] ) {
        case 'b': // Swift
        case 'B': *(bool *)iptr = [value intValue]; break;
        case 'c': *(char *)iptr = [value intValue]; break;
        case 'C': *(unsigned char *)iptr = [value intValue]; break;
        case 's': *(short *)iptr = [value intValue]; break;
        case 'S': *(unsigned short *)iptr = [value intValue]; break;
        case 'i': *(int *)iptr = [value intValue]; break;
        case 'I': *(unsigned *)iptr = [value intValue]; break;
        case 'f': *(float *)iptr = [value floatValue]; break;
        case 'd': *(double *)iptr = [value doubleValue]; break;
#ifndef __LP64__
        case 'q': *(long long *)iptr = [value longLongValue]; break;
#else
        case 'q':
#endif
        case 'l': *(long *)iptr = (long)[value longLongValue]; break;
#ifndef __LP64__
        case 'Q': *(unsigned long long *)iptr = [value longLongValue]; break;
#else
        case 'Q':
#endif
        case 'L': *(unsigned long *)iptr = (unsigned long)[value longLongValue]; break;
        case ':': *(SEL *)iptr = NSSelectorFromString(value); break;
        default:
            NSLog( @"Xprobe: update of unknown type: %s", type );
            return FALSE;
    }

    return TRUE;
}

- (NSString *)xtype:(const char *)type {
    NSString *typeStr = [self xtype_:type];
    return [NSString stringWithFormat:@"<span class=\\'%@\\' title=\\'%s\\'>%@</span>",
            [typeStr hasSuffix:@"*"] ? @"classStyle" : @"typeStyle", type, typeStr];
}

- (NSString *)xtype_:(const char *)type {
    if ( !type )
        return @"notype";
    switch ( type[0] ) {
        case 'V': return @"oneway void";
        case 'v': return @"void";
        case 'b': return @"Bool";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return type[-1] != 'S' ? @"unsigned short" : @"String";
        case 'i': return @"int";
        case 'I': return @"unsigned";
        case 'f': return @"float";
        case 'd': return @"double";
#ifndef __LP64__
        case 'q': return @"long long";
#else
        case 'q':
#endif
        case 'l': return @"long";
#ifndef __LP64__
        case 'Q': return @"unsigned long long";
#else
        case 'Q':
#endif
        case 'L': return @"unsigned long";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': return [self xtype:type+1 star:" *"];
        case '^': return [self xtype:type+1 star:" *"];
        case '{': return [self xtype:type star:""];
        case '[': {
            int dim = atoi( type+1 );
            while ( isnumber( *++type ) )
                ;
            return [NSString stringWithFormat:@"%@[%d]", [self xtype:type], dim];
        }
        case 'r':
            return [@"const " stringByAppendingString:[self xtype:type+1]];
        case '*': return @"char *";
        default:
            return utf8String( type ); //@"id";
    }
}

- (NSString *)xtype:(const char *)type star:(const char *)star {
    if ( type[-1] == '@' ) {
        if ( type[0] != '"' )
            return @"id";
        else if ( type[1] == '<' )
            type++;
    }
    if ( type[-1] == '^' && type[0] != '{' )
        return [[self xtype:type] stringByAppendingString:@" *"];

    const char *end = ++type;
    if ( *end == '?' )
        end = end+strlen(end);
    else
        while ( isalnum(*end) || *end == '_' || *end == ',' || *end == '.' || *end < 0 )
            end++;
    NSData *data = [NSData dataWithBytesNoCopy:(void *)type length:end-type freeWhenDone:NO];
    NSString *typeName = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ( type[-1] == '<' )
        return [NSString stringWithFormat:@"id&lt;%@&gt;",
                    [self xlinkForProtocol:typeName]];
    else {
        return [NSString stringWithFormat:@"<span onclick=\\'this.id=\"%@\"; "
                    "sendClient( \"class:\", \"%@\" ); event.cancelBubble=true;\\'>%@</span>%s",
                    typeName, typeName, typeName, star];
    }
}

- (NSString *)xlinkForProtocol:(NSString *)protocolName {
  return snapshot ? protocolName :
    [NSString stringWithFormat:@"<a href=\\'#\\' onclick=\\'this.id=\"%@\"; "
     "sendClient( \"protocol:\", \"%@\" ); event.cancelBubble = true; return false;\\'>%@</a>",
     protocolName, protocolName, protocolName];
}

- (NSString *)xhtmlEscape {
    return [[[[[[[[self description]
                  stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
                 stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"]
               stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
              stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
             stringByReplacingOccurrencesOfString:@"  " withString:@" &#160;"]
            stringByReplacingOccurrencesOfString:@"\t" withString:@" &#160; &#160;"];
}

- (id)xvalueForKey:(NSString *)key {
    if ( [key hasPrefix:@"0x"] ) {
        NSScanner* scanner = [NSScanner scannerWithString:key];
        unsigned long long objectPointer;
        [scanner scanHexLongLong:&objectPointer];
        return (__bridge id)(void *)objectPointer;
    }
    else
        return [self valueForKey:key];
}

- (id)xvalueForKeyPath:(NSString *)key {
    NSUInteger dotLocation = [key rangeOfString:@"."].location;
    if ( dotLocation == NSNotFound )
        return [self xvalueForKey:key];
    else
        return [[self xvalueForKey:[key substringToIndex:dotLocation]]
                xvalueForKeyPath:[key substringFromIndex:dotLocation+1]];
}

@end

/*****************************************************
 ************ sweep of foundation classes ************
 *****************************************************/

@implementation NSArray(Xprobe)

- (void)xsweep {
    sweepState.depth++;
    unsigned saveMaxArrayIndex = currentMaxArrayIndex;

    for ( unsigned i=0 ; i<[self count] ; i++ ) {
        if ( currentMaxArrayIndex < i )
            currentMaxArrayIndex = i;
        if ( [self[i] respondsToSelector:@selector(xsweep)] )
            [self[i] xsweep];//// xsweep( self[i] );
    }

    currentMaxArrayIndex = saveMaxArrayIndex;
    sweepState.depth--;
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"@["];

    for ( int i=0 ; i < self.count ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeArray *path = [XprobeArray withPathID:pathID];
        path.sub = i;
        id obj = self[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }

    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [self objectAtIndex:[key intValue]];
}

@end

@implementation NSSet(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    NSArray *all = [self allObjects];

    [html appendString:@"@["];
    for ( int i=0 ; i < all.count ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeSet *path = [XprobeSet withPathID:pathID];
        path.sub = i;
        id obj = all[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }
    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [[self allObjects] objectAtIndex:[key intValue]];
}

@end

@implementation NSDictionary(Xprobe)

- (void)xsweep {
    [[self allValues] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"@{<br/>"];

    for ( id key in [[self allKeys] sortedArrayUsingSelector:@selector(compare:)] ) {
        [html appendFormat:@" &#160; &#160;%@ => ", [key xhtmlEscape]];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = self[key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br/>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSMapTable(Xprobe)

- (void)xsweep {
    [[[self objectEnumerator] allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:@"@{<br/>"];

    for ( id key in [[[self keyEnumerator] allObjects] sortedArrayUsingSelector:@selector(compare:)] ) {
        [html appendFormat:@" &#160; &#160;%@ => ", [key xhtmlEscape]];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = [self objectForKey:key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br/>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSHashTable(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    NSArray *all = [self allObjects];

    [html appendString:@"@["];
    for ( int i=0 ; i<[all count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeSet *path = [XprobeSet withPathID:pathID];
        path.sub = i;
        id obj = all[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }
    [html appendString:@"]"];
}

- (id)xvalueForKey:(NSString *)key {
    return [[self allObjects] objectAtIndex:[key intValue]];
}

@end

@implementation NSString(Xprobe)

- (void)xsweep {
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    if ( self.length < 50 )
        [self xopenPathID:pathID into:html];
    else
        [super xlinkForCommand:which withPathID:pathID into:html];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendFormat:@"@\"%@\"", [self xhtmlEscape]];
}

@end

@implementation NSValue(Xprobe)

- (void)xsweep {
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:[self xhtmlEscape]];
}

@end

@implementation NSData(Xprobe)

- (void)xsweep {
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    [html appendString:[self xhtmlEscape]];
}

@end

@interface NSBlock : NSObject
@end

@implementation NSBlock(Xprobe)

// Block internals. (thanks to https://github.com/steipete/Aspects)
typedef NS_OPTIONS(int, AspectBlockFlags) {
    AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
    AspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _AspectBlock {
    __unused Class isa;
    AspectBlockFlags flags;
    __unused int reserved;
    void (__unused *invoke)(struct _AspectBlock *block, ...);
    struct {
        unsigned long int reserved;
        unsigned long int size;
        // requires AspectBlockFlagsHasCopyDisposeHelpers
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
        // requires AspectBlockFlagsHasSignature
        const char *signature;
        const char *layout;
    } *descriptor;
    // imported variables
} *AspectBlockRef;

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html {
    AspectBlockRef blockInfo = (__bridge AspectBlockRef)self;
    BOOL hasInfo = blockInfo->flags & AspectBlockFlagsHasSignature ? YES : NO;
    [html appendFormat:@"<br/>%p ^( %s ) {<br/>&nbsp &#160; %s<br/>}", blockInfo->invoke,
     hasInfo && blockInfo->descriptor->signature ?
     blockInfo->descriptor->signature : "blank",
     /*hasInfo && blockInfo->descriptor->layout ?
     blockInfo->descriptor->layout :*/ "// layout blank"];
}

@end

@implementation NSProxy(Xprobe)

- (void)xsweep {
}

@end

#endif
