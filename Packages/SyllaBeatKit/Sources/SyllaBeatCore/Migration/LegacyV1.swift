import Foundation

/// Projektformat von SyllaBeat 0.2.0 (`"version": 1`), nur zum Lesen.
/// Felder, die 0.2.0 optional geschrieben hat, sind hier optional.
enum LegacyV1 {
    struct Project: Decodable {
        var version: Int
        var name: String?
        var videoDir: String?
        var audioPath: String?
        var lyrics: String?
        var timeline: Timeline?
        var clips: [Clip]?
        var audio: Audio?
        var plan: Plan?
        var cutStyle: CutStyle?
        var planDraft: String?

        enum CodingKeys: String, CodingKey {
            case version, name, lyrics, timeline, clips, audio, plan
            case videoDir = "video_dir"
            case audioPath = "audio_path"
            case cutStyle = "cut_style"
            case planDraft = "plan_draft"
        }
    }

    struct Timeline: Decodable {
        var fpsNum: Int
        var fpsDen: Int
        var width: Int
        var height: Int

        enum CodingKeys: String, CodingKey {
            case width, height
            case fpsNum = "fps_num"
            case fpsDen = "fps_den"
        }
    }

    struct Clip: Decodable {
        var id: String
        var path: String
        var name: String
        var duration: Double
        var fpsNum: Int
        var fpsDen: Int
        var width: Int
        var height: Int
        var rotation: Double?
        var frameCount: Int64?
        var sizeBytes: Int64?
        var codec: String?
        var fingerprint: String?
        var isVFR: Bool?
        var metadataWarnings: [String]?
        var description: String?
        var tags: [String]?
        var originalName: String?
        var suggestedFilename: String?
        var visionModel: String?
        var vision: Vision?
        var segments: [Segment]?

        enum CodingKeys: String, CodingKey {
            case id, path, name, duration, width, height, rotation, codec, fingerprint, description, tags, vision
            case segments
            case fpsNum = "fps_num"
            case fpsDen = "fps_den"
            case frameCount = "frame_count"
            case sizeBytes = "size_bytes"
            case isVFR = "is_vfr"
            case metadataWarnings = "metadata_warnings"
            case originalName = "original_name"
            case suggestedFilename = "suggested_filename"
            case visionModel = "vision_model"
        }
    }

    struct Vision: Decodable {
        var description: String?
        var action: String?
        var motif: String?
        var mood: String?
        var filenameSuggestion: String?
        var tags: [String]?

        enum CodingKeys: String, CodingKey {
            case description, action, motif, mood, tags
            case filenameSuggestion = "filename_suggestion"
        }
    }

    struct Segment: Decodable {
        var start: Double
        var end: Double
        var description: String?
    }

    struct Audio: Decodable {
        var duration: Double?
        var beats: [Double]?
        var lines: [Line]?
        var sections: [Section]?
        var words: [Word]?
        var sampleRate: Int?
        var channels: Int?
        var tempo: Double?
        var language: String?
        var whisperModel: String?
        var warnings: [String]?

        enum CodingKeys: String, CodingKey {
            case duration, beats, lines, sections, words, channels, tempo, language, warnings
            case sampleRate = "sample_rate"
            case whisperModel = "whisper_model"
        }
    }

    struct Line: Decodable {
        var id: String?
        var text: String?
        var start: Double
        var end: Double
        var confidence: Double?
        var needsReview: Bool?

        enum CodingKeys: String, CodingKey {
            case id, text, start, end, confidence
            case needsReview = "needs_review"
        }
    }

    struct Word: Decodable {
        var word: String?
        var start: Double
        var end: Double
        var probability: Double?
        var estimated: Bool?
    }

    struct Section: Decodable {
        var id: String
        var label: String?
        var start: Double
        var end: Double
        var repeatOf: String?
        var needsReview: Bool?

        enum CodingKeys: String, CodingKey {
            case id, label, start, end
            case repeatOf = "repeat_of"
            case needsReview = "needs_review"
        }
    }

    struct CutStyle: Decodable {
        var variation: String?
        var verseBeats: Int?
        var chorusBeats: Int?
        var chorusFaster: Bool?
        var seed: Int?

        enum CodingKeys: String, CodingKey {
            case variation, seed
            case verseBeats = "verse_beats"
            case chorusBeats = "chorus_beats"
            case chorusFaster = "chorus_faster"
        }
    }

    struct Plan: Decodable {
        var version: Int
        var shots: [Shot]
    }

    struct Shot: Decodable {
        var clipID: String
        var startBeat: Int
        var endBeat: Int
        var sourceIn: Double

        enum CodingKeys: String, CodingKey {
            case clipID = "clip_id"
            case startBeat = "start_beat"
            case endBeat = "end_beat"
            case sourceIn = "source_in"
        }
    }
}
