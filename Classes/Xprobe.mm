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
#import "Xtrace.h"

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

// options
static BOOL logXprobeSweep = NO, retainObjects = YES;

static unsigned maxArrayItemsForGraphing = 20, currentMaxArrayIndex;

// sweep state
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

// "dot" object graph rendering

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
    XGraphWithoutExcepton        = 1 << 3
};

static NSString *graphOutlineColor = @"#000000", *graphHighlightColor = @"#ff0000";

static XGraphOptions graphOptions;
static NSMutableString *dotGraph;

static unsigned graphEdgeID;
static BOOL graphAnimating;

// support for Objective-C++ reference classes
static const char *isOOType( const char *type ) {
    return strncmp( type, "{OO", 3 ) == 0 ? strstr( type, "\"ref\"" ) : NULL;
}

@interface NSObject(Xprobe)

// forward references
- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html;

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar into:(NSMutableString *)html;
- (void)xopenPathID:(int)pathID into:(NSMutableString *)html;

- (NSString *)xlinkForProtocol:(NSString *)protocolName;
- (NSString *)xhtmlEscape;
- (void)xsweep;

// ivar handling
- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value;
- (id)xvalueForIvar:(Ivar)ivar inClass:(Class)aClass;
- (NSString *)xtype:(const char *)type;
- (id)xvalueForKeyPath:(NSString *)key;
- (id)xvalueForMethod:(Method)method;
- (id)xvalueForKey:(NSString *)key;

@end

@interface NSObject(XprobeReferences)

// external references
- (NSString *)base64EncodedStringWithOptions:(NSUInteger)options;
+ (const char *)connectedAddress;
- (NSArray *)getNSArray;
- (NSArray *)subviews;
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
    int newPathID = (int)[paths count];
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
        [path appendFormat:@"%s", seedName];
        return path;
    }

    NSMutableString *path = [paths[self.pathID] xpath];
    if ( self.name != superName )
        [path appendFormat:@".%s", self.name];
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
    return @"$Id: //depot/XprobePlugin/Classes/Xprobe.mm#119 $";
}

+ (BOOL)xprobeExclude:(NSString *)className {
    static NSRegularExpression *excluded;
    if ( !excluded )
        excluded = [NSRegularExpression xsimpleRegexp:@"^(_|NS|XC|IDE|DVT|Xcode3|IB|VK|WebHistory)"];
    return [excluded xmatches:className] && ![className hasPrefix:swiftPrefix];
}

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain {

    if ( !ipAddress ) {
        Class injectionLoader = NSClassFromString(@"BundleInjection");
        if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] )
            ipAddress = [injectionLoader connectedAddress];
    }

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
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];

#if 0 // Adding methods to Swift classes does not work alas..
    Class SwiftRoot = objc_getClass("SwiftObject");
    if ( SwiftRoot ) {
        unsigned mc;
        Method *methods1 = class_copyMethodList(SwiftRoot, &mc);
        NSLog( @"%u", mc );
        for ( unsigned i=0 ; i<mc ; i++ ) {
            SEL methodName = method_getName(methods1[i]);
            NSLog( @"%s", sel_getName(methodName));
        }
        Method *methods = class_copyMethodList(objc_getClass("NSObject"), &mc);
        for ( unsigned i=0 ; i<mc ; i++ ) {
            SEL methodName = method_getName(methods[i]);
            if ( sel_getName(methodName)[0] == 'x' || strncmp(sel_getName(methodName),"method",6)==0) {
                if ( !class_replaceMethod(SwiftRoot, methodName, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i])) || 1 )
                    NSLog( @">>> %s %p %s", sel_getName(methodName), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]) );
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
        [self performSelector:NSSelectorFromString(command) withObject:argument];
#pragma clang diagnostic pop
    }

    NSLog( @"Xprobe: Service loop exits" );
    close( clientSocket );
}

