import AppKit
import CoreText
import AIUsageCore

extension MenuBarFontID {
    static var installed: [MenuBarFontID] {
        allCases.filter(\.isInstalled)
    }

    var isInstalled: Bool {
        switch self {
        case .sfPro, .sfRounded, .sfCompact:
            return true
        default:
            return NSFont(name: postScriptName, size: 12) != nil
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        withTabularFigures(baseFont(size: size), size: size)
    }

    private func baseFont(size: CGFloat) -> NSFont {
        switch self {
        case .sfPro:
            return NSFont.systemFont(ofSize: size, weight: .medium)
        case .sfRounded:
            return weightedSystemFont(name: ".AppleSystemUIFontRounded", size: size, weight: .medium)
        case .sfCompact:
            return weightedSystemFont(name: ".AppleSystemUIFontCompact", size: size, weight: .medium)
        default:
            return NSFont(name: postScriptName, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .medium)
        }
    }

    private var postScriptName: String {
        switch self {
        case .sfPro, .sfRounded, .sfCompact:
            return ""
        case .helveticaNeue: return "HelveticaNeue-Medium"
        case .helvetica: return "Helvetica-Bold"
        case .lucidaGrande: return "LucidaGrande-Bold"
        case .avenir: return "Avenir-Medium"
        case .avenirNext: return "AvenirNext-Medium"
        case .avenirNextDemi: return "AvenirNext-DemiBold"
        case .futura: return "Futura-Medium"
        case .gillSans: return "GillSans-SemiBold"
        case .optima: return "Optima-Bold"
        case .dinAlternate: return "DINAlternate-Bold"
        case .seravek: return "Seravek-Medium"
        case .arial: return "Arial-BoldMT"
        case .arialRounded: return "ArialRoundedMTBold"
        case .verdana: return "Verdana-Bold"
        case .tahoma: return "Tahoma-Bold"
        case .trebuchet: return "TrebuchetMS-Bold"
        case .calibri: return "Calibri-Bold"
        case .ptSans: return "PTSans-Bold"
        case .appleSDGothicNeo: return "AppleSDGothicNeo-SemiBold"
        case .pretendard: return "Pretendard-SemiBold"
        case .nanumGothic: return "NanumGothicBold"
        case .malgunGothic: return "MalgunGothicBold"
        case .hiraginoSans: return "HiraginoSans-W6"
        case .hiraginoMaru: return "HiraMaruProN-W4"
        case .yuGothic: return "YuGo-Bold"
        case .georgia: return "Georgia-Bold"
        case .charter: return "Charter-Bold"
        case .baskerville: return "Baskerville-SemiBold"
        case .ptSerif: return "PTSerif-Bold"
        case .iowanOldStyle: return "IowanOldStyle-Bold"
        case .hoeflerText: return "HoeflerText-Black"
        case .americanTypewriter: return "AmericanTypewriter-Semibold"
        case .rockwell: return "Rockwell-Bold"
        case .menlo: return "Menlo-Bold"
        case .monaco: return "Monaco"
        case .ptMono: return "PTMono-Bold"
        case .courierNew: return "CourierNewPS-BoldMT"
        case .meslo: return "MesloLGS-NF-Bold"
        case .galvji: return "Galvji-Bold"
        }
    }
}

private func weightedSystemFont(name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let fallback = NSFont.systemFont(ofSize: size, weight: weight)
    guard let named = NSFont(name: name, size: size) else { return fallback }
    let descriptor = named.fontDescriptor.addingAttributes([
        .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
    ])
    return NSFont(descriptor: descriptor, size: size) ?? named
}

private func withTabularFigures(_ font: NSFont, size: CGFloat) -> NSFont {
    let descriptor = font.fontDescriptor.addingAttributes([
        .featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]
    ])
    return NSFont(descriptor: descriptor, size: size) ?? font
}
