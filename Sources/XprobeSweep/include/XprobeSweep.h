//
// All XprobeSwift needs to know about Xprobe
// so XprobeSwift can be a depency of Xprobe.
//

#import <Foundation/Foundation.h>

@interface NSObject(XprobeSweep)
- (void)xsweep;
- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID
                   into:(NSMutableString *)html;
@end

@interface XprobeRetained : NSObject
- (void)setObject:obj;
- (int)xadd;
@end
