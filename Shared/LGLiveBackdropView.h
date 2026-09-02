#pragma once
#import <UIKit/UIKit.h>
#import "LGWallpaperBlurCache.h"

void LGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#ifndef jbroot
#define jbroot(path) (path)
#endif
#endif

id LGGlassPreferenceValue(NSString *key);
void LGInvalidateGlassPreferenceCache(void);
NSString *LGFilterTypeForHostPrefix(NSString *prefix);

/// 背景捕获模式
typedef NS_ENUM(NSInteger, LGBackdropMode) {
    /// 实时模式：使用 CABackdropLayer 实时捕获背景（控制中心、通知、键盘等动态场景）
    LGBackdropModeLive = 0,
    /// 静态壁纸模式：使用预模糊的壁纸缓存，零 GPU 实时开销（Dock、文件夹、小组件、灵动岛等位置固定的表面）
    LGBackdropModeStaticWallpaper = 1,
};

@interface LGLiveBackdropView : UIView

@property (nonatomic, copy) NSString *lgFilterType;
@property (nonatomic, copy) NSNumber *lgSpecularEnabledOverride;

/// 背景模式，默认 LGBackdropModeLive
/// 设置为 LGBackdropModeStaticWallpaper 后，视图不再使用 CABackdropLayer 实时捕获，
/// 而是显示 LGWallpaperBlurCache 中预模糊的壁纸图片。
@property (nonatomic, assign) LGBackdropMode backdropMode;

/// 静态模式下使用的壁纸变体，默认 LGWallpaperVariantHomeScreen
@property (nonatomic, assign) LGWallpaperVariant wallpaperVariant;

/// 静态模式下的模糊半径（点），默认 20
@property (nonatomic, assign) CGFloat staticBlurRadius;

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName;
- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName
                   filterType:(NSString *)filterType;
- (void)applyFilters;

/// 刷新静态壁纸内容（壁纸变化后自动调用，一般不需要手动调）
- (void)refreshStaticWallpaper;

@end

void LGInjectGlassIntoMaterialGroupType(UIView *materialView, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType);
void LGResyncGlassGeometry(UIView *materialView, const void *assocKey);
void LGRemoveGlassFromMaterial(UIView *materialView, const void *assocKey);
BOOL LGMaterialHasGlass(UIView *materialView, const void *assocKey);
