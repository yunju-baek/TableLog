#if TABLELOG_VERIFICATION
extension VoiceIdentity {
    func loadNameSuggestionsFixture() {
        vault.continuousLearningEnabled = false
        suggestions = [
            1: VoiceSuggestion(profileID: UUID(), name: "김하늘", similarity: 0.82, margin: 0.12,
                               evidenceCount: 2, evidenceSeconds: 8),
            2: VoiceSuggestion(profileID: UUID(), name: "이서준", similarity: 0.91, margin: 0.18,
                               evidenceCount: 3, evidenceSeconds: 12, automaticEligible: true)
        ]
        didChange?()
    }
}
#endif
