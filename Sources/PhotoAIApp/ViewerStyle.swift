import SwiftUI

/// 单张、比较、放大共用的观看样式：“显示 → 背景 / 照片边框 / 四周留白”（计划 V-1）。
/// 背景不跟系统深浅色走：看照片要的是稳定的中性底色。记在本机设置里。
struct ViewerStyle: Equatable {
    enum Background: String, CaseIterable, Identifiable {
        case darkGray, black, midGray, white

        var id: Self { self }

        var title: String {
            switch self {
            case .darkGray: "深灰"
            case .black: "黑"
            case .midGray: "中灰"
            case .white: "白"
            }
        }

        /// 中灰约是 18% 灰卡在 sRGB 下的亮度。
        var color: Color {
            switch self {
            case .darkGray: Color(white: 0.16)
            case .black: .black
            case .midGray: Color(white: 0.47)
            case .white: Color(white: 0.96)
            }
        }

        /// 背景上的文字、信息条材质用深色还是浅色外观。
        var colorScheme: ColorScheme { self == .white ? .light : .dark }

        /// 照片细边框的颜色：深底上是浅线，白底上是深线。
        var borderColor: Color { self == .white ? .black.opacity(0.18) : .white.opacity(0.16) }
    }

    enum Margin: String, CaseIterable, Identifiable {
        case narrow, wide

        var id: Self { self }
        var title: String { self == .narrow ? "窄" : "宽" }
        /// 单张视图里照片四周的留白（pt）。
        var points: CGFloat { self == .narrow ? 16 : 48 }
    }

    var background = Background.darkGray
    /// 照片四周的细边框和投影。
    var framed = true
    var margin = Margin.narrow

    static func load(_ defaults: UserDefaults = .standard) -> ViewerStyle {
        var style = ViewerStyle()
        if let raw = defaults.string(forKey: "viewer.background"), let value = Background(rawValue: raw) { style.background = value }
        if defaults.object(forKey: "viewer.framed") != nil { style.framed = defaults.bool(forKey: "viewer.framed") }
        if let raw = defaults.string(forKey: "viewer.margin"), let value = Margin(rawValue: raw) { style.margin = value }
        return style
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(background.rawValue, forKey: "viewer.background")
        defaults.set(framed, forKey: "viewer.framed")
        defaults.set(margin.rawValue, forKey: "viewer.margin")
    }
}

extension View {
    /// 给照片加细边框和投影。投影画在照片下面的一个矩形上，不对整张图算阴影（翻页时便宜）。
    func viewerFrame(_ style: ViewerStyle) -> some View {
        self
            .overlay {
                if style.framed { Rectangle().strokeBorder(style.background.borderColor, lineWidth: 1) }
            }
            .background {
                if style.framed {
                    Rectangle().fill(.black).shadow(color: .black.opacity(style.background == .white ? 0.25 : 0.55), radius: 12, y: 4)
                }
            }
    }
}