+ (NSString *)readString {
    uint32_t length;

    if ( read(clientSocket, &length, sizeof length) != sizeof length ) {
        NSLog( @"Xprobe: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read(clientSocket, buff+sofar, length-sofar )) > 0 )
        sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"Xprobe: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        return nil;
    }

    if ( buff )
        buff[sofar] = '\000';

    NSString *str = [NSString stringWithUTF8String:buff];
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
    else if ( write(clientSocket, &length, sizeof length ) != sizeof length ||
             write(clientSocket, data, length ) != length )
        NSLog( @"Xprobe: Socket write error %s", strerror(errno) );

    [writeLock unlock];
}

+ (void)xlog:(NSString *)message {
    [self writeString:[NSString stringWithFormat:@"$('OUTPUT%d').innerHTML += '%@<br>';",
                                                    lastPathID, [message xhtmlEscape]]];
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
                if ( instancesSeen.find(obj) == instancesSeen.end() ) {
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

    instancesSeen.clear();
    instancesByClass.clear();
    instancesLabeled.clear();

    sweepState.sequence = sweepState.depth = 0;
    sweepState.source = seedName;
    graphEdgeID = 1;

    if ( pattern != lastPattern ) {
        lastPattern = pattern;
        graphOptions = 0;
    }

    paths = [NSMutableArray new];
    [[self xprobeSeeds] xsweep];

    [dotGraph appendString:@"}\n"];
    [self writeString:dotGraph];

    NSLog( @"Xprobe: sweep complete, %d objects found", (int)[paths count] );
    dotGraph = nil;

    NSMutableString *html = [NSMutableString new];
    [html appendString:@"$().innerHTML = '<b>Application Memory Sweep</b> (<input type=checkbox onclick=\"kitswitch(this);\"> - Filter out \"kit\" instances)<p>"];

    // various types of earches
    unichar firstChar = [pattern length] ? [pattern characterAtIndex:0] : 0;
    if ( (firstChar == '+' || firstChar == '-') && [pattern length] > 3 )
        [self findMethodsMatching:[pattern substringFromIndex:1] type:firstChar into:html];
    else {

        // original search by instance's class name
        NSRegularExpression *classRegexp = [NSRegularExpression xsimpleRegexp:pattern];
        std::map<__unsafe_unretained id,int> matchedObjects;

        for ( const auto &byClass : instancesByClass )
            if ( !classRegexp || [classRegexp xmatches:NSStringFromClass(byClass.first)] )
                for ( const auto &instance : byClass.second )
                    matchedObjects[instance]++;

        if ( !matchedObjects.empty() ) {
            for ( int pathID=0 ; pathID<[paths count] ; pathID++ ) {
                id obj = [paths[pathID] object];

                if( matchedObjects[obj] ) {
                    const char *className = class_getName([obj class]);
                    BOOL isUIKit = className[0] == '_' || strncmp(className, "NS", 2) == 0 ||
                        strncmp(className, "UI", 2) == 0 || strncmp(className, "CA", 2) == 0;

                    [html appendFormat:@"<div%@>", isUIKit ? @" class=kitclass" : @""];

                    struct _xsweep &info = instancesSeen[obj];
                    for ( unsigned i=1 ; i<info.depth ; i++ )
                        [html appendString:@"&nbsp; &nbsp; "];

                    [obj xlinkForCommand:@"open" withPathID:info.sequence into:html];
                    [html appendString:@"</div>"];
                }
            }
        }
        else
            if ( ![self findClassesMatching:classRegexp into:html] )
                [html appendString:@"No root objects or classes found, check class name pattern.<br>"];
    }

    [html appendString:@"';"];
    [self writeString:html];

    if ( graphAnimating )
        [self animate:@"1"];
}

+ (NSUInteger)findClassesMatching:(NSRegularExpression *)classRegexp into:(NSMutableString *)html {

    unsigned ccount;
    Class *classes = objc_copyClassList( &ccount );
    NSMutableArray *classesFound = [NSMutableArray new];

    for ( unsigned i=0 ; i<ccount ; i++ ) {
        NSString *className = [NSString stringWithUTF8String:class_getName(classes[i])];
        if ( [classRegexp xmatches:className] && [className characterAtIndex:1] != '_' )
            [classesFound addObject:className];
    }

    free( classes );

    [classesFound sortUsingSelector:@selector(caseInsensitiveCompare:)];

    for ( NSString *className in classesFound ) {
        XprobeClass *path = [XprobeClass new];
        path.aClass = NSClassFromString(className);
        [path xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@"<br>"];
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
                    methodsFound = [NSMutableString stringWithString:@"<br>"];
                [methodsFound appendFormat:@"&nbsp; &nbsp; %@%@<br>", [NSString stringWithCharacters:&firstChar length:1], methodName];
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

static int lastPathID;

+ (void)open:(NSString *)input {
    lastPathID = [input intValue];
    XprobePath *path = paths[lastPathID];
    id obj = [path object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", lastPathID];
    [obj xlinkForCommand:@"close" withPathID:lastPathID into:html];

    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [obj xopenPathID:lastPathID into:html];

    [html appendString:@"</table></span>';"];
    [self writeString:html];

    if ( ![path isKindOfClass:[XprobeSuper class]] )
        [self writeString:[path xpath]];
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
        [html appendFormat:@"%s%s", i ? "," : "", name];
    }

    [html appendString:@"'.split(',');"];
    [self writeString:html];
}

+ (void)injectedClass:(Class)aClass {
    id lastObject = [paths[lastPathID] object];
    if ( [lastObject isKindOfClass:aClass] && [lastObject respondsToSelector:@selector(injected)] )
        [lastObject injected];
    [self writeString:[NSString stringWithFormat:@"$('BUSY%d').hidden = true;", lastPathID]];
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
    [html appendFormat:@"$('P%d').outerHTML = '<span class=propsStyle><br><br>", pathID];

    unsigned pc;
    objc_property_t *props = class_copyPropertyList(aClass, &pc);
    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);

        [html appendFormat:@"@property () %@ <span onclick=\\'this.id =\"P%d\"; "
             "sendClient( \"property:\", \"%d,%s\" ); event.cancelBubble = true;\\'>%s</span>; // %s<br>",
             [self xtype:attrs+1], pathID, pathID, name, name, attrs];
    }

    free( props );

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)methods:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('M%d').outerHTML = '<br><span class=methodStyle>"
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
    [NSString stringWithFormat:@" style=\\'display:none;\\' title=\\'%s\\'", class_getName(aClass)];

    if ( mc && ![hide length] )
        [html appendString:@"<br>"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse signature for %s, '%s': %@", name, type, e );
        }

        NSArray *bits = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];
        [html appendFormat:@"<div sel=\\'%s\\'%@>%s (%@)", name, hide, mtype, [self xtype:[sig methodReturnType]]];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", bits[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"M%d\"; sendClient( \"method:\", \"%d,%s\" );"
                "event.cancelBubble = true;\\'>%s</span> ", pathID, pathID, name, name];

        [html appendFormat:@";</div>"];
    }

    free( methods );
}

