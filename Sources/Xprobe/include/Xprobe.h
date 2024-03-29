//
//  Xprobe.h
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
//  $Id: //depot/XprobePlugin/Sources/Xprobe/include/Xprobe.h#9 $
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

#ifndef XPROBE_PORT
#define XPROBE_PORT 31448
#endif
#define XPROBE_MAGIC -XPROBE_PORT*XPROBE_PORT
#define XPROBE_KEY @__FILE__

#pragma primary interface

@interface Xprobe : NSObject

// specify pattern of classes to avoid in sweep
+ (BOOL)xprobeExclude:(NSString *)className;

// take snapshot of application memeory
+ (void)snapshot:(NSString *)filepath;
+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds;
+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds excluding:(NSString *)exclusions;

#define SNAPSHOT_EXCLUSIONS @"^(?:UI|NS((Object|URL|Proxy)$|Text|Layout|Index|Mach|.*(Map|Data|Font))|Web|WAK|SwiftObject|XC|IDE|DVT|Xcode3|IB|VK)"

+ (void)_search:(NSString *)pattern;

@end

// This category must be implemented in your
// application to provide seeds for the sweep

@interface Xprobe(Seeding)
+ (NSArray *)xprobeSeeds;
@end

#pragma interface for Xprobe service (in category)

// these require Xprobe+Service.mm in your project

@interface Xprobe(Service)

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain;
+ (void)search:(NSString *)classNamePattern;
+ (void)writeString:(NSString *)str;
+ (void)open:(NSString *)input;

@end

@interface NSObject(Xprobe)

#pragma mark internal references

+ (void)xopen:(NSObject *)obj withPathID:(int)pathID into:(NSMutableString *)html;

- (void)xsweep;
- (void)xopenPathID:(int)pathID into:(NSMutableString *)html;
- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:(NSMutableString *)html;
- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar type:(const char *)type into:(NSMutableString *)html;

- (id)xvalueForKeyPath:(NSString *)key;
- (id)xvalueForKey:(NSString *)key;
- (NSString *)xhtmlEscape;

@end

#pragma XprobePath objects

@interface XprobePath : NSObject

@property int pathID;
@property const char *name;

+ (id)withPathID:(int)pathID;
- (int)xadd;
- (id)object;
- (Class)aClass;
- (NSMutableString *)xpath;

@end

// these two classes determine
// whether objects are retained

@interface XprobeRetained : XprobePath
@property (nonatomic,retain) id object;
@end

@interface XprobeAssigned : XprobePath
@property (nonatomic,assign) id object;
@end

@interface XprobeWeak : XprobePath
@property (nonatomic,weak) id object;
@end

@interface XprobeIvar : XprobePath
@property Class iClass;
@end

@interface XprobeMethod : XprobePath
@end

@interface XprobeArray : XprobePath
@property NSUInteger sub;
@end

@interface XprobeSet : XprobeArray
@end

@interface XprobeView : XprobeArray
@end

@interface XprobeDict : XprobePath
@property id sub;
@end

@interface XprobeSuper : XprobePath
@property Class aClass;
@end

// class without instance
@interface XprobeClass : XprobeSuper
@end

#pragma Xprobe globals

extern NSMutableArray<XprobePath *> *xprobePaths;
extern BOOL xprobeRetainObjects;

#pragma XprobeSwift includes

#if defined(INJECTION_III_APP) && \
    defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && \
    __has_include("iOSInjection-Swift.h")
#import <UIKit/UIKit.h>
#import "iOSInjection-Swift.h"
#else
@interface XprobeSwift : NSObject
+ (NSString *)string:(const void *)stringPtr;
+ (NSString *)stringOpt:(const void *)stringPtr;
+ (NSString *)array:(const void *)arrayPtr;
+ (NSString *)arrayOpt:(const void *)arrayPtr;
+ (NSString *)demangle:(NSString *)name;
+ (NSArray<NSString *> *)listMembers:(id)instance;
+ (void)dumpMethods:(Class)aClass into:(NSMutableString *)into;
+ (void)dumpIvars:(id)instance into:(NSMutableString *)into;
+ (void)traceBundle:(NSBundle *)bundle;
+ (void)traceClass:(Class)aClass;
+ (void)traceInstance:(id)instance;
+ (void)traceInstance:(id)instance class:(Class)aClass;
+ (void)notrace:(id)instance;
+ (void)dumpIvars:(id)instance forClass:(Class)aClass into:(NSMutableString *)into;
+ (void)xprobeSweep:(id)instance forClass:(Class)aClass;
@end
#endif
