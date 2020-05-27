//
//  NSObject+SEMethodSwizzier.m
//  Coding_iOS
//
//  Created by 史贵岭 on 2017/4/21.
//  Copyright © 2017年 Coding. All rights reserved.
//

#import "NSObject+SEMethodSwizzier.h"
#import <objc/runtime.h>
#import <libkern/OSAtomic.h>


static OSSpinLock lock = OS_SPINLOCK_INIT;

static NSMutableDictionary *originalClassMethods;
static NSMutableDictionary *originalInstanceMethods;
static NSMutableDictionary *originalInstanceInstanceMethods;

static NSMutableDictionary *allBlocksMap;

#pragma mark Defines

#ifdef __clang__
#if __has_feature(objc_arc)
#define SE_ARC_ENABLED
#endif
#endif

#ifdef SE_ARC_ENABLED
#define SEBridgeCast(type, obj) ((__bridge type)obj)
#define releaseIfNecessary(object)
#else
#define SEBridgeCast(type, obj) ((type)obj)
#define releaseIfNecessary(object) [object release];
#endif


#define kClassKey @"k"
#define kCountKey @"c"
#define kIMPKey @"i"

// See http://clang.llvm.org/docs/Block-ABI-Apple.html#high-level
struct SE_Block_literal_1 {
    void *isa; // initialized to &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    struct Block_descriptor_1 {
        unsigned long int reserved;         // NULL
        unsigned long int size;         // sizeof(struct Block_literal_1)
        // optional helper functions
        void (*copy_helper)(void *dst, void *src);     // IFF (1<<25)
        void (*dispose_helper)(void *src);             // IFF (1<<25)
        // required ABI.2010.3.16
        const char *signature;                         // IFF (1<<30)
    } *descriptor;
    // imported variables
};

enum {
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    BLOCK_HAS_CTOR =          (1 << 26), // helpers have C++ code
    BLOCK_IS_GLOBAL =         (1 << 28),
    BLOCK_HAS_STRET =         (1 << 29), // IFF BLOCK_HAS_SIGNATURE
    BLOCK_HAS_SIGNATURE =     (1 << 30),
};
typedef int SE_BlockFlags;


NS_INLINE const char *se_blockGetType(id block) {
    struct SE_Block_literal_1 *blockRef = SEBridgeCast(struct SE_Block_literal_1 *, block);
    SE_BlockFlags flags = blockRef->flags;
    
    if (flags & BLOCK_HAS_SIGNATURE) {
        void *signatureLocation = blockRef->descriptor;
        signatureLocation += sizeof(unsigned long int);
        signatureLocation += sizeof(unsigned long int);
        
        if (flags & BLOCK_HAS_COPY_DISPOSE) {
            signatureLocation += sizeof(void(*)(void *dst, void *src));
            signatureLocation += sizeof(void (*)(void *src));
        }
        
        const char *signature = (*(const char **)signatureLocation);
        return signature;
    }
    
    return NULL;
}

