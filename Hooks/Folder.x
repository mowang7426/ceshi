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
    return CGRectGetWidth(b) >= 200.0 && CGRectGetHeight(b) >= 200.0;
}

#pragma mark - folder-open coordination

static NSHashTable<UIView *> *sFolderIconGlasses;
static NSHashTable<UIView *> *sFolderIconMaterials;
static NSHashTable<UIView *> *sOpenFolderMaterials;

// 状态标志：避免反复调用 hide/fadeIn 导致闪烁
static BOOL sFolderIconGlassHidden = NO;
// 延迟检查的 block，避免在动画过程中反复调用
static dispatch_block_t sFolderIconDelayedCheck = nil;

CGFloat LGFolderIconCornerRadiusFallback(void) {
    // app icon glass borrows this when its image view exposes no radius
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
    // 已经隐藏了就不要重复调用，避免闪烁
    if (sFolderIconGlassHidden) return;
    sFolderIconGlassHidden = YES;

    // open folder and folder icon captures cannot overlap cleanly
    for (UIView *g in sFolderIconGlasses.allObjects) {
        // 不要调用 removeAllAnimations，会导致动画中断产生闪烁
        // 用动画淡出，而不是直接隐藏
        g.alpha = 1.0;
        [UIView animateWithDuration:0.15 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ g.alpha = 0.0; }
                         completion:^(BOOL finished) {
                             if (sFolderIconGlassHidden) {
                                 g.hidden = YES;
                                 g.alpha = 1.0;
                             }
                         }];
    }
}

static void fadeInFolderIconGlasses(void) {
    // 已经显示了就不要重复调用，避免闪烁
    if (!sFolderIconGlassHidden) return;
    sFolderIconGlassHidden = NO;

    for (UIView *g in sFolderIconGlasses.allObjects) {
        g.hidden = NO;
        g.alpha = 0.0;
        [UIView animateWithDuration:0.2 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ g.alpha = 1.0; }
                         completion:nil];
    }
}

// 延迟检查：避免在动画过程中反复调用 hide/fadeIn
static void scheduleFolderIconCheck(void) {
    if (sFolderIconDelayedCheck) {
        dispatch_block_cancel(sFolderIconDelayedCheck);
    }
    sFolderIconDelayedCheck = dispatch_block_create(0, ^{
        if (anyOpenFolderActive()) {
            hideFolderIconGlasses();
        } else {
            fadeInFolderIconGlasses();
        }
    });
    // 延迟 0.3 秒检查，等文件夹打开动画完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), sFolderIconDelayedCheck);
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
    // 根据当前状态设置 hidden
    g.hidden = sFolderIconGlassHidden;
}

static void injectOpenFolder(UIView *mat) {
    if (!LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"OpenFolder",
                                            UIEdgeInsetsZero, -1.0, nil)) {
        // 安装失败，延迟检查是否需要显示文件夹图标玻璃
        // 不要立即调用 fadeInFolderIconGlasses，避免在动画过程中反复调用
        scheduleFolderIconCheck();
        return;
    }
    if (!sOpenFolderMaterials) sOpenFolderMaterials = [NSHashTable weakObjectsHashTable];
    if (![sOpenFolderMaterials containsObject:mat]) {
        [sOpenFolderMaterials addObject:mat];
        // 延迟隐藏文件夹图标玻璃，等动画完成
        scheduleFolderIconCheck();
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
            // 延迟检查，不要立即调用 fadeInFolderIconGlasses
            scheduleFolderIconCheck();
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
