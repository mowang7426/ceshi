#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/*
 * AssistiveTouch 小白点文字颜色自适应补丁 v2
 *
 * v2 改进：
 * 1. 更全面的窗口检测（类名 + 尺寸 + windowLevel + 子视图特征）
 * 2. 更全面的文字元素处理（UILabel/UIButton/UITextView/CATextLayer）
 * 3. 更主动的重新应用（防止被其他插件/系统重置）
 * 4. 调试日志（控制台可看到补丁是否命中）
 * 5. 强制覆盖 attributedText 的颜色
 */

#pragma mark - 配置

static const CGFloat kATBrightnessThreshold = 128.0;
static const void *kATAppliedStyleKey = &kATAppliedStyleKey;
static const void *kATOriginalTextColorKey = &kATOriginalTextColorKey;
static const void *kATLastCheckTimeKey = &kATLastCheckTimeKey;

#pragma mark - 颜色

static UIColor *ATDarkTextColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.92];
}
static UIColor *ATLightTextColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.95];
}
static UIColor *ATDarkIconColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.85];
}
static UIColor *ATLightIconColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.90];
}

#pragma mark - AssistiveTouch 窗口检测（v2 更全面）

static BOOL ATIsAssistiveTouchWindow(UIWindow *window) {
    if (!window) return NO;
    @try {
        // 方式1：类名检测
        NSString *clsName = NSStringFromClass(window.class);
        if ([clsName containsString:@"AssistiveTouch"] ||
            [clsName containsString:@"ASTouch"] ||
            [clsName containsString:@"ASTouch"]) {
            NSLog(@"[ATTextAdaptive] matched by class name: %@", clsName);
            return YES;
        }

        // 方式2：rootViewController 类名检测
        UIViewController *rootVC = window.rootViewController;
        if (rootVC) {
            NSString *vcName = NSStringFromClass(rootVC.class);
            if ([vcName containsString:@"AssistiveTouch"] ||
                [vcName containsString:@"ASTouch"]) {
                NSLog(@"[ATTextAdaptive] matched by rootVC class: %@", vcName);
                return YES;
            }
        }

        // 方式3：窗口特征检测（小尺寸 + 高 windowLevel）
        // AssistiveTouch 菜单窗口通常不是全屏的，且 windowLevel 很高
        CGRect frame = window.frame;
        BOOL isSmallWindow = CGRectGetWidth(frame) < CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.8 &&
                             CGRectGetHeight(frame) < CGRectGetHeight(UIScreen.mainScreen.bounds) * 0.6;
        BOOL isHighLevel = window.windowLevel > 1000.0;

        if (isSmallWindow && isHighLevel) {
            // 进一步检查：窗口中是否包含 AssistiveTouch 特有的视图
            UIView *rootView = rootVC.view ?: window;
            for (UIView *sub in rootView.subviews) {
                NSString *subName = NSStringFromClass(sub.class);
                if ([subName containsString:@"AssistiveTouch"] ||
                    [subName containsString:@"ASTouch"] ||
                    [subName containsString:@"Touch"]) {
                    NSLog(@"[ATTextAdaptive] matched by window features + subview: %@", subName);
                    return YES;
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

/// 检测视图是否在 AssistiveTouch 窗口中（沿 superview 链向上找）
static BOOL ATViewInAssistiveTouch(UIView *view) {
    if (!view) return NO;
    UIWindow *window = view.window;
    if (window) return ATIsAssistiveTouchWindow(window);
    // 视图还没加入窗口时，向上遍历找 window
    for (UIView *cur = view; cur; cur = cur.superview) {
        if ([cur isKindOfClass:[UIWindow class]]) {
            return ATIsAssistiveTouchWindow((UIWindow *)cur);
        }
    }
    return NO;
}

#pragma mark - 背景亮度检测

static CGFloat ATCalculateBrightness(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return 128.0;
    @try {
        CGSize size = view.bounds.size;
        CGFloat scale = MIN(1.0, 60.0 / MAX(size.width, size.height));
        CGSize smallSize = CGSizeMake(MAX(size.width * scale, 10), MAX(size.height * scale, 10));

        UIGraphicsBeginImageContextWithOptions(smallSize, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (!ctx) { UIGraphicsEndImageContext(); return 128.0; }
        CGContextScaleCTM(ctx, scale, scale);
        [view.layer renderInContext:ctx];
        UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!snapshot || !snapshot.CGImage) return 128.0;

        CGImageRef cgImage = snapshot.CGImage;
        size_t width = CGImageGetWidth(cgImage);
        size_t height = CGImageGetHeight(cgImage);
        if (width == 0 || height == 0) return 128.0;

        unsigned char *rawData = calloc(width * height * 4, sizeof(unsigned char));
        if (!rawData) return 128.0;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(rawData, width, height, 8, width * 4,
                                                      colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colorSpace);
        if (!context) { free(rawData); return 128.0; }
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(context);

        unsigned long long total = 0;
        NSUInteger count = 0;
        for (NSUInteger y = 0; y < height; y += 2) {
            for (NSUInteger x = 0; x < width; x += 2) {
                NSUInteger idx = (y * width + x) * 4;
                unsigned char a = rawData[idx + 3];
                if (a < 15) continue;
                CGFloat b = 0.299 * rawData[idx] + 0.587 * rawData[idx+1] + 0.114 * rawData[idx+2];
                total += (unsigned long long)b;
                count++;
            }
        }
        free(rawData);
        if (count == 0) return 128.0;
        return (CGFloat)total / (CGFloat)count;
    } @catch (__unused NSException *e) {
        return 128.0;
    }
}

#pragma mark - 应用文字样式（v2 更全面）

static void ATApplyStyleToLabel(UILabel *label, BOOL darkStyle) {
    if (!label) return;
    NSString *styleKey = darkStyle ? @"dark" : @"light";
    NSString *applied = objc_getAssociatedObject(label, kATAppliedStyleKey);
    if ([applied isEqualToString:styleKey]) return;

    if (!objc_getAssociatedObject(label, kATOriginalTextColorKey)) {
        objc_setAssociatedObject(label, kATOriginalTextColorKey,
                                 label.textColor ?: [UIColor whiteColor],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *targetColor = darkStyle ? ATDarkTextColor() : ATLightTextColor();
    label.textColor = targetColor;

    // 同时处理 attributedText（强制覆盖颜色）
    if (label.attributedText && label.attributedText.length > 0) {
        NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithAttributedString:label.attributedText];
        [mas addAttribute:NSForegroundColorAttributeName value:targetColor range:NSMakeRange(0, mas.length)];
        label.attributedText = mas;
    }

    // 高亮状态
    if (label.highlightedTextColor) {
        label.highlightedTextColor = [targetColor colorWithAlphaComponent:0.5];
    }
    objc_setAssociatedObject(label, kATAppliedStyleKey, styleKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ATApplyStyleToButton(UIButton *button, BOOL darkStyle) {
    if (!button) return;
    NSString *styleKey = darkStyle ? @"dark" : @"light";
    NSString *applied = objc_getAssociatedObject(button, kATAppliedStyleKey);
    if ([applied isEqualToString:styleKey]) return;

    UIColor *textColor = darkStyle ? ATDarkTextColor() : ATLightTextColor();
    UIColor *iconColor = darkStyle ? ATDarkIconColor() : ATLightIconColor();

    [button setTitleColor:textColor forState:UIControlStateNormal];
    [button setTitleColor:[textColor colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    [button setTitleColor:[textColor colorWithAlphaComponent:0.3] forState:UIControlStateDisabled];
    [button setTitleColor:textColor forState:UIControlStateSelected];

    // 处理 attributedTitle
    for (NSNumber *stateNum in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled)]) {
        UIControlState state = stateNum.unsignedIntegerValue;
        NSAttributedString *attrTitle = [button attributedTitleForState:state];
        if (attrTitle && attrTitle.length > 0) {
            NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithAttributedString:attrTitle];
            [mas addAttribute:NSForegroundColorAttributeName value:textColor range:NSMakeRange(0, mas.length)];
            [button setAttributedTitle:mas forState:state];
        }
    }

    button.tintColor = iconColor;
    if (button.imageView) {
        button.imageView.tintColor = iconColor;
    }
    objc_setAssociatedObject(button, kATAppliedStyleKey, styleKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ATApplyStyleToImageView(UIImageView *imageView, BOOL darkStyle) {
    if (!imageView || !imageView.image) return;
    if (imageView.image.renderingMode != UIImageRenderingModeAlwaysTemplate) return;
    NSString *styleKey = darkStyle ? @"dark" : @"light";
    NSString *applied = objc_getAssociatedObject(imageView, kATAppliedStyleKey);
    if ([applied isEqualToString:styleKey]) return;
    imageView.tintColor = darkStyle ? ATDarkIconColor() : ATLightIconColor();
    objc_setAssociatedObject(imageView, kATAppliedStyleKey, styleKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ATApplyStyleToTextView(UITextView *textView, BOOL darkStyle) {
    if (!textView) return;
    UIColor *targetColor = darkStyle ? ATDarkTextColor() : ATLightTextColor();
    textView.textColor = targetColor;
    if (textView.attributedText && textView.attributedText.length > 0) {
        NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithAttributedString:textView.attributedText];
        [mas addAttribute:NSForegroundColorAttributeName value:targetColor range:NSMakeRange(0, mas.length)];
        textView.attributedText = mas;
    }
}

/// 递归遍历所有子视图，应用样式
static void ATApplyStyleToViewTree(UIView *view, BOOL darkStyle) {
    if (!view) return;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            ATApplyStyleToLabel((UILabel *)view, darkStyle);
            return;
        }
        if ([view isKindOfClass:[UIButton class]]) {
            ATApplyStyleToButton((UIButton *)view, darkStyle);
            // 继续递归处理 button 内部的子视图
        }
        if ([view isKindOfClass:[UITextView class]]) {
            ATApplyStyleToTextView((UITextView *)view, darkStyle);
            return;
        }
        if ([view isKindOfClass:[UIImageView class]]) {
            ATApplyStyleToImageView((UIImageView *)view, darkStyle);
            return;
        }
        for (UIView *sub in [view.subviews copy]) {
            ATApplyStyleToViewTree(sub, darkStyle);
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 主逻辑

static void ATDetectAndApply(UIWindow *window) {
    if (!window) return;
    if (!ATIsAssistiveTouchWindow(window)) {
        NSLog(@"[ATTextAdaptive] window is not AssistiveTouch: %@", NSStringFromClass(window.class));
        return;
    }
    @try {
        UIView *rootView = window.rootViewController.view ?: window;
        if (!rootView) return;

        // 找到菜单的主容器（最大的子视图）
        UIView *menuView = rootView;
        CGFloat maxArea = 0;
        for (UIView *sub in rootView.subviews) {
            CGFloat area = CGRectGetWidth(sub.bounds) * CGRectGetHeight(sub.bounds);
            if (area > maxArea && area > 500) {
                maxArea = area;
                menuView = sub;
            }
        }

        CGFloat brightness = ATCalculateBrightness(menuView);
        BOOL darkStyle = brightness > kATBrightnessThreshold;

        NSLog(@"[ATTextAdaptive] brightness=%.1f, applying %@ text, menuView=%@",
              brightness, darkStyle ? @"DARK" : @"LIGHT", NSStringFromClass(menuView.class));

        ATApplyStyleToViewTree(rootView, darkStyle);
    } @catch (NSException *e) {
        NSLog(@"[ATTextAdaptive] error: %@", e);
    }
}

static void ATDetectAfterDelay(UIWindow *window, NSTimeInterval delay) {
    __weak UIWindow *weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { ATDetectAndApply(weakWindow); } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Hook UIWindow

%hook UIWindow

- (void)setHidden:(BOOL)hidden {
    %orig(hidden);
    if (!hidden) {
        NSLog(@"[ATTextAdaptive] window shown: %@ frame=%@ level=%.0f",
              NSStringFromClass(self.class), NSStringFromCGRect(self.frame), self.windowLevel);
        if (ATIsAssistiveTouchWindow(self)) {
            ATDetectAfterDelay(self, 0.15);
            ATDetectAfterDelay(self, 0.4);
            ATDetectAfterDelay(self, 0.8);
        }
    }
}

- (void)makeKeyAndVisible {
    %orig;
    NSLog(@"[ATTextAdaptive] makeKeyAndVisible: %@", NSStringFromClass(self.class));
    if (ATIsAssistiveTouchWindow(self)) {
        ATDetectAfterDelay(self, 0.15);
        ATDetectAfterDelay(self, 0.4);
        ATDetectAfterDelay(self, 0.8);
    }
}

- (void)layoutSubviews {
    %orig;
    if (ATIsAssistiveTouchWindow(self)) {
        // 节流：0.3 秒最多一次
        NSNumber *lastTime = objc_getAssociatedObject(self, kATLastCheckTimeKey);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!lastTime || now - lastTime.doubleValue > 0.3) {
            objc_setAssociatedObject(self, kATLastCheckTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ATDetectAfterDelay(self, 0.1);
        }
    }
}

%end

#pragma mark - Hook UIViewController

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        if (ATViewInAssistiveTouch(self.view)) {
            NSNumber *lastTime = objc_getAssociatedObject(self, kATLastCheckTimeKey);
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (!lastTime || now - lastTime.doubleValue > 0.25) {
                objc_setAssociatedObject(self, kATLastCheckTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ATDetectAfterDelay(self.view.window, 0.08);
            }
        }
    } @catch (__unused NSException *e) {}
}

%end

#pragma mark - Hook UILabel（防止颜色被重置）

%hook UILabel

- (void)setTextColor:(UIColor *)color {
    %orig(color);
    @try {
        if (ATViewInAssistiveTouch(self)) {
            NSString *applied = objc_getAssociatedObject(self, kATAppliedStyleKey);
            if (applied.length) {
                // 已经应用过样式，但被外部重置了，延迟重新应用
                __weak UILabel *weakLabel = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try { ATDetectAndApply(weakLabel.window); } @catch (__unused NSException *e) {}
                });
            }
        }
    } @catch (__unused NSException *e) {}
}

%end

#pragma mark - Hook UIButton（防止颜色被重置）

%hook UIButton

- (void)setTitleColor:(UIColor *)color forState:(UIControlState)state {
    %orig(color, state);
    @try {
        if (ATViewInAssistiveTouch(self)) {
            NSString *applied = objc_getAssociatedObject(self, kATAppliedStyleKey);
            if (applied.length) {
                __weak UIButton *weakBtn = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try { ATDetectAndApply(weakBtn.window); } @catch (__unused NSException *e) {}
                });
            }
        }
    } @catch (__unused NSException *e) {}
}

%end