+ (void)protocol:(NSString *)protoName {
    Protocol *protocol = NSProtocolFromString(protoName);
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%@').outerHTML = '<span id=\\'%@\\'><a href=\\'#\\' onclick=\\'sendClient( \"_protocol:\", \"%@\"); "
         "event.cancelBubble = true; return false;\\'>%@</a><p><table><tr><td><td class=indent><td>"
         "<span class=protoStyle>@protocol %@", protoName, protoName, protoName, protoName, protoName];

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

    [html appendString:@"<br>"];

    objc_property_t *props = protocol_copyPropertyList(protocol, &pc);

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ %s; // %s<br>", [self xtype:attrs+1], name, attrs];
    }

    free( props );

    [self dumpMethodsForProtocol:protocol required:YES instance:NO into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:NO into:html];

    [self dumpMethodsForProtocol:protocol required:YES instance:YES into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:YES into:html];

    [html appendString:@"<br>@end<p></span></table></span>';"];
    [self writeString:html];
}

// Thanks to http://bou.io/ExtendedTypeInfoInObjC.html !
extern "C" const char *_protocol_getMethodTypeEncoding(Protocol *,SEL,BOOL,BOOL);

+ (void)dumpMethodsForProtocol:(Protocol *)protocol required:(BOOL)required instance:(BOOL)instance into:(NSMutableString *)html {

    unsigned mc;
    objc_method_description *methods = protocol_copyMethodDescriptionList( protocol, required, instance, &mc );
    if ( !mc )
        return;

    [html appendFormat:@"<br>@%@<br>", required ? @"required" : @"optional"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(methods[i].name);
        const char *type;// = methods[i].types;

        type = _protocol_getMethodTypeEncoding(protocol, methods[i].name, required,instance);
        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:type];
        }
        @catch ( NSException *e ) {
            NSLog( @"Xprobe: Unable to parse protocol signature for %s, '%s': %@", name, type, e );
        }

        NSArray *parts = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];
        [html appendFormat:@"%s (%@)", instance ? "-" : "+", [self xtype:[sig methodReturnType]]];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", a-2 < [parts count] ? parts[a-2] : @"?",
                    [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"%s", name];

        [html appendFormat:@" ;<br>"];
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

    [html appendFormat:@"$('V%d').outerHTML = '<br>", pathID];
    [self subviewswithPathID:pathID indent:0 into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)subviewswithPathID:(int)pathID indent:(int)indent into:(NSMutableString *)html {
    id obj = [paths[pathID] object];
    for ( int i=0 ; i<indent ; i++ )
        [html appendString:@"&nbsp; &nbsp; "];

    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"<br>"];

    NSArray *subviews = [obj subviews];
    for ( int i=0 ; i<[subviews count] ; i++ ) {
        XprobeView *path = [XprobeView withPathID:pathID];
        path.sub = i;
        [self subviewswithPathID:[path xadd] indent:indent+1 into:html];
    }
}

