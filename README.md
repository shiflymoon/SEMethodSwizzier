# SEMethodSwizzier

//定义Hook后需要执行的block
 void(^executeBlock)(id, SEL,SEL,id,id,UIEvent*,BOOL) = ^(id view, SEL command,SEL Action,id toObj,id fromObj,UIEvent *event,BOOL res) {
            
            //执行逻辑
        };

 [UIApplication se_swizzleInstanceMethod:@selector(sendAction:to:from:forEvent:) withReplacement:^id(SE_IMP originals, __unsafe_unretained Class swizzledClass, SEL selector, BOOL isHooked, NSMapTable *blocks){
            if (isHooked) {//让内部获取到Hook需要执行的block
                return executeBlock;
            }else{
                return ^BOOL(__unsafe_unretained id self_,SEL Action,id toObj,id fromObj,UIEvent *event) {
                    BOOL result = ((__typeof(BOOL (*)(__typeof(self_), SEL, ...)))originals)(self_, selector,Action,toObj,fromObj,event);
                    NSEnumerator *AllBlocks = [blocks objectEnumerator];
                    void (^swizzleBlock)();
                    //从注册的Map中取出所有block依次执行
                    while ((swizzleBlock = [AllBlocks nextObject])) {
                        swizzleBlock(self_, selector,Action,toObj,fromObj,event,result);
                    }
                    return result;
                };
            }
        } UUIDname:@"UIApplication-ID"];
