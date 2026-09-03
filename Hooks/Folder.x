#import <UIKit/UIKit.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static BOOL isFolderIconMaterial(UIView *mat) {
    static Class folderCls, iconCls;
    if (!folderCls) folderCls = NSClassFromString(@"SBFolderIconImageView");
    if (!iconCls)   iconCls   = NSClassFromString(@"SBIconView");
    for (UIView *v = mat.superview; v; v = v.superview) {
        if ([v isKindOfClass:folderCls]) return YES;
        if ([v isKindOfClass:iconCls])   break;
    }
    return NO;
}

static BOOL isOpenFolderMaterial(UIView *mat) {
    if (!hasAncestorOfClassName(mat, @"SBFolderBackgroundView")) return NO;
    CGRect b = mat.bounds;
    // 更准确的判断：文件夹展开背景通常比较大，且不是正方形图标
    return CGRectGetWidth(b) >= 250.0 && CGRectGetHeight(b) >= 250.0;
}

#pragma mark - folder-open coordination

static NSHashTable<UIView *> *sFolderIconGlasses;
static NSHashTable<UIView *> *sFolderIconMaterials;
static NSHashTable<UIView *> *sOpenFolderMaterials;
static BOOL sFolderIconGlassHidden = NO; // 状态标志，避免重复调用动画

CGFloat LGFolderIconCornerRadiusFallback(void) {
    for (UIView *glass in sFolderIconGlasses.allObjects) {
        CGFloat radius = glass.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    for (UIView *material in sFolderIconMaterials.allObjects) {
        CGFloat radius = material.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    return 0.0;
}

static BOOL anyOpenFolderActive(void) {
    for (UIView *m in sOpenFolderMaterials.allObjects)
        if (m.window) return YES;
    return NO;
}

static void hideFolderIconGlasses(void) {
    if (sFolderIconGlassHidden) return; // 已经隐藏了，不重复调用
    sFolderIconGlassHidden = YES;
    for (UIView *g in sFolderIconGlasses.allObjects) {
        // 不调用 removeAllAnimations，避免动画中断跳跃
        g.hidden = YES;
        g.alpha = 1.0;
    }
}

static void fadeInFolderIconGlasses(void) {
    if (!sFolderIconGlassHidden) return; // 已经显示了，不重复调用
    sFolderIconGlassHidden = NO;
    for (UIView *g in sFolderIconGlasses.allObjects) {
        if (g.hidden) {
            g.hidden = NO;
            g.alpha = 0.0;
            [UIView animateWithDuration:0.25 delay:0.0
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ g.alpha = 1.0; }
                             completion:nil];
        }
    }
}

#pragma mark - inject

static void injectFolderIcon(UIView *mat) {
    if (!sFolderIconMaterials) sFolderIconMaterials = [NSHashTable weakObjectsHashTable];
    [sFolderIconMaterials addObject:mat];

    UIView *g = LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"FolderIcon",
                                                    UIEdgeInsetsZero, -1.0, nil);
    if (!g) return;
    if (!sFolderIconGlasses) sFolderIconGlasses = [NSHashTable weakObjectsHashTable];
    [sFolderIconGlasses addObject:g];
    g.hidden = anyOpenFolderActive();
    if (g.hidden) sFolderIconGlassHidden = YES;
}

static void injectOpenFolder(UIView *mat) {
    UIView *g = LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"OpenFolder",
                                            UIEdgeInsetsZero, -1.0, nil);
    if (!g) {
        // 注入失败，只移除材质，不立即触发动画（避免频繁闪烁）
        if (sOpenFolderMaterials && [sOpenFolderMaterials containsObject:mat]) {
            [sOpenFolderMaterials removeObject:mat];
            // 延迟检查，如果确实没有打开的文件夹了，再淡入
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
            });
        }
        return;
    }
    if (!sOpenFolderMaterials) sOpenFolderMaterials = [NSHashTable weakObjectsHashTable];
    if (![sOpenFolderMaterials containsObject:mat]) {
        [sOpenFolderMaterials addObject:mat];
        hideFolderIconGlasses();
    }
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        [sFolderIconMaterials removeObject:self_];

        if ([sOpenFolderMaterials containsObject:self_]) {
            [sOpenFolderMaterials removeObject:self_];
            // 延迟检查，避免频繁触发动画
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
            });
        }
        return;
    }
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
%end