static std::map<unsigned,NSTimeInterval> edgesCalled;
static __unsafe_unretained id callStack[1000];
static OSSpinLock edgeLock;

+ (void)trace:(NSString *)input {
    int pathID = [input intValue];
    XprobePath *path = paths[pathID];
    id obj = [path object];
    Class aClass = [path aClass];

    [Xtrace setDelegate:self];
    if ( [path class] == [XprobeClass class] )
        [Xtrace traceClass:obj = aClass];
    else {
        [Xtrace traceInstance:obj class:aClass];
        instancesTraced[obj] = YES;
    }

    [self writeString:[NSString stringWithFormat:@"Tracing <%s %p>", class_getName(aClass), obj]];
}

+ (void)traceclass:(NSString *)input {
    XprobeClass *path = [XprobeClass new];
    path.aClass = [paths[[input intValue]] aClass];
    [self trace:[NSString stringWithFormat:@"%d", [path xadd]]];
}

+ (void)xtrace:(NSString *)trace forInstance:(void *)optr indent:(int)indent {
    if ( !graphAnimating )
        [self writeString:trace];
    else if ( !dotGraph ) {
        __unsafe_unretained id obj = (__bridge __unsafe_unretained id)optr;
        struct _animate &info = instancesLabeled[obj];
        info.lastMessageTime = [NSDate timeIntervalSinceReferenceDate];
        info.callCount++;

        if ( indent >= 0 && indent < sizeof callStack / sizeof callStack[0] ) {
            callStack[indent] = obj;
            __unsafe_unretained id caller = callStack[indent-1];
            std::map<__unsafe_unretained id,unsigned> &owners = instancesSeen[obj].owners;
            if ( indent > 0 && obj != caller && owners.find(caller) != owners.end() ) {
                OSSpinLockLock(&edgeLock);
                edgesCalled[owners[caller]] = info.lastMessageTime;
                OSSpinLockUnlock(&edgeLock);
            }
        }
    }
}

+ (void)animate:(NSString *)input {
    BOOL wasAnimating = graphAnimating;
    if ( (graphAnimating = [input intValue]) ) {
        [Xtrace setDelegate:self];
        for ( const auto &graphing : instancesLabeled )
            [Xtrace traceInstance:graphing.first];

        edgeLock = OS_SPINLOCK_INIT;
        if ( !wasAnimating )
            [self performSelectorInBackground:@selector(sendUpdates) withObject:nil];

        NSLog( @"Xprobe: traced %d objects", (int)instancesLabeled.size() );
    }
    else
        for ( const auto &graphing : instancesLabeled )
            if ( instancesTraced.find(graphing.first) != instancesTraced.end() )
                [Xtrace notrace:graphing.first];
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

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('I%d').outerHTML = '", info.pathID];
    [info.obj xspanForPathID:info.pathID ivar:ivar into:html];

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
         info.pathID, info.pathID, [info.obj xvalueForIvar:ivar inClass:info.aClass], info.pathID, info.name];

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
    [html appendFormat:@"$('O%d').outerHTML = '<p>", pathID];

    for ( auto owner : instancesSeen[obj].owners ) {
        int pathID = instancesSeen[owner.first].sequence;
        [owner.first xlinkForCommand:@"open" withPathID:pathID into:html];
        [html appendString:@"&nbsp; "];
    }

    [html appendString:@"<p>';"];
    [self writeString:html];
}

