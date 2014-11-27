//
//  $Id: //depot/InjectionPluginLite/Classes/BundleSweeper.h#11 $
//  Injection
//
//  Created by John Holdsworth on 12/11/2014.
//  Copyright (c) 2012 John Holdsworth. All rights reserved.
//
//  Client application interface to Code Injection system.
//  Added to program's main.(m|mm) to connect to the Injection app.
//
//  This file is copyright and may not be re-distributed, whole or in part.
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
//

#import <objc/runtime.h>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#ifndef XPROBE_BUNDLE
#import <UIKit/UIKit.h>

@interface CCDirector
+ (CCDirector *)sharedDirector;
@end
#endif
@implementation BundleInjection(BundleSeeds)

+ (NSArray *)bprobeSeeds {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    [seeds insertObject:app atIndex:0];

    // support for cocos2d
    Class ccDirectorClass = NSClassFromString(@"CCDirector");
    CCDirector *ccDirector = [ccDirectorClass sharedDirector];
    if ( ccDirector )
        [seeds addObject:ccDirector];
    return seeds;
}

@end
#else
#import <Cocoa/Cocoa.h>

@implementation BundleInjection(BundleSeeds)
+ (NSArray *)bprobeSeeds {
    return @[[NSApp keyWindow]];
}
@end
#endif

// support for Objective-C++ reference classes
static const char *isOOType( const char *type ) {
    return strncmp( type, "{OO", 3 ) == 0 ? strstr( type, "\"ref\"" ) : NULL;
}

@interface NSObject(BundleReferences)

// external references
- (NSArray *)getNSArray;
- (NSArray *)subviews;
- (id)contentView;
- (id)document;
- (id)delegate;
- (SEL)action;
- (id)target;

@end

@interface BundleInjection(Sweeper)
+ (NSMutableDictionary *)instancesSeen;
+ (NSMutableArray *)liveInstances;
@end

@implementation NSObject(BundleSweeper)

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

static const char *strfmt( NSString *fmt, ... ) {
    va_list argp;
    va_start(argp, fmt);
    return strdup([[[NSString alloc] initWithFormat:fmt arguments:argp] UTF8String]);
}

static const char *typeInfoForClass( Class aClass ) {
    return strfmt( @"@\"%s\"", class_getName(aClass) );
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

    struct _swift_field *field = swiftData->get_field_data()[ivarIndex];

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
                return strfmt(@"{%s}", skipSwift(typeIdent) );
            else
                return strfmt(@"{%s}", skipSwift(skipSwift(typeIdent)) );
        }
        else
            return field->typeInfo->typeIdent+1;
    }
    else if ( field->flags == 0xa ) // function
        return "^{CLOSURE}";
    else if ( field->flags == 0xc ) // protocol
        return strfmt(@"@\"<%s>\"", field->optional->typeIdent);
    else if ( field->flags == 0xe ) // objc class
        return typeInfoForClass(field->objcClass);
    else if ( field->flags == 0x10 ) // pointer
        return strfmt(@"^{%s}", skipSwift(field->typeIdent) );
    else if ( field->flags < 0x100 ) // unknown/bad isa
        return strfmt(@"?FLAGS#%d", (int)field->flags);
    else // swift class
        return typeInfoForClass((__bridge Class)field);
}

/*****************************************************
 ********* sweep and object display methods **********
 *****************************************************/

+ (void)bsweep {
}

