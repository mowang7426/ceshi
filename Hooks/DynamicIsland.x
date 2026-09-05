// SBLiquidGlass - Dynamic Island (Mango-style)
// 基于 Mango 插件的液态灵动岛实现原理
// 主要 hook _SBGainMapView（灵动岛增益图视图，真正显示内容的视图）
// 辅助 hook _SBSystemApertureMagiciansCurtainView

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

#pragma mark - 私有类声明

@interface _SBGainMapView : UIView
@end

@interface _SBSystemApertureMagiciansCurtainView : UIView
@end

@interface SBSystemApertureViewController : UIViewController
@end

#pragma mark - 全局变量

static void *kDIGlassKey = &kDIGlassKey;
static void *kDICurtainGlassKey = &kDICurtainGlassKey;

#pragma mark - 工具函数

// 判断颜色是否为黑色
static BOOL diColorIsBlack(CGColorRef color) {
    if (!color) return NO;
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (!c) return NO;
    CGFloat r=0,g=0,b=0,a=1;
    if (n >= 4) { r=c[0]; g=c[1]; b=c[2]; a=c[3]; }
    else if (n == 2) { r=g=b=c[0]; a=c[1]; }
    return a > 0.3 && r < 0.08 && g < 0.08 && b < 0.08;
}

// 递归清除黑色背景
static void diClearBlackBackgrounds(UIView *view, NSInteger depth) {
    if (!view || depth > 20) return;
    @try {
        // 清除当前视图的黑色背景
        if (view.backgroundColor && diColorIsBlack(view.backgroundColor.CGColor)) {
            view.backgroundColor = UIColor.clearColor;
            view.opaque = NO;
        }
        if (view.layer.backgroundColor && diColorIsBlack(view.layer.backgroundColor)) {
            view.layer.backgroundColor = UIColor.clearColor.CGColor;
        }

        // 清除子层的黑色背景
        for (CALayer *sublayer in [view.layer.sublayers copy]) {
            if (sublayer.backgroundColor && diColorIsBlack(sublayer.backgroundColor)) {
                sublayer.backgroundColor = UIColor.clearColor.CGColor;
            }
            if ([sublayer isKindOfClass:[CAShapeLayer class]]) {
                CAShapeLayer *shape = (CAShapeLayer *)sublayer;
                if (shape.fillColor && diColorIsBlack(shape.fillColor)) {
                    shape.fillColor = UIColor.clearColor.CGColor;
                }
            }
        }

        // 递归清除子视图
        for (UIView *sub in [view.subviews copy]) {
            diClearBlackBackgrounds(sub, depth + 1);
        }
    } @catch (__unused NSException *e) {}
}

// 确保玻璃层存在
static LGLiveBackdropView *diEnsureGlassForView(UIView *view, void *key) {
    if (!view || !view.window) return nil;
    if (!lgHostEnabled(@"DynamicIsland")) return nil;
    if (CGRectIsEmpty(view.bounds) || CGRectGetWidth(view.bounds) < 10.0) return nil;

    LGLiveBackdropView *glass = objc_getAssociatedObject(view, key);
    CGFloat radius = view.layer.cornerRadius;
    if (radius <= 0.0) radius = CGRectGetHeight(view.bounds) * 0.5;

    if (!glass) {
        NSString *filterType = LGFilterTypeForHostPrefix(@"DynamicIsland");
        if (!filterType) filterType = @"dylv.liquidglass.dynamicisland";

        glass = [[LGLiveBackdropView alloc] initWithFrame:view.bounds
                                                 groupName:nil
                                                filterType:filterType];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.backgroundColor = UIColor.clearColor;
        glass.opaque = NO;
        glass.alpha = 1.0;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.cornerRadius = radius;
        glass.layer.masksToBounds = YES;

        // 插到最底层，在内容下面
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [glass applyFilters]; } @catch (__unused NSException *e) {}
        });

        NSLog(@"[SBLiquidGlass-DI] glass created on %s h=%.1f",
              class_getName(view.class), CGRectGetHeight(view.bounds));
    } else {
        glass.frame = view.bounds;
        glass.layer.cornerRadius = radius;
    }

    // 清除当前视图的黑色背景
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;

    return glass;
}

// 移除玻璃层
static void diRemoveGlassForView(UIView *view, void *key) {
    @try {
        LGLiveBackdropView *glass = objc_getAssociatedObject(view, key);
        if (glass) {
            [glass removeFromSuperview];
            objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Hook _SBGainMapView（主要 hook 目标）

%hook _SBGainMapView

- (void)didMoveToWindow {
    %orig;
    @try {
        if (self.window) {
            diEnsureGlassForView(self, kDIGlassKey);
            // 延迟清除黑色背景，确保内容都加载完成
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { diClearBlackBackgrounds(self, 0); } @catch (__unused NSException *e) {}
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { diClearBlackBackgrounds(self, 0); } @catch (__unused NSException *e) {}
            });
        } else {
            diRemoveGlassForView(self, kDIGlassKey);
        }
    } @catch (__unused NSException *e) {}
}

- (void)layoutSubviews {
    %orig;
    @try {
        if (self.window) {
            diEnsureGlassForView(self, kDIGlassKey);
        }
    } @catch (__unused NSException *e) {}
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    @try {
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kDIGlassKey);
        if (glass) {
            glass.hidden = hidden;
        }
    } @catch (__unused NSException *e) {}
}

%end

#pragma mark - Hook _SBSystemApertureMagiciansCurtainView（辅助 hook 目标）

%hook _SBSystemApertureMagiciansCurtainView

- (void)didMoveToWindow {
    %orig;
    @try {
        if (self.window) {
            diEnsureGlassForView(self, kDICurtainGlassKey);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { diClearBlackBackgrounds(self, 0); } @catch (__unused NSException *e) {}
            });
        } else {
            diRemoveGlassForView(self, kDICurtainGlassKey);
        }
    } @catch (__unused NSException *e) {}
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    @try {
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kDICurtainGlassKey);
        if (glass) {
            glass.hidden = hidden;
        }
    } @catch (__unused NSException *e) {}
}

%end

#pragma mark - 构造函数

%ctor {
    NSLog(@"[SBLiquidGlass-DI] Mango-style Dynamic Island hook loaded (hook _SBGainMapView + _SBSystemApertureMagiciansCurtainView)");
}
