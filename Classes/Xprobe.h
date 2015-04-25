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

#import <Foundation/Foundation.h>

#define XPROBE_PORT 31448
#define XPROBE_MAGIC -XPROBE_PORT*XPROBE_PORT

@interface Xprobe : NSObject

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain;
+ (void)search:(NSString *)classNamePattern;

+ (BOOL)xprobeExclude:(NSString *)className;

#define SNAPSHOT_EXCLUSIONS @"^(?:UI|NS((Object|URL|Proxy)$|Text|Layout|Index|.*(Map|Data|Font))|Web|WAK|SwiftObject|XC|IDE|DVT|Xcode3|IB|VK)"

+ (void)snapshot:(NSString *)filepath;
+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds;
+ (NSString *)snapshot:(NSString *)filepath seeds:(NSArray *)seeds excluding:(NSString *)exclusions;

@end

@interface NSRegularExpression(Xprobe)

+ (NSRegularExpression *)xsimpleRegexp:(NSString *)pattern;
- (BOOL)xmatches:(NSString *)str;

@end

//@interface Xprobe(Seeding)
//
//+ (NSArray *)xprobeSeeds;
//
//@end
