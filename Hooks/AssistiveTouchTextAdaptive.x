// AssistiveTouch 小白点菜单文字自适应 v3
// 直接 hook AssistiveTouch 窗口，强制把文字和图标改成深色（浅色背景下清晰可见）
// 编译时需要加入 Makefile 的 FILES 列表

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 工具函数

// 判断是否是 AssistiveTouch 窗口
static BOOL ATIsAssistiveTouchWindow(UIWindow *window) {
    if (!window) return NO;
    NSString *className = NSStringFromClass([window class]);
    // 类名包含 ASTouch 或 AssistiveTouch
    if ([className rangeOfString:@"ASTouch" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([className rangeOfString:@"AssistiveTouch" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    // 高 windowLevel + 小尺寸窗口（AssistiveTouch 菜单通常 windowLevel 很高）
    if (window.windowLevel > 1000 && window.bounds.size.width < [UIScreen mainScreen].bounds.size.width * 0.8) {
        // 检查子视图里有没有 ASTouch 相关的类
        for (UIView *subview in window.subviews) {
            NSString *subClassName = NSStringFromClass([subview class]);
            if ([subClassName rangeOfString:@"ASTouch" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            if ([subClassName rangeOfString:@"Assistive" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
    }
    return NO;
}

// 获取当前应该用的文字颜色（根据窗口的深浅模式）
static UIColor *ATAdaptiveTextColor(UIView *view) {
    if (!view) return [UIColor blackColor];
    // 检查 traitCollection 的 userInterfaceStyle
    if (@available(iOS 12.0, *)) {
        UIUserInterfaceStyle style = view.traitCollection.userInterfaceStyle;
        if (style == UIUserInterfaceStyleDark) {
            // 深色模式：用浅色文字
            return [UIColor whiteColor];
        }
    }
    // 浅色模式：用深色文字（AssistiveTouch 菜单在浅色壁纸上玻璃背景会很亮，深色字最清晰）
    return [UIColor blackColor];
}

// 递归遍历视图，把所有文字和图标改成自适应颜色
static void ATApplyAdaptiveColorToView(UIView *view, UIColor *textColor) {
    if (!view || !textColor) return;

    // 处理 UILabel
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        label.textColor = textColor;
        // 同时处理 attributedText
        if (label.attributedText) {
            NSMutableAttributedString *mutable = [[NSMutableAttributedString alloc] initWithAttributedString:label.attributedText];
            [mutable addAttribute:NSForegroundColorAttributeName value:textColor range:NSMakeRange(0, mutable.length)];
            label.attributedText = mutable;
        }
    }

    // 处理 UIButton
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        [button setTitleColor:textColor forState:UIControlStateNormal];
        [button setTitleColor:textColor forState:UIControlStateHighlighted];
        [button setTitleColor:textColor forState:UIControlStateSelected];
        // 处理按钮里的图片图标（模板图标）
        if (button.imageView) {
            UIImage *image = button.imageView.image;
            if (image && image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
                button.tintColor = textColor;
            }
        }
    }

    // 处理 UIImageView（模板图标）
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        UIImage *image = imageView.image;
        if (image && image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
            imageView.tintColor = textColor;
        }
    }

    // 递归处理子视图
    for (UIView *subview in view.subviews) {
        ATApplyAdaptiveColorToView(subview, textColor);
    }
}

// 对 AssistiveTouch 窗口应用文字自适应
static void ATApplyToWindowIfNeeded(UIWindow *window) {
    if (!ATIsAssistiveTouchWindow(window)) return;
    UIColor *textColor = ATAdaptiveTextColor(window);
    ATApplyAdaptiveColorToView(window, textColor);
}

#pragma mark - Hook UIWindow layoutSubviews

static void (*original_UIWindow_layoutSubviews)(UIWindow *, SEL);

static void hooked_UIWindow_layoutSubviews(UIWindow *self, SEL _cmd) {
    original_UIWindow_layoutSubviews(self, _cmd);
    @autoreleasepool {
        ATApplyToWindowIfNeeded(self);
    }
}

#pragma mark - Hook UILabel setTextColor: （防止被系统重置回白色）

static void (*original_UILabel_setTextColor)(UILabel *, SEL, UIColor *);

static void hooked_UILabel_setTextColor(UILabel *self, SEL _cmd, UIColor *color) {
    // 检查这个 label 是否在 AssistiveTouch 窗口里
    UIView *superview = self.superview;
    while (superview) {
        if ([superview isKindOfClass:[UIWindow class]]) {
            if (ATIsAssistiveTouchWindow((UIWindow *)superview)) {
                // 在 AssistiveTouch 窗口里，强制用自适应颜色
                UIColor *adaptiveColor = ATAdaptiveTextColor(self);
                original_UILabel_setTextColor(self, _cmd, adaptiveColor);
                return;
            }
            break;
        }
        superview = superview.superview;
    }
    original_UILabel_setTextColor(self, _cmd, color);
}

#pragma mark - Hook UIButton setTitleColor:forState:

static void (*original_UIButton_setTitleColor_forState)(UIButton *, SEL, UIColor *, UIControlState);

static void hooked_UIButton_setTitleColor_forState(UIButton *self, SEL _cmd, UIColor *color, UIControlState state) {
    UIView *superview = self.superview;
    while (superview) {
        if ([superview isKindOfClass:[UIWindow class]]) {
            if (ATIsAssistiveTouchWindow((UIWindow *)superview)) {
                UIColor *adaptiveColor = ATAdaptiveTextColor(self);
                original_UIButton_setTitleColor_forState(self, _cmd, adaptiveColor, state);
                return;
            }
            break;
        }
        superview = superview.superview;
    }
    original_UIButton_setTitleColor_forState(self, _cmd, color, state);
}

#pragma mark - 构造函数

__attribute__((constructor))
static void AssistiveTouchTextAdaptiveInitialize(void) {
    @autoreleasepool {
        // Hook UIWindow layoutSubviews
        Class windowClass = objc_getClass("UIWindow");
        if (windowClass) {
            Method originalMethod = class_getInstanceMethod(windowClass, @selector(layoutSubviews));
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                original_UIWindow_layoutSubviews = (void (*)(UIWindow *, SEL))originalImp;
                method_setImplementation(originalMethod, (IMP)hooked_UIWindow_layoutSubviews);
            }
        }

        // Hook UILabel setTextColor:
        Class labelClass = objc_getClass("UILabel");
        if (labelClass) {
            Method originalMethod = class_getInstanceMethod(labelClass, @selector(setTextColor:));
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                original_UILabel_setTextColor = (void (*)(UILabel *, SEL, UIColor *))originalImp;
                method_setImplementation(originalMethod, (IMP)hooked_UILabel_setTextColor);
            }
        }

        // Hook UIButton setTitleColor:forState:
        Class buttonClass = objc_getClass("UIButton");
        if (buttonClass) {
            Method originalMethod = class_getInstanceMethod(buttonClass, @selector(setTitleColor:forState:));
            if (originalMethod) {
                IMP originalImp = method_getImplementation(originalMethod);
                original_UIButton_setTitleColor_forState = (void (*)(UIButton *, SEL, UIColor *, UIControlState))originalImp;
                method_setImplementation(originalMethod, (IMP)hooked_UIButton_setTitleColor_forState);
            }
        }

        NSLog(@"[ATTextAdaptive] v3 已加载 - AssistiveTouch 小白点文字自适应");
    }
}