+ (void)siblings:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('S%d').outerHTML = '<p>", pathID];

    for ( const auto &obj : instancesByClass[aClass] ) {
        XprobeRetained *path = [XprobeRetained new];
        path.object = obj;
        [obj xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@" "];
    }

    [html appendString:@"<p>';"];
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
    [html appendFormat:@"$('R%d').outerHTML = '<span id=\\'R%d\\'><p>"
         "<img src=\\'data:image/png;base64,%@\\' onclick=\\'sendClient(\"_render:\", \"%d\"); "
         "event.cancelBubble = true;\\'><p></span>';", pathID, pathID,
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

    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [path xopenPathID:pathID into:html];
    
    [html appendString:@"</table></span>';"];
    [self writeString:html];
}

@end

@implementation NSObject(Xprobe)

/*****************************************************
 ********* sweep and object display methods **********
 *****************************************************/

+ (void)xsweep {
}

- (void)xsweep {
    BOOL sweptAlready = instancesSeen.find(self) != instancesSeen.end();
    __unsafe_unretained id from = sweepState.from;
    const char *source = sweepState.source;

    if ( !sweptAlready )
        instancesSeen[self] = sweepState;

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
        printf("Xprobe sweep %d: <%s %p> %d\n", sweepState.depth, [className UTF8String], self, legacy);

    for ( ; aClass && aClass != [NSObject class] ; aClass = class_getSuperclass(aClass) ) {
        if ( [className characterAtIndex:1] != '_' )
            instancesByClass[aClass].push_back(self);

        // avoid sweeping legacy classes ivars
        if ( legacy )
            continue;

        unsigned ic;
        Ivar *ivars = class_copyIvarList(aClass, &ic);
        __unused const char *currentClassName = class_getName(aClass);

        for ( unsigned i=0 ; i<ic ; i++ ) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if ( type && type[0] == '@' ) {
                __unused const char *currentIvarName = sweepState.source = ivar_getName(ivars[i]);
                id subObject = [self xvalueForIvar:ivars[i] inClass:aClass];
                if ( [subObject respondsToSelector:@selector(xsweep)] )
                    [subObject xsweep];
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
    if ( [self respondsToSelector:@selector(delegate)] )
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

static struct _swift_class *isSwift( Class aClass );

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    XprobePath *path = paths[pathID];
    Class aClass = [path aClass];

    NSString *closer = [NSString stringWithFormat:@"<span onclick=\\'sendClient(\"open:\",\"%d\"); "
                        "event.cancelBubble = true;\\'>%s</span>", pathID, class_getName(aClass)];
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

    [html appendString:@" {<br>"];

    Ivar *ivars = class_copyIvarList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *type = ivar_getTypeEncodingSwift(ivars[i],aClass);
        [html appendFormat:@" &nbsp; &nbsp;%@ ", [self xtype:type]];
        [self xspanForPathID:pathID ivar:ivars[i] into:html];
        [html appendString:@";<br>"];
    }

    free( ivars );

    [html appendFormat:@"} "];
    [self xlinkForCommand:@"properties" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"methods" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"owners" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"siblings" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"trace" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"traceclass" withPathID:pathID into:html];

    if ( [self respondsToSelector:@selector(subviews)] ) {
        [html appendFormat:@" "];
        [self xlinkForCommand:@"render" withPathID:pathID into:html];
        [html appendFormat:@" "];
        [self xlinkForCommand:@"views" withPathID:pathID into:html];
    }

    [html appendFormat:@" "];
    [html appendFormat:@" <a href=\\'#\\' onclick=\\'sendClient(\"close:\",\"%d\"); return false;\\'>close</a>", pathID];

    Class injectionLoader = NSClassFromString(@"BundleInjection");
    if ( [injectionLoader respondsToSelector:@selector(connectedAddress)] ) {
        BOOL injectionConnected = [injectionLoader connectedAddress] != NULL;

        Class myClass = [self class];
        [html appendFormat:@"<br><span><button onclick=\"evalForm(this.parentElement,%d,\\'%s\\',%d);"
            "return false;\"%@>Evaluate code against this instance..</button>%@</span>",
            pathID, class_getName(myClass), isSwift( myClass ) ? 1 : 0,
            injectionConnected ? @"" : @" disabled",
            injectionConnected ? @"" :@" (requires connection to "
            "<a href=\\'https://github.com/johnno1962/injectionforxcode\\'>injectionforxcode plugin</a>)"];
    }
}

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar into:(NSMutableString *)html {
    Class aClass = [paths[pathID] aClass];
    const char *type = ivar_getTypeEncodingSwift(ivar,aClass);
    const char *name = ivar_getName(ivar);

    [html appendFormat:@"<span onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { this.id =\"I%d\"; "
        "sendClient( \"ivar:\", \"%d,%s\" ); event.cancelBubble = true; }\\'>%s", pathID, pathID, name, name];

    if ( [paths[pathID] class] != [XprobeClass class] ) {
        [html appendString:@" = "];
        if ( !type || type[0] == '@' || isOOType( type ) )
            [self xprotect:^{
                id subObject = [self xvalueForIvar:ivar inClass:aClass];
                if ( subObject ) {
                    XprobeIvar *ivarPath = [XprobeIvar withPathID:pathID];
                    ivarPath.iClass = aClass;
                    ivarPath.name = name;
                    if ( [subObject respondsToSelector:@selector(xsweep)] )
                        [subObject xlinkForCommand:@"open" withPathID:[ivarPath xadd:subObject] into:html];
                    else
                        [html appendFormat:@"&lt;%s %p&gt;", class_getName([subObject class]), subObject];
                }
                else
                    [html appendString:@"nil"];
            }];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"E%d\"; sendClient( \"edit:\", \"%d,%s\" ); "
                "event.cancelBubble = true;\\'>%@</span>", pathID, pathID, name,
                [[self xvalueForIvar:ivar inClass:aClass] xhtmlEscape]];
    }

    [html appendString:@"</span>"];
}

