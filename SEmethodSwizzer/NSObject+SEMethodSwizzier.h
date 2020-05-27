//
//  NSObject+SEMethodSwizzier.h
//  Coding_iOS
//
//  Created by 史贵岭 on 2017/4/21.
//  Copyright © 2017年 Coding. All rights reserved.
//

#import <Foundation/Foundation.h>


typedef void *(* SE_IMP)(__unsafe_unretained id, SEL, ...);
typedef void (^swizzleBlockTmp)();

typedef id (^SEMethodReplacementProvider)(SE_IMP original, __unsafe_unretained Class swizzledClass, SEL selector,BOOL isHooked,NSMapTable *blocks);


#define SEMethodReplacement(returntype, selftype, ...) ^ returntype (__unsafe_unretained selftype self_, ##__VA_ARGS__)
#define SEMethodReplacementProviderBlock ^ id (SE_IMP original, __unsafe_unretained Class swizzledClass, SEL comand,BOOL isHooked,NSMapTable *blocks)
#define SEOriginalImplementation(type, ...) ((__typeof(type (*)(__typeof(self_), SEL, ...)))original)(self_, comand, ##__VA_ARGS__)


@interface NSObject (SEMethodSwizzier)

+ (void)se_swizzleInstanceMethod:(SEL)selector withReplacement:(SEMethodReplacementProvider)replacementProvider UUIDname:(NSString*)UUIDname;
+ (BOOL)se_deswizzleInstanceMethod:(SEL)selector UUIDname:(NSString*)UUIDname;

@end
