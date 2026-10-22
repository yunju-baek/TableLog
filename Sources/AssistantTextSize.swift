import SwiftUI

enum AssistantTextSize {
    static let range = 0...4
    static func clamped(_ step: Int) -> Int { min(range.upperBound, max(range.lowerBound, step)) }
}

private struct AssistantFontStepKey: EnvironmentKey { static let defaultValue = 1 }
extension EnvironmentValues {
    var assistantFontStep: Int {
        get { self[AssistantFontStepKey.self] }
        set { self[AssistantFontStepKey.self] = AssistantTextSize.clamped(newValue) }
    }
}

private struct AssistantFontModifier: ViewModifier {
    @Environment(\.assistantFontStep) private var step
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: size + CGFloat(step * 2), weight: weight, design: design))
    }
}

extension View {
    func assistantFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AssistantFontModifier(size: size, weight: weight, design: design))
    }
}