+ (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    [html appendFormat:@"[%s class]", class_getName(self)];
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html {
    if ( self == trapped || self == notype || self == invocationException ) {
        [html appendString:(NSString *)self];
        return;
    }

    XprobePath *path = paths[pathID];
    Class linkClass = [path aClass];
    BOOL basic = [which isEqualToString:@"open"] || [which isEqualToString:@"close"];
    NSString *label = !basic ? which : [self class] != linkClass ? NSStringFromClass(linkClass) :
        [NSString stringWithFormat:@"&lt;%@&nbsp;%p&gt;", [self xclassName], self];

    unichar firstChar = toupper([which characterAtIndex:0]);
    [html appendFormat:@"<span id=\\'%@%d\\' onclick=\\'event.cancelBubble = true;\\'>"
        "<a href=\\'#\\' onclick=\\'sendClient( \"%@:\", \"%d\" ); "
        "event.cancelBubble = true; return false;\\'%@>%@</a>%@",
        basic ? @"" : [NSString stringWithCharacters:&firstChar length:1],
        pathID, which, pathID, [NSString stringWithFormat:@" title=\\'%s\\'", path.name],
        label, [which isEqualToString:@"close"] ? @"" : @"</span>"];
}

- (NSString *)xclassName {
    NSString *className = NSStringFromClass([self class]);
    if ( [className hasPrefix:swiftPrefix] ) {
        NSScanner *scanner = [NSScanner scannerWithString:className];
        int len;

        [scanner setScanLocation:[swiftPrefix length]];
        [scanner scanInt:&len];
        NSRange arange = NSMakeRange([scanner scanLocation], len);
        NSString *aname = [className substringWithRange:arange];

        [scanner setScanLocation:NSMaxRange(arange)];
        [scanner scanInt:&len];
        NSRange crange = NSMakeRange([scanner scanLocation], len);
        NSString *cname = [className substringWithRange:crange];

        return [NSString stringWithFormat:@"%@.%@", aname, cname];
    }
    else
        return className;
}

/*****************************************************
 ********* dot object graph generation code **********
 *****************************************************/

- (BOOL)xgraphInclude {
    NSString *className = NSStringFromClass([self class]);
    return [className hasPrefix:swiftPrefix] ||
        ([className characterAtIndex:0] != '_' && ![className hasPrefix:@"NS"] && ![className hasPrefix:@"UI"] &&
         ![className hasPrefix:@"CA"] && ![className hasPrefix:@"Web"] && ![className hasPrefix:@"WAK"]);
}

- (BOOL)xgraphExclude {
    NSString *className = NSStringFromClass([self class]);
    return ![className hasPrefix:swiftPrefix] &&
        ([className characterAtIndex:0] == '_' || [className isEqual:@"CALayer"] || [className hasPrefix:@"NSIS"] ||
         [className hasSuffix:@"Constraint"] || [className hasSuffix:@"Variable"] || [className hasSuffix:@"Color"]);
}

- (NSString *)outlineColorFor:(NSString *)className {
    return graphOutlineColor;
}

- (void)xgraphLabelNode {
    if ( instancesLabeled.find(self) == instancesLabeled.end() ) {
        NSString *className = NSStringFromClass([self class]);
        instancesLabeled[self].sequence = instancesSeen[self].sequence;
        NSString *color = instancesLabeled[self].color = [self outlineColorFor:className];
        [dotGraph appendFormat:@"    %d [label=\"%@\" tooltip=\"<%@ %p> #%d\"%s%s color=\"%@\"];\n",
             instancesSeen[self].sequence, [self xclassName], className, self, instancesSeen[self].sequence,
             [self respondsToSelector:@selector(subviews)] ? " shape=box" : "",
             [self xgraphInclude] ? " style=\"filled\" fillcolor=\"#e0e0e0\"" : "", color];
    }
}

- (BOOL)xgraphConnectionTo:(id)ivar {
    int edgeID = instancesSeen[ivar].owners[self] = graphEdgeID++;
    if ( dotGraph && (__bridge CFNullRef)ivar != kCFNull &&
            (graphOptions & XGraphArrayWithoutLmit || currentMaxArrayIndex < maxArrayItemsForGraphing) &&
            (graphOptions & XGraphAllObjects || [self xgraphInclude] || [ivar xgraphInclude] ||
                (graphOptions & XGraphInterconnections &&
                 instancesLabeled.find(self) != instancesLabeled.end() &&
                 instancesLabeled.find(ivar) != instancesLabeled.end())) &&
            (graphOptions & XGraphWithoutExcepton || (![self xgraphExclude] && ![ivar xgraphExclude])) ) {
        [self xgraphLabelNode];
        [ivar xgraphLabelNode];
        [dotGraph appendFormat:@"    %d -> %d [label=\"%s\" color=\"%@\" eid=\"%d\"];\n",
            instancesSeen[self].sequence, instancesSeen[ivar].sequence, sweepState.source,
            instancesLabeled[self].color, edgeID];
        return YES;
    }
    else
        return NO;
}

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
    unsigned long flags;
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

static const char *typeInfoForClass( Class aClass ) {
    return strdup([[NSString stringWithFormat:@"@\"%s\"", class_getName(aClass)] UTF8String]);
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

    struct _swift_field *field = swiftData->get_field_data()[ivarIndex];

    // unpack any optionals
    while ( field->flags == 0x2 ) {
        if ( field->optional )
            field = field->optional;
        else
            return field->typeInfo->typeIdent;
    }

    if ( field->flags == 0x1 ) // rawtype
        return field->typeInfo->typeIdent+1;
    else if ( field->flags == 0xa ) // function
        return "^";
    else if ( field->flags == 0xc ) // protocol
        return strdup([[NSString stringWithFormat:@"@\"<%s>\"", field->optional->typeIdent] UTF8String]);
    else if ( field->flags == 0xe ) // objc class
        return typeInfoForClass(field->objcClass);
    else // swift class
        return typeInfoForClass((__bridge Class)field);
}

/*****************************************************
 ********* generic ivar/method/type access ***********
 *****************************************************/

- (id)xvalueForIvar:(Ivar)ivar inClass:(Class)aClass {
    void *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    //NSLog( @"%p %p %p %s %s %s", aClass, ivar, isSwift(aClass), ivar_getName(ivar), ivar_getTypeEncoding(ivar), ivar_getTypeEncodingSwift(ivar, aClass) );
    return [self xvalueForPointer:iptr type:ivar_getTypeEncodingSwift(ivar, aClass)];
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
        case 'C': return @(*(unsigned char *)iptr);
        case 's': return @(*(short *)iptr);
        case 'S': return @(*(unsigned short *)iptr);
        case 'i': return @(*(int *)iptr);
        case 'I': return @(*(unsigned *)iptr);

        case 'f': return @(*(float *)iptr);
        case 'd': return @(*(double *)iptr);

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
                id obj = *(const id *)iptr;
                [obj description];
                out = obj;
            }];

            return out;
        }
        case ':': return NSStringFromSelector(*(SEL *)iptr);
        case '#': {
            Class aClass = *(const Class *)iptr;
            return aClass ? [NSString stringWithFormat:@"[%@ class]", aClass] : @"Nil";
        }
        case '^': return [NSValue valueWithPointer:*(void **)iptr];

        case '{': try {
            const char *ooType = isOOType( type );
            if ( ooType )
                return [self xvalueForPointer:iptr type:ooType+5];

            // remove names for valueWithBytes:objCType:
            char cleanType[strlen(type)+1], *tptr = cleanType;
            while ( *type )
                if ( *type == '"' ) {
                    while ( *++type != '"' )
                        ;
                    type++;
                }
                else
                    *tptr++ = *type++;
            *tptr = '\000';
            return [NSValue valueWithBytes:iptr objCType:cleanType];
        }
        catch ( NSException *e ) {
            return @"raised exception";
        }
        case '*': {
            const char *ptr = *(const char **)iptr;
            return ptr ? [NSString stringWithUTF8String:ptr] : @"NULL";
        }
