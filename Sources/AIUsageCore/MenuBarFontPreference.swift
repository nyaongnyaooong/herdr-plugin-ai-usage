import Foundation

public enum MenuBarFontID: String, CaseIterable, Equatable, Identifiable, Codable {
    case sfPro
    case sfRounded
    case sfCompact
    case helveticaNeue
    case helvetica
    case lucidaGrande
    case avenir
    case avenirNext
    case avenirNextDemi
    case futura
    case gillSans
    case optima
    case dinAlternate
    case seravek
    case arial
    case arialRounded
    case verdana
    case tahoma
    case trebuchet
    case calibri
    case ptSans
    case appleSDGothicNeo
    case pretendard
    case nanumGothic
    case malgunGothic
    case hiraginoSans
    case hiraginoMaru
    case yuGothic
    case georgia
    case charter
    case baskerville
    case ptSerif
    case iowanOldStyle
    case hoeflerText
    case americanTypewriter
    case rockwell
    case menlo
    case monaco
    case ptMono
    case courierNew
    case meslo
    case galvji

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sfPro: return "SF Pro"
        case .sfRounded: return "SF Rounded"
        case .sfCompact: return "SF Compact"
        case .helveticaNeue: return "Helvetica Neue"
        case .helvetica: return "Helvetica"
        case .lucidaGrande: return "Lucida Grande"
        case .avenir: return "Avenir"
        case .avenirNext: return "Avenir Next"
        case .avenirNextDemi: return "Avenir Next Demi"
        case .futura: return "Futura"
        case .gillSans: return "Gill Sans"
        case .optima: return "Optima"
        case .dinAlternate: return "DIN Alternate"
        case .seravek: return "Seravek"
        case .arial: return "Arial"
        case .arialRounded: return "Arial Rounded"
        case .verdana: return "Verdana"
        case .tahoma: return "Tahoma"
        case .trebuchet: return "Trebuchet MS"
        case .calibri: return "Calibri"
        case .ptSans: return "PT Sans"
        case .appleSDGothicNeo: return "Apple SD Gothic Neo"
        case .pretendard: return "Pretendard"
        case .nanumGothic: return "나눔고딕"
        case .malgunGothic: return "맑은 고딕"
        case .hiraginoSans: return "Hiragino Sans"
        case .hiraginoMaru: return "Hiragino Maru"
        case .yuGothic: return "Yu Gothic"
        case .georgia: return "Georgia"
        case .charter: return "Charter"
        case .baskerville: return "Baskerville"
        case .ptSerif: return "PT Serif"
        case .iowanOldStyle: return "Iowan Old Style"
        case .hoeflerText: return "Hoefler Text"
        case .americanTypewriter: return "American Typewriter"
        case .rockwell: return "Rockwell"
        case .menlo: return "Menlo"
        case .monaco: return "Monaco"
        case .ptMono: return "PT Mono"
        case .courierNew: return "Courier New"
        case .meslo: return "Meslo"
        case .galvji: return "Galvji"
        }
    }
}

public enum MenuBarFontPreference {
    public static let defaultsKey = "menuBarFontID"
    public static let `default`: MenuBarFontID = .sfPro

    public static func load(from defaults: UserDefaults) -> MenuBarFontID {
        guard let raw = defaults.string(forKey: defaultsKey),
              let id = MenuBarFontID(rawValue: raw) else {
            return `default`
        }
        return id
    }

    public static func save(_ id: MenuBarFontID, to defaults: UserDefaults) {
        defaults.set(id.rawValue, forKey: defaultsKey)
    }
}