NS_INLINE BOOL se_blockIsValidReplacementProvider(id block) {
    const char *blockType = se_blockGetType(block);
    
    SEMethodReplacementProvider dummy = SEMethodReplacementProviderBlock {
        return nil;
    };
    
    const char *expectedType = se_blockGetType(dummy);
    
    return (strcmp(expectedType, blockType) == 0);
}
NS_INLINE BOOL se_isHooked(__unsafe_unretained Class class, SEL selector){
    
    if (!originalInstanceMethods) {
        return NO;
    }
    
    NSString *classKey = NSStringFromClass(class);
    NSString *selectorKey = NSStringFromSelector(selector);
    
    NSMutableDictionary *classSwizzles = originalInstanceMethods[classKey];
    NSValue *pointerValue = classSwizzles[selectorKey];
    if (pointerValue) {
        return YES;
    }
    return NO;
}
NS_INLINE SE_IMP se_originalInstanceMethodImplementation(__unsafe_unretained Class class, SEL selector, BOOL fetchOnly) {
    NSCAssert(!OSSpinLockTry(&lock), @"Spin lock is not locked");
    
    if (!originalInstanceMethods) {
        originalInstanceMethods = [[NSMutableDictionary alloc] init];
    }
    
    NSString *classKey = NSStringFromClass(class);
    NSString *selectorKey = NSStringFromSelector(selector);
    
    NSMutableDictionary *classSwizzles = originalInstanceMethods[classKey];
    
    NSValue *pointerValue = classSwizzles[selectorKey];
    
    if (!classSwizzles) {
        classSwizzles = [NSMutableDictionary dictionary];
        
        originalInstanceMethods[classKey] = classSwizzles;
    }
    
    SE_IMP orig = NULL;
    
    if (pointerValue) {
        orig = [pointerValue pointerValue];
        
        if (fetchOnly) {
            [classSwizzles removeObjectForKey:selectorKey];
            if (classSwizzles.count == 0) {
                [originalInstanceMethods removeObjectForKey:classKey];
            }
        }
    }
    else if (!fetchOnly) {
        orig = (SE_IMP)[class instanceMethodForSelector:selector];
        
        classSwizzles[selectorKey] = [NSValue valueWithPointer:orig];
    }
    
    
    NSMutableDictionary *classSwizzlesTmp = originalInstanceMethods[classKey];
    if (classSwizzlesTmp && classSwizzlesTmp.count == 0) {
        [originalInstanceMethods removeObjectForKey:classKey];
    }
    
    if (originalInstanceMethods.count == 0) {
        releaseIfNecessary(originalInstanceMethods);
        originalInstanceMethods = nil;
    }
    
    return orig;
}
NS_INLINE BOOL se_blockIsCompatibleWithMethodType(id block, __unsafe_unretained Class class, SEL selector, BOOL instanceMethod) {
    const char *blockType = se_blockGetType(block);
    
    NSMethodSignature *blockSignature = [NSMethodSignature signatureWithObjCTypes:blockType];
    NSMethodSignature *methodSignature = (instanceMethod ? [class instanceMethodSignatureForSelector:selector] : [class methodSignatureForSelector:selector]);
    
    if (!blockSignature || !methodSignature) {
        return NO;
    }
    
    if (blockSignature.numberOfArguments != methodSignature.numberOfArguments) {
        return NO;
    }
    const char *blockReturnType = blockSignature.methodReturnType;
    
    if (strncmp(blockReturnType, "@", 1) == 0) {
        blockReturnType = "@";
    }
    
    if (strcmp(blockReturnType, methodSignature.methodReturnType) != 0) {
        return NO;
    }
    
    for (unsigned int i = 0; i < methodSignature.numberOfArguments; i++) {
        if (i == 0) {
            // self in method, block in block
            if (strcmp([methodSignature getArgumentTypeAtIndex:i], "@") != 0) {
                return NO;
            }
            if (strcmp([blockSignature getArgumentTypeAtIndex:i], "@?") != 0) {
                return NO;
            }
        }
        else if(i == 1) {
            // SEL in method, self in block
            if (strcmp([methodSignature getArgumentTypeAtIndex:i], ":") != 0) {
                return NO;
            }
            if (instanceMethod ? strncmp([blockSignature getArgumentTypeAtIndex:i], "@", 1) != 0 : (strncmp([blockSignature getArgumentTypeAtIndex:i], "@", 1) != 0 && strcmp([blockSignature getArgumentTypeAtIndex:i], "r^#") != 0)) {
                return NO;
            }
        }
        else {
            const char *blockSignatureArg = [blockSignature getArgumentTypeAtIndex:i];
            
            if (strncmp(blockSignatureArg, "@", 1) == 0) {
                blockSignatureArg = "@";
            }
            
            if (strcmp(blockSignatureArg, [methodSignature getArgumentTypeAtIndex:i]) != 0) {
                return NO;
            }
        }
    }
    
    return YES;
}
NS_INLINE void se_classSwizzleMethod(Class cls, Method method, IMP newImp) {
    if (!class_addMethod(cls, method_getName(method), newImp, method_getTypeEncoding(method))) {
        // class already has implementation, swizzle it instead
        method_setImplementation(method, newImp);
    }
}
NS_INLINE void se_swizzleInstanceMethod(__unsafe_unretained Class class, SEL selector, SEMethodReplacementProvider replacement,NSString* UUIDname) {
    if (!se_blockIsValidReplacementProvider(replacement)) {
        NSLog(@"Invalid method replacemt provider");
        return;
    }
    if(![class instancesRespondToSelector:selector]){
        NSLog(@"Invalid method: -[%@ %@]", NSStringFromClass(class), NSStringFromSelector(selector));
        return;
    }
    if (!(originalInstanceInstanceMethods[NSStringFromClass(class)][NSStringFromSelector(selector)] == nil)) {
        NSLog(@"Swizzling an instance method that has already been swizzled on a specific instance is not supported");
        return;
    }
    
    NSCAssert(se_blockIsValidReplacementProvider(replacement), @"Invalid method replacemt provider");
    NSCAssert([class instancesRespondToSelector:selector], @"Invalid method: -[%@ %@]", NSStringFromClass(class), NSStringFromSelector(selector));    
    NSCAssert(originalInstanceInstanceMethods[NSStringFromClass(class)][NSStringFromSelector(selector)] == nil, @"Swizzling an instance method that has already been swizzled on a specific instance is not supported");
    
    OSSpinLockLock(&lock);
    
    NSString *key = [NSString stringWithFormat:@"%@_%@",NSStringFromClass(class),NSStringFromSelector(selector)];
    if (!allBlocksMap) {
        allBlocksMap = [[NSMutableDictionary alloc] initWithCapacity:1];
    }
    NSMapTable *blocks = [allBlocksMap objectForKey:key];
    
    if (!blocks) {
        blocks = [NSMapTable mapTableWithKeyOptions:(NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPersonality)
                                       valueOptions:(NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality)];
        [allBlocksMap setObject:blocks forKey:key];
    }
    Method originalMethod = class_getInstanceMethod(class, selector);
    
    //取回第一个 需要被执行的hook
    id replaceBlock2 = replacement(NULL, NULL, NULL,YES,NULL);
    [blocks setObject:replaceBlock2 forKey:UUIDname];
    
    
    if (!se_isHooked(class, selector)) {
        SE_IMP orig = se_originalInstanceMethodImplementation(class, selector, NO);
        //真正  hook 替换
        id replaceBlock = replacement(orig, class, selector,NO,blocks);
        if (!se_blockIsCompatibleWithMethodType(replaceBlock, class, selector, YES)) {
            NSLog(@"Invalid method replacement");
            return;
        }
        NSCAssert(se_blockIsCompatibleWithMethodType(replaceBlock, class, selector, YES), @"Invalid method replacement");
        IMP replace = imp_implementationWithBlock(replaceBlock);
        se_classSwizzleMethod(class, originalMethod, replace);
    }
    //    NSLog(@"blocks = %@  p = %p,key = %@,allBlocksMap = %@",blocks,blocks,key,allBlocksMap);
    OSSpinLockUnlock(&lock);
}
NS_INLINE BOOL se_deswizzleInstanceMethod(__unsafe_unretained Class class, SEL selector,NSString* UUIDname) {
    OSSpinLockLock(&lock);
    
    if (!allBlocksMap) {
        OSSpinLockUnlock(&lock);
        return NO;
    }
    NSString *key = [NSString stringWithFormat:@"%@_%@",NSStringFromClass(class),NSStringFromSelector(selector)];
    NSMapTable *blocks = [allBlocksMap objectForKey:key];
    if (!blocks) {
        OSSpinLockUnlock(&lock);
        return NO;
    }
    if (UUIDname && [blocks objectForKey:UUIDname]) {
        [blocks removeObjectForKey:UUIDname];
        
        if (blocks.count==0) {
            SE_IMP originalIMP = se_originalInstanceMethodImplementation(class, selector, YES);
            if (originalIMP) {
                method_setImplementation(class_getInstanceMethod(class, selector), (IMP)originalIMP);
                OSSpinLockUnlock(&lock);
                return YES;
            }else {
                OSSpinLockUnlock(&lock);
                return NO;
            }
        }
        OSSpinLockUnlock(&lock);
        return YES;
    }
    OSSpinLockUnlock(&lock);
    return NO;
}
@implementation NSObject (SEMethodSwizzier)

+ (void)se_swizzleInstanceMethod:(SEL)selector withReplacement:(SEMethodReplacementProvider)replacementProvider UUIDname:(NSString*)UUIDname {
    se_swizzleInstanceMethod(self, selector, replacementProvider,UUIDname);
}
+ (BOOL)se_deswizzleInstanceMethod:(SEL)selector UUIDname:(NSString*)UUIDname {
    return se_deswizzleInstanceMethod(self, selector,UUIDname);
}
@end
