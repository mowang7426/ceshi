#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/*
 * AssistiveTouch 小白点文字颜色自适应补丁
 *
 * 问题：液态玻璃插件给小白点菜单注入玻璃效果后，背景可能变亮或变暗，
 *      原本固定的白色文字在浅色背景上看不清。
 *
 * 方案：保留液态玻璃效果，自动检测菜单背景亮度，动态调整文字和图标颜色：
 *      - 浅色背景（亮度 > 128）→ 黑色文字 + 深色图标
 *      - 深色背景（亮度 ≤ 128）→ 白色文字 + 浅色图标
 *
 * 使用方法：
 * 1. 把本文件放到 Hooks/ 目录
 * 2. 在 Makefile 的 sbliquidglass_FILES 中加上 Hooks/AssistiveTouchTextAdaptive.x
 * 3. 重新编译打包
 *
 * 注意：本补丁不移除液态玻璃，只调整文字颜色，和液态玻璃插件共存。
 */

#pragma mark - 配置

/// 亮度阈值（0-255），大于此值视为浅色背景，用深色文字
static const CGFloat kATBrightnessThreshold = 128.0;

/// 浅色背景下的文字颜色（黑色，带一点透明度更自然）
static UIColor *kATDarkTextColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.90];
}

/// 深色背景下的文字颜色（白色，带一点透明度更自然）
static UIColor *kATLightTextColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.95];
}

/// 浅色背景下的图标 tintColor
static UIColor *kATDarkIconColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.85];
}

/// 深色背景下的图标 tintColor
static UIColor *kATLightIconColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.90];
}

#pragma mark - 关联对象 Key

static void *kATOriginalTextColorKey = &kATOriginalTextColorKey;
static void *kATOriginalTintColorKey = &kATOriginalTintColorKey;
static void *kATAppliedStyleKey = &kATAppliedStyleKey; // @"dark" / @"light"

#pragma mark - AssistiveTouch 窗口检测

