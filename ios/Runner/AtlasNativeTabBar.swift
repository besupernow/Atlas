import Flutter
import UIKit

/// Atlas: the app's bottom bar on iPhone and iPad as a real UIKit `UITabBar` (Liquid Glass on
/// iOS 26), shown inside Flutter as a platform view. Dart sends the tabs, the selection and the
/// theme's colors; the bar sends taps, long presses and its height back.
///
/// Channel per view: `atlas/native_tab_bar_<id>`.
///   Dart -> iOS  `update` {items: [{title, symbol}], selected, showLabels, tint, unselectedTint,
///                          background, dark}
///   iOS -> Dart  `select` index, `longPress` index, `height` points (bar only, no home indicator)
final class AtlasNativeTabBarFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "atlas/native_tab_bar"

  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(AtlasNativeTabBarFactory(messenger: registrar.messenger()), withId: viewType)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AtlasNativeTabBarView(frame: frame, viewId: viewId, messenger: messenger, arguments: args as? [String: Any] ?? [:])
  }
}

private final class AtlasTabBarContainer: UIView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    onLayout?()
  }
}

final class AtlasNativeTabBarView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: AtlasTabBarContainer
  private let tabBar = UITabBar()
  private let channel: FlutterMethodChannel
  private var itemKeys: [String] = []
  private var lastReportedHeight: CGFloat = 0

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, arguments: [String: Any]) {
    container = AtlasTabBarContainer(frame: frame)
    channel = FlutterMethodChannel(name: "atlas/native_tab_bar_\(viewId)", binaryMessenger: messenger)
    super.init()

    container.backgroundColor = .clear
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    container.addSubview(tabBar)
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      tabBar.topAnchor.constraint(equalTo: container.topAnchor),
      tabBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
    press.cancelsTouchesInView = false
    tabBar.addGestureRecognizer(press)

    container.onLayout = { [weak self] in self?.reportHeight() }
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "update", let arguments = call.arguments as? [String: Any] {
        self?.apply(arguments)
      }
      result(nil)
    }
    apply(arguments)
  }

  func view() -> UIView { container }

  // MARK: - From Dart

  private func apply(_ arguments: [String: Any]) {
    let showLabels = arguments["showLabels"] as? Bool ?? true
    if let items = arguments["items"] as? [[String: Any]] {
      let keys = items.map { "\($0["title"] as? String ?? "")|\($0["symbol"] as? String ?? "")|\(showLabels)" }
      if keys != itemKeys {
        itemKeys = keys
        let barItems = items.enumerated().map { index, item -> UITabBarItem in
          let symbol = item["symbol"] as? String ?? "circle"
          let image = UIImage(systemName: symbol) ?? UIImage(systemName: "circle")
          let barItem = UITabBarItem(title: showLabels ? item["title"] as? String : nil, image: image, tag: index)
          barItem.accessibilityLabel = item["title"] as? String
          return barItem
        }
        tabBar.setItems(barItems, animated: false)
      }
    }
    if let selected = arguments["selected"] as? Int, let items = tabBar.items, items.indices.contains(selected) {
      if tabBar.selectedItem !== items[selected] { tabBar.selectedItem = items[selected] }
    }

    if let dark = arguments["dark"] as? Bool {
      tabBar.overrideUserInterfaceStyle = dark ? .dark : .light
    }
    let tint = color(arguments["tint"])
    let unselected = color(arguments["unselectedTint"])
    if let tint { tabBar.tintColor = tint }
    if let unselected { tabBar.unselectedItemTintColor = unselected }

    if #available(iOS 26, *) {
      // Liquid Glass: leave the system background alone so the bar keeps the glass material;
      // the theme comes through the tint and light/dark style.
    } else {
      let appearance = UITabBarAppearance()
      appearance.configureWithDefaultBackground()
      if let background = color(arguments["background"]) {
        appearance.backgroundColor = background.withAlphaComponent(0.92)
      }
      for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
        if let tint {
          layout.selected.iconColor = tint
          layout.selected.titleTextAttributes = [.foregroundColor: tint]
        }
        if let unselected {
          layout.normal.iconColor = unselected
          layout.normal.titleTextAttributes = [.foregroundColor: unselected]
        }
      }
      tabBar.standardAppearance = appearance
      tabBar.scrollEdgeAppearance = appearance
    }
    container.setNeedsLayout()
  }

  private func color(_ value: Any?) -> UIColor? {
    guard let number = value as? NSNumber else { return nil }
    let argb = number.uint32Value
    return UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }

  // MARK: - To Dart

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("select", arguments: item.tag)
  }

  @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began, let count = tabBar.items?.count, count > 0 else { return }
    let point = recognizer.location(in: tabBar)
    channel.invokeMethod("longPress", arguments: itemIndex(at: point, count: count))
  }

  /// The tab under [point]: the bar's item buttons in left-to-right order when they can be found
  /// (their layout differs between iOS versions), otherwise an equal share of the width.
  private func itemIndex(at point: CGPoint, count: Int) -> Int {
    var buttons: [UIView] = []
    func collect(_ view: UIView) {
      for subview in view.subviews {
        if subview is UIControl, subview.bounds.width > 20, subview.bounds.width < tabBar.bounds.width * 0.8 {
          buttons.append(subview)
        } else {
          collect(subview)
        }
      }
    }
    collect(tabBar)
    if buttons.count == count {
      let ordered = buttons.sorted { $0.convert($0.bounds, to: tabBar).minX < $1.convert($1.bounds, to: tabBar).minX }
      if let hit = ordered.firstIndex(where: { $0.convert($0.bounds, to: tabBar).insetBy(dx: -4, dy: -12).contains(point) }) {
        return tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? count - 1 - hit : hit
      }
    }
    let share = max(tabBar.bounds.width / CGFloat(count), 1)
    let index = min(count - 1, max(0, Int(point.x / share)))
    return tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? count - 1 - index : index
  }

  /// The bar's own height, without the home indicator area (Dart adds its own bottom padding).
  private func reportHeight() {
    let width = max(container.bounds.width, 1)
    let fitted = tabBar.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let height = max(44, fitted - tabBar.safeAreaInsets.bottom)
    guard abs(height - lastReportedHeight) >= 0.5 else { return }
    lastReportedHeight = height
    channel.invokeMethod("height", arguments: Double(height))
  }
}
