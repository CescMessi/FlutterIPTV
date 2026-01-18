import '../platform/platform_detector.dart';

/// 卡片尺寸计算工具类
/// 根据可用宽度动态计算卡片数量和尺寸，适配所有平台
class CardSizeCalculator {
  /// 卡片间距
  static double get spacing => PlatformDetector.isMobile ? 6.0 : 7.0;
  
  /// 卡片宽高比（宽:高）- 统一比例，无论有没有EPG
  /// 值越大卡片越扁，值越小卡片越高
  /// 调整为适中比例，确保EPG可见
  // static double get aspectRatio => PlatformDetector.isMobile ? 0.85 : 1;
  static double aspectRatio() {
    if (PlatformDetector.isMobile) {
      return 0.85;
    } else if (PlatformDetector.isTV) {
      return 0.9;
    } else {
      return 1;
    }
  }

  
  /// 计算每行卡片数量（用于频道页Grid）
  static int calculateCardsPerRow(double availableWidth) {
    if (PlatformDetector.isMobile) {
      // 手机端：适中卡片数量
      if (availableWidth > 450) return 6;
      if (availableWidth > 350) return 5;
      if (availableWidth > 250) return 4;
      return 3;
    } else if (PlatformDetector.isTV) {
      // TV端频道页：适中卡片数量，确保EPG可读
      // if (availableWidth > 1400) return 9;
      // if (availableWidth > 1200) return 8;
      // if (availableWidth > 1000) return 7;
      // if (availableWidth > 800) return 6;
      if (availableWidth > 1800) return 11;
      if (availableWidth > 1600) return 12;
      if (availableWidth > 1400) return 9;
      if (availableWidth > 1200) return 9;
      if (availableWidth > 1000) return 8;
      if (availableWidth > 800) return 8;
      if (availableWidth > 780) return 7;
      if (availableWidth > 750) return 7;
      if (availableWidth > 700) return 6;
      if (availableWidth > 600) return 6;
      return 5;
    } else {
      // Windows/Desktop端：适中卡片数量
      if (availableWidth > 1800) return 13;
      if (availableWidth > 1600) return 12;
      if (availableWidth > 1400) return 11;
      if (availableWidth > 1200) return 10;
      if (availableWidth > 1000) return 9;
      if (availableWidth > 800) return 7;
      if (availableWidth > 780) return 6;
      if (availableWidth > 750) return 5;
      if (availableWidth > 725) return 5;
      if (availableWidth > 700) return 5;
      if (availableWidth > 600) return 4;
      return 3;
    }
  }
  
  /// 计算首页每行卡片数量（首页需要更多更小的卡片）
  static int calculateHomeCardsPerRow(double availableWidth) {
    if (PlatformDetector.isMobile) {
      if (availableWidth > 450) return 5;
      if (availableWidth > 350) return 4;
      if (availableWidth > 250) return 4;
      return 3;
    } else if (PlatformDetector.isTV) {
      // TV端首页：全宽约1800px，适中卡片数量
      // if (availableWidth > 1600) return 9;
      // if (availableWidth > 1400) return 8;
      // if (availableWidth > 1200) return 7;
      // if (availableWidth > 1000) return 6;
      if (availableWidth > 1800) return 13;
      if (availableWidth > 1600) return 12;
      if (availableWidth > 1400) return 11;
      if (availableWidth > 1200) return 10;
      if (availableWidth > 1000) return 9;
      if (availableWidth > 800) return 7;
      if (availableWidth > 780) return 6;
      if (availableWidth > 750) return 6;
      if (availableWidth > 700) return 6;
      if (availableWidth > 600) return 5;
      return 5;
    } else {
      // Windows首页
      if (availableWidth > 1800) return 13;
      if (availableWidth > 1600) return 12;
      if (availableWidth > 1400) return 11;
      if (availableWidth > 1200) return 10;
      if (availableWidth > 1000) return 9;
      if (availableWidth > 800) return 7;
      if (availableWidth > 780) return 6;
      if (availableWidth > 750) return 5;
      if (availableWidth > 700) return 5;
      if (availableWidth > 600) return 4;
      return 5;
    }
  }
  
  /// 计算卡片宽度
  static double calculateCardWidth(double availableWidth) {
    final cardsPerRow = calculateCardsPerRow(availableWidth);
    final totalSpacing = (cardsPerRow + 1) * spacing;
    return (availableWidth - totalSpacing) / cardsPerRow;
  }
  
  /// 计算卡片高度
  static double calculateCardHeight(double availableWidth) {
    return calculateCardWidth(availableWidth) / aspectRatio();
  }
  
  /// 获取GridView的crossAxisCount
  static int getGridCrossAxisCount(double availableWidth) {
    return calculateCardsPerRow(availableWidth);
  }
  
  /// 获取GridView的childAspectRatio
  static double getGridChildAspectRatio() {
    return aspectRatio();
  }
  
  /// 获取GridView的crossAxisSpacing
  static double getGridCrossAxisSpacing() {
    return spacing;
  }
  
  /// 获取GridView的mainAxisSpacing
  static double getGridMainAxisSpacing() {
    return spacing;
  }
}
