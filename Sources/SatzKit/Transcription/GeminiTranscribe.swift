import Foundation

/// Google's Gemini API as a dictation provider: `gemini-3.5-transcribe`,
/// asked at `POST /v1beta/interactions` with the audio inline. The one Google
/// route a single pasted key opens: Chirp 3 and Cloud Speech-to-Text v2
/// refuse API keys (a live probe on 10.10.2026 answered 401 "API keys are not
/// supported by this API"). The shapes are the ones Google documents; they
/// are not yet tried against the live service, which is why reading the
/// answer is forgiving.
public enum GeminiTranscribe {

    public static let model = "gemini-3.5-transcribe"

    /// The whole request may be 20 MB, base64 included. Beyond that the
    /// Files API would be needed; a dictation that long fails early instead.
    public static let requestLimit = 20_000_000
    /// The custom vocabulary takes up to 1000 terms.
    public static let vocabularyLimit = 1_000

    /// Whether the request for `wav` would be over the limit. Counted before
    /// anything is encoded: base64 makes four bytes of every three, and the
    /// vocabulary and the JSON around it ride along.
    static func isTooLarge(wav: Data, vocabulary: [String]) -> Bool {
        let audio = (wav.count + 2) / 3 * 4
        let words = vocabulary.prefix(vocabularyLimit).reduce(0) { $0 + $1.utf8.count + 4 }
        return audio + words + 1_024 > requestLimit
    }

    /// The model id as the API wants it: Google's own lists spell it
    /// `models/gemini-…`.
    static func apiModel(_ id: String) -> String {
        let typed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.hasPrefix("models/") ? String(typed.dropFirst("models/".count)) : typed
    }

    static func body(wav: Data, model id: String, vocabulary: [String], removesFillers: Bool) -> [String: Any] {
        // No language: an empty list is auto-detection, which a sentence that
        // switches between German and English needs.
        var config: [String: Any] = ["language_codes": [String]()]
        if !vocabulary.isEmpty { config["custom_vocabulary"] = Array(vocabulary.prefix(vocabularyLimit)) }
        // Smart mode drops fillers and self-corrections; left out, the
        // transcript is verbatim.
        if removesFillers { config["mode"] = "smart" }
        return [
            "model": apiModel(id),
            "input": [["type": "audio", "data": wav.base64EncodedString(), "mime_type": "audio/wav"]],
            "generation_config": ["transcription_config": config],
        ]
    }

    /// The transcript out of whichever shape the endpoint answers in. The
    /// documented one is `steps[].content[]` with `{type: "text", text}`
    /// items; the SDKs' `output_text`, an `outputs[]` list (the interactions
    /// API's earlier name for it) and generateContent's
    /// `candidates[].content.parts[]` are read too. A well-formed answer
    /// with no words in it (silence, a blocked answer) is "", anything else
    /// nil.
    static func text(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var found: [String] = []
        var understood = false

        if let text = object["output_text"] as? String {
            understood = true
            found.append(text)
        }
        if let steps = object["steps"] as? [[String: Any]] {
            understood = true
            for step in steps where (step["type"] as? String).map({ $0 == "model_output" }) ?? true {
                found += textItems(step["content"])
            }
        }
        if let outputs = object["outputs"] as? [[String: Any]] {
            understood = true
            found += textItems(outputs)
        }
        if let candidates = object["candidates"] as? [[String: Any]] {
            understood = true
            for candidate in candidates {
                let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts {
                    if let text = part["audioTranscription"] as? String {
                        found.append(text)
                    } else if let transcription = part["audioTranscription"] as? [String: Any] {
                        found += ["text", "transcript", "transcription"].compactMap { transcription[$0] as? String }.prefix(1)
                    } else if let text = part["text"] as? String {
                        found.append(text)
                    }
                }
                // Only the first candidate is the answer.
                if !found.isEmpty { break }
            }
        }
        guard understood else { return nil }
        return found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The `{type: "text", text}` items of a content list.
    private static func textItems(_ content: Any?) -> [String] {
        (content as? [[String: Any]] ?? []).compactMap { item in
            guard (item["type"] as? String).map({ $0 == "text" || $0 == "output_text" }) ?? true else { return nil }
            return item["text"] as? String
        }
    }
}