static BOOL ATIsAssistiveTouchWindow(UIWindow *window) {
    if (!window) return NO;
    @try {
        NSString *clsName = NSStringFromClass(window.class);
        if ([clsName containsString:@"AssistiveTouch"] ||
            [clsName containsString:@"ASTouch"]) {
            return YES;
        }
        UIViewController *rootVC = window.rootViewController;
        if (rootVC) {
            NSString *vcName = NSStringFromClass(rootVC.class);
            if ([vcName containsString:@"AssistiveTouch"] ||
                [vcName containsString:@"ASTouch"]) {
                return YES;
            }
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

#pragma mark - 背景亮度检测

/// 截取视图区域并计算平均亮度（0-255）
static CGFloat ATCalculateAverageBrightness(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return 128.0;
    @try {
        CGSize size = view.bounds.size;
        // 缩小尺寸计算，提高性能
        CGFloat scale = MIN(1.0, 80.0 / MAX(size.width, size.height));
        CGSize smallSize = CGSizeMake(size.width * scale, size.height * scale);

        UIGraphicsBeginImageContextWithOptions(smallSize, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (!ctx) {
            UIGraphicsEndImageContext();
            return 128.0;
        }
        // 缩放绘制
        CGContextScaleCTM(ctx, scale, scale);
        [view.layer renderInContext:ctx];
        UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (!snapshot) return 128.0;

        // 计算平均亮度
        CGImageRef cgImage = snapshot.CGImage;
        if (!cgImage) return 128.0;

        size_t width = CGImageGetWidth(cgImage);
        size_t height = CGImageGetHeight(cgImage);
        if (width == 0 || height == 0) return 128.0;

        unsigned char *rawData = calloc(width * height * 4, sizeof(unsigned char));
        if (!rawData) return 128.0;

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(rawData, width, height, 8,
                                                      width * 4, colorSpace,
                                                      kCGImageAlphaPremultipliedLast |
                                                      kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colorSpace);

        if (!context) {
            free(rawData);
            return 128.0;
        }

        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(context);

        // 采样计算平均亮度（跳过纯透明像素）
        unsigned long long totalBrightness = 0;
        NSUInteger pixelCount = 0;
        NSUInteger step = 2; // 隔行采样，提高性能
        for (NSUInteger y = 0; y < height; y += step) {
            for (NSUInteger x = 0; x < width; x += step) {
                NSUInteger index = (y * width + x) * 4;
                unsigned char alpha = rawData[index + 3];
                if (alpha < 10) continue; // 跳过接近透明的像素
                unsigned char r = rawData[index];
                unsigned char g = rawData[index + 1];
                unsigned char b = rawData[index + 2];
                // 人眼感知亮度公式
                CGFloat brightness = 0.299 * r + 0.587 * g + 0.114 * b;
                totalBrightness += (unsigned long long)brightness;
                pixelCount++;
            }
        }
        free(rawData);

        if (pixelCount == 0) return 128.0;
        return (CGFloat)totalBrightness / (CGFloat)pixelCount;
    } @catch (__unused NSException *e) {
        return 128.0;
    }
}

#pragma mark - 文字/图标颜色调整

/// 递归遍历视图，调整所有 UILabel 和 UIImageView 的颜色
static void ATApplyTextStyleToView(UIView *view, BOOL useDarkStyle) {
    if (!view) return;
    @try {
        NSString *styleKey = useDarkStyle ? @"dark" : @"light";

        // 处理 UILabel
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            NSString *applied = objc_getAssociatedObject(label, kATAppliedStyleKey);
            if ([applied isEqualToString:styleKey]) return; // 已经是这个样式，跳过

            // 保存原始颜色（只保存一次）
            if (!objc_getAssociatedObject(label, kATOriginalTextColorKey)) {
                objc_setAssociatedObject(label, kATOriginalTextColorKey,
                                         label.textColor ?: [UIColor whiteColor],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }

            label.textColor = useDarkStyle ? kATDarkTextColor() : kATLightTextColor();
            // 高亮状态也同步
            if (label.highlightedTextColor) {
                label.highlightedTextColor = useDarkStyle
                    ? [UIColor colorWithWhite:0.0 alpha:0.6]
                    : [UIColor colorWithWhite:1.0 alpha:0.6];
            }
            objc_setAssociatedObject(label, kATAppliedStyleKey, styleKey,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return;
        }

        // 处理 UIButton（内部有 titleLabel 和 imageView）
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            NSString *applied = objc_getAssociatedObject(button, kATAppliedStyleKey);
            if (![applied isEqualToString:styleKey]) {
                UIColor *textColor = useDarkStyle ? kATDarkTextColor() : kATLightTextColor();
                UIColor *iconColor = useDarkStyle ? kATDarkIconColor() : kATLightIconColor();
                [button setTitleColor:textColor forState:UIControlStateNormal];
                [button setTitleColor:[textColor colorWithAlphaComponent:0.5]
                             forState:UIControlStateHighlighted];
                [button setTitleColor:[textColor colorWithAlphaComponent:0.3]
                             forState:UIControlStateDisabled];
                button.tintColor = iconColor;
                if (button.imageView) {
                    button.imageView.tintColor = iconColor;
                }
                objc_setAssociatedObject(button, kATAppliedStyleKey, styleKey,
                                         OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
            // 继续递归处理子视图
        }

        // 处理 UIImageView（模板图标）
        if ([view isKindOfClass:[UIImageView class]]) {
            UIImageView *imageView = (UIImageView *)view;
            // 只处理模板渲染模式的图片（系统图标通常是这个模式）
            if (imageView.image && imageView.image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
                NSString *applied = objc_getAssociatedObject(imageView, kATAppliedStyleKey);
                if (![applied isEqualToString:styleKey]) {
                    if (!objc_getAssociatedObject(imageView, kATOriginalTintColorKey)) {
                        objc_setAssociatedObject(imageView, kATOriginalTintColorKey,
                                                 imageView.tintColor ?: [UIColor whiteColor],
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    imageView.tintColor = useDarkStyle ? kATDarkIconColor() : kATLightIconColor();
                    objc_setAssociatedObject(imageView, kATAppliedStyleKey, styleKey,
                                             OBJC_ASSOCIATION_COPY_NONATOMIC);
                }
            }
            return;
        }

        // 递归处理子视图
        for (UIView *subview in view.subviews) {
            ATApplyTextStyleToView(subview, useDarkStyle);
        }
    } @catch (__unused NSException *e) {}
}

/// 恢复原始文字颜色（一般不需要，切换样式时会自动覆盖）
static void ATRestoreOriginalTextStyle(UIView *view) {
    if (!view) return;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            UIColor *original = objc_getAssociatedObject(label, kATOriginalTextColorKey);
            if (original) label.textColor = original;
            objc_setAssociatedObject(label, kATAppliedStyleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return;
        }
        if ([view isKindOfClass:[UIImageView class]]) {
            UIImageView *imageView = (UIImageView *)view;
            UIColor *original = objc_getAssociatedObject(imageView, kATOriginalTintColorKey);
            if (original) imageView.tintColor = original;
            objc_setAssociatedObject(imageView, kATAppliedStyleKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            return;
        }
        for (UIView *subview in view.subviews) {
            ATRestoreOriginalTextStyle(subview);
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 主逻辑：检测亮度并应用样式

static void ATDetectAndApplyTextStyle(UIWindow *window) {
    if (!window || !ATIsAssistiveTouchWindow(window)) return;
    @try {
        UIView *rootView = window.rootViewController.view ?: window;
        if (!rootView) return;

        // 找到菜单的容器视图（最大的子视图）
        UIView *menuView = rootView;
        CGFloat maxArea = 0;
        for (UIView *sub in rootView.subviews) {
            CGFloat area = CGRectGetWidth(sub.bounds) * CGRectGetHeight(sub.bounds);
            if (area > maxArea && area > 1000) {
                maxArea = area;
                menuView = sub;
            }
        }

        // 计算背景平均亮度
        CGFloat brightness = ATCalculateAverageBrightness(menuView);
        BOOL useDarkStyle = brightness > kATBrightnessThreshold;

        // 调试日志（可注释掉）
        NSLog(@"[ATTextAdaptive] brightness=%.1f, style=%@",
              brightness, useDarkStyle ? @"dark-text" : @"light-text");

        // 应用文字样式
        ATApplyTextStyleToView(rootView, useDarkStyle);
    } @catch (__unused NSException *e) {
        NSLog(@"[ATTextAdaptive] error: %@", e);
    }
}

/// 延迟执行，确保液态玻璃已经注入完成
static void ATDetectAndApplyAfterDelay(UIWindow *window, NSTimeInterval delay) {
    __weak UIWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            ATDetectAndApplyTextStyle(weakWindow);
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Hook UIWindow

%hook UIWindow

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);
    if (!hidden && ATIsAssistiveTouchWindow(self)) {
        // 延迟执行，等液态玻璃注入完成
        ATDetectAndApplyAfterDelay(self, 0.2);
        ATDetectAndApplyAfterDelay(self, 0.5); // 再补一次，确保动画完成
    }
}

- (void)makeKeyAndVisible {
    %orig;
    if (ATIsAssistiveTouchWindow(self)) {
        ATDetectAndApplyAfterDelay(self, 0.2);
        ATDetectAndApplyAfterDelay(self, 0.5);
    }
}

%end

#pragma mark - Hook UIViewController（菜单展开/收起时重新检测）

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        if (ATIsAssistiveTouchWindow(self.view.window)) {
            // 节流：用关联对象记录上次检测时间
            NSNumber *lastTime = objc_getAssociatedObject(self, kATAppliedStyleKey);
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (!lastTime || now - lastTime.doubleValue > 0.3) {
                objc_setAssociatedObject(self, kATAppliedStyleKey, @(now),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ATDetectAndApplyAfterDelay(self.view.window, 0.1);
            }
        }
    } @catch (__unused NSException *e) {}
}

%end

#pragma mark - Hook UILabel（防止液态玻璃或系统重置文字颜色）

%hook UILabel

- (void)setTextColor:(UIColor *)color {
    %orig(color);
    @try {
        // 如果这个 label 在 AssistiveTouch 窗口中，且我们已经应用过样式，
        // 但系统/其他插件又改了颜色，就重新检测一次
        if (ATIsAssistiveTouchWindow(self.window)) {
            NSString *applied = objc_getAssociatedObject(self, kATAppliedStyleKey);
            if (applied.length) {
                // 延迟重新检测，避免和其他插件的设置冲突
                __weak UILabel *weakLabel = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        ATDetectAndApplyTextStyle(weakLabel.window);
                    } @catch (__unused NSException *e) {}
                });
            }
        }
    } @catch (__unused NSException *e) {}
}

%end