- (void)bsweep {
    Class bundleInjection = objc_getClass("BundleInjection");
    NSString *key = [NSString stringWithFormat:@"%p", self];
    if ( [bundleInjection instancesSeen][key] )
        return;

    [bundleInjection instancesSeen][key] = @"1";

    Class aClass = object_getClass(self);
    NSString *className = NSStringFromClass(aClass);
    if ( [className characterAtIndex:1] == '_' )
        return;
    else
        [[bundleInjection liveInstances] addObject:self];

    //printf("BundleSweeper sweep %d: <%s %p> %d\n", sweepState.depth, [className UTF8String], self, legacy);

    for ( ; aClass && aClass != [NSObject class] ; aClass = class_getSuperclass(aClass) ) {
        unsigned ic;
        Ivar *ivars = class_copyIvarList(aClass, &ic);
        const char *currentClassName = class_getName(aClass), firstChar = currentClassName[0];

        if ( firstChar != '_' && !(firstChar == 'N' && currentClassName[1] == 'S') )
            for ( unsigned i=0 ; i<ic ; i++ ) {
                const char *type = ivar_getTypeEncodingSwift(ivars[i],aClass);
                if ( type && type[0] == '@' ) {
                    __unused const char *currentIvarName = ivar_getName(ivars[i]);
                    id subObject = [self bvalueForIvar:ivars[i] inClass:aClass];
                    if ( [subObject respondsToSelector:@selector(bsweep)] )
                        [subObject bsweep];
                }
            }

        free( ivars );
    }

    if ( [self respondsToSelector:@selector(target)] )
        [[self target] bsweep];
    if ( [self respondsToSelector:@selector(delegate)] )
        [[self delegate] bsweep];
    if ( [self respondsToSelector:@selector(document)] )
        [[self document] bsweep];

    if ( [self respondsToSelector:@selector(contentView)] )
        [[[self contentView] superview] bsweep];
    if ( [self respondsToSelector:@selector(subviews)] )
        [[self subviews] bsweep];
    if ( [self respondsToSelector:@selector(getNSArray)] )
        [[self getNSArray] bsweep];
}

/*****************************************************
 ********* generic ivar/method/type access ***********
 *****************************************************/

- (id)bvalueForIvar:(Ivar)ivar inClass:(Class)aClass {
    void *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    return [self bvalueForPointer:iptr type:ivar_getTypeEncodingSwift(ivar, aClass)];
}

static NSString *trapped = @"#INVALID", *notype = @"#TYPE";

- (id)bvalueForPointer:(void *)iptr type:(const char *)type {
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

            [self bprotect:^{
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

        case '{': @try {
                const char *ooType = isOOType( type );
                if ( ooType )
                    return [self bvalueForPointer:iptr type:ooType+5];

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
            @catch ( NSException *e ) {
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

- (int)bprotect:(void (^)())blockToProtect {
    void (*savetrap)(int) = signal( SIGTRAP, handler );
    void (*savesegv)(int) = signal( SIGSEGV, handler );
    void (*savebus )(int) = signal( SIGBUS,  handler );

    int signum;
    switch ( signum = setjmp( jmp_env ) ) {
        case 0:
            blockToProtect();
            break;
        default:
            ;///[BundleSweeper writeString:[NSString stringWithFormat:@"SIGNAL: %d", signum]];
    }

    signal( SIGBUS,  savebus  );
    signal( SIGSEGV, savesegv );
    signal( SIGTRAP, savetrap );
    return signum;
}
@end

@implementation NSArray(BundleSweeper)

- (void)bsweep {
    for ( NSObject *obj in self )
        [obj bsweep];
}

@end

@implementation NSSet(BundleSweeper)

- (void)bsweep {
    [[self allObjects] bsweep];
}

@end

@implementation NSDictionary(BundleSweeper)

- (void)bsweep {
    [[self allValues] bsweep];
}

@end

@implementation NSMapTable(BundleSweeper)

- (void)bsweep {
    [[[self objectEnumerator] allObjects] bsweep];
}

@end

@implementation NSHashTable(BundleSweeper)

- (void)bsweep {
    [[self allObjects] bsweep];
}

@end

@implementation NSString(BundleSweeper)

- (void)bsweep {
}

@end

@implementation NSValue(BundleSweeper)

- (void)bsweep {
}

@end

@implementation NSData(BundleSweeper)

- (void)bsweep {
}

@end

@interface NSBlock : NSObject
@end

@implementation NSBlock(BundleSweeper)

- (void)bsweep {
}

@end

static NSMutableDictionary *instancesSeen;
static NSMutableArray *liveInstances;

@implementation BundleInjection(Sweeper)

+ (NSMutableDictionary *)instancesSeen {
    return instancesSeen;
}

+ (void)setInstancesSeen:(NSMutableDictionary *)dictionary {
    instancesSeen = dictionary;
}

+ (NSMutableArray *)liveInstances {
    return liveInstances;
}

+ (void)setLiveInstances:(NSMutableArray *)array {
    liveInstances = array;
}

+ (NSArray *)sweepForLiveObjects {
    Class bundleInjection = objc_getClass("BundleInjection");
    bundleInjection.instancesSeen = [NSMutableDictionary new];
    bundleInjection.liveInstances = [NSMutableArray new];

    //NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    [[self bprobeSeeds] bsweep];
    //NSLog( @"%f", [NSDate timeIntervalSinceReferenceDate]-start );

    return bundleInjection.liveInstances;
}

@end