#if 0
        case 'b':
            return [NSString stringWithFormat:@"0x%08x", *(int *)iptr];
#endif
        default:
            return @"unknown";
    }
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
    NSString *typeStr = [self _xtype:type];
    return [NSString stringWithFormat:@"<span class=%@>%@</span>",
            [typeStr hasSuffix:@"*"] ? @"classStyle" : @"typeStyle", typeStr];
}

- (NSString *)_xtype:(const char *)type {
    if ( !type )
        return @"notype";
    switch ( type[0] ) {
        case 'V': return @"oneway void";
        case 'v': return @"void";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
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
        case 'r':
            return [@"const " stringByAppendingString:[self xtype:type+1]];
        case '*': return @"char *";
        default:
            return [NSString stringWithUTF8String:type]; //@"id";
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
    while ( isalnum(*end) || *end == '_' || *end == ',' )
        end++;
    if ( type[-1] == '<' )
        return [NSString stringWithFormat:@"id&lt;%@&gt;",
                    [self xlinkForProtocol:[NSString stringWithFormat:@"%.*s", (int)(end-type), type]]];
    else {
        NSString *className = [NSString stringWithFormat:@"%.*s", (int)(end-type), type];
        return [NSString stringWithFormat:@"<span onclick=\\'this.id=\"%@\"; "
                    "sendClient( \"class:\", \"%@\" ); event.cancelBubble=true;\\'>%@</span>%s",
                    className, className, className, star];
    }
}

- (NSString *)xlinkForProtocol:(NSString *)protocolName {
    return [NSString stringWithFormat:@"<a href=\\'#\\' onclick=\\'this.id=\"%@\"; sendClient( \"protocol:\", \"%@\" ); "
                "event.cancelBubble = true; return false;\\'>%@</a>", protocolName, protocolName, protocolName];
}

- (NSString *)xhtmlEscape {
    return [[[[[[self description]
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
               stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
              stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"]
             stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
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
        [self[i] xsweep];
    }

    currentMaxArrayIndex = saveMaxArrayIndex;
    sweepState.depth--;
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"("];

    for ( int i=0 ; i<[self count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeArray *path = [XprobeArray withPathID:pathID];
        path.sub = i;
        id obj = self[i];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
    }

    [html appendString:@")"];
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

    [html appendString:@"["];
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

@implementation NSDictionary(Xprobe)

- (void)xsweep {
    [[self allValues] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"{<br>"];

    for ( id key in [self allKeys] ) {
        [html appendFormat:@" &nbsp; &nbsp;%@ => ", key];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = self[key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSMapTable(Xprobe)

- (void)xsweep {
    [[[self objectEnumerator] allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"{<br>"];

    for ( id key in [[self keyEnumerator] allObjects] ) {
        [html appendFormat:@" &nbsp; &nbsp;%@ => ", key];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        id obj = [self objectForKey:key];
        [obj xlinkForCommand:@"open" withPathID:[path xadd:obj] into:html];
        [html appendString:@",<br>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSHashTable(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    NSArray *all = [self allObjects];

    [html appendString:@"["];
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

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
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

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
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

- (void)xopenPathID:(int)pathID into:(NSMutableString *)html
{
    AspectBlockRef blockInfo = (__bridge AspectBlockRef)self;
    BOOL hasInfo = blockInfo->flags & AspectBlockFlagsHasSignature ? YES : NO;
    [html appendFormat:@"<br>%p ^( %s ) {<br>&nbsp &nbsp; %s<br>}", blockInfo->invoke,
     hasInfo && blockInfo->descriptor->signature ?
     blockInfo->descriptor->signature : "blank",
     /*hasInfo && blockInfo->descriptor->layout ?
     blockInfo->descriptor->layout :*/ "// layout blank"];
}

@end

#endif
