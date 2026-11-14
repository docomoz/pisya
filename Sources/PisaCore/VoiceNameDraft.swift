import Foundation

func voiceNameForSelection(currentSpeaker: String?, currentName: String, segment: TranscriptSegment) -> String {
    currentSpeaker == segment.speaker ? currentName : segment.speaker
}

func voiceNameSuggestions(query: String, meetingNames: [String], savedNames: [String]) -> [String] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func words(in text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
    }
    let prefixes = words(in: query)
    guard !prefixes.isEmpty else { return [] }
    var seen = Set<String>()
    return (savedNames + meetingNames).compactMap { rawName in
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != TranscriptSegment.unidentifiedSpeaker,
              seen.insert(name.lowercased()).inserted, name != query else { return nil }
        let nameWords = words(in: name)
        guard prefixes.allSatisfy({ prefix in nameWords.contains { $0.hasPrefix(prefix) } }) else { return nil }
        return name
    }
}
