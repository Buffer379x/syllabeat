import Foundation
import Testing

@testable import SyllaBeatCore

@MainActor
private final class Editor: ProjectEditing {
    var project: Project
    init(_ project: Project) { self.project = project }
}

/// 120 BPM, Beats ab 0,5 s, Taktanfang auf Index 0; ein Schnitt auf Beat 3 und Beat 7.
@MainActor
private func songEditor() -> Editor {
    let beats = (0..<40).map { Beat(time: 0.5 + Double($0) * 0.5, isDownbeat: $0 % 4 == 0) }
    var project = Project()
    project.analysis = SongAnalysis(
        duration: 21, tempo: 120, beats: beats,
        words: [Word(id: "w1", text: "Mehr", start: 1, end: 1.4, confidence: 0.3)],
        lines: [LyricLine(id: "l1", text: "Mehr", start: 1, end: 1.4, needsReview: true, wordIDs: ["w1"])],
        sections: [
            SongSection(id: "a", kind: .verse, label: "Strophe", start: 0, end: 8),
            SongSection(id: "b", kind: .chorus, label: "Refrain", start: 8, end: 14),
            SongSection(id: "c", kind: .verse, label: "Strophe", start: 14, end: 21),
        ])
    let clip = Clip(
        id: "k", media: MediaRef(path: "/x.mov"),
        meta: ClipMetadata(duration: 60, fps: Rational(25), width: 1, height: 1))
    project.clips = [clip]
    func shot(_ id: String, _ a: CutPoint, _ b: CutPoint) -> Shot {
        Shot(id: id, start: a, end: b, clipID: "k", sourceIn: .zero)
    }
    project.cut = Cut(
        id: "c", name: "c", seed: 1, origin: .manual,
        shots: [
            shot("1", CutPoint(time: 0, anchor: .songStart), CutPoint(time: 2, anchor: .beat(3))),
            shot("2", CutPoint(time: 2, anchor: .beat(3)), CutPoint(time: 4, anchor: .beat(7))),
            shot("3", CutPoint(time: 4, anchor: .beat(7)), CutPoint(time: 21, anchor: .songEnd)),
        ])
    return Editor(project)
}

@MainActor
@Suite struct SongCommandTests {
    @Test func shiftMovesBeatsAndAnchoredCuts() throws {
        let editor = songEditor()
        try editor.perform(ShiftBeats(milliseconds: 30), undoManager: nil)
        #expect(abs(editor.project.analysis!.beats[0].time - 0.53) < 1e-9)
        #expect(abs(editor.project.cut!.shots[1].start.time - 2.03) < 1e-9)
        #expect(editor.project.cut!.shots[1].start.anchor == .beat(3))
    }

    @Test func doubleAndHalfTempoKeepDownbeatsAndAnchors() throws {
        let editor = songEditor()
        try editor.perform(ScaleTempo(factor: .double), undoManager: nil)
        var analysis = editor.project.analysis!
        #expect(analysis.tempo == 240)
        #expect(analysis.beats.count == 79)
        #expect(analysis.beats[1].time == 0.75)
        #expect(analysis.beats[0].isDownbeat && analysis.beats[4].isDownbeat && !analysis.beats[2].isDownbeat)
        // Beat 3 (2,0 s) ist jetzt Beat 6.
        #expect(editor.project.cut!.shots[1].start == CutPoint(time: 2, anchor: .beat(6)))

        try editor.perform(ScaleTempo(factor: .half), undoManager: nil)
        analysis = editor.project.analysis!
        #expect(analysis.tempo == 120 && analysis.beats.count == 40)
        #expect(editor.project.cut!.shots[1].start == CutPoint(time: 2, anchor: .beat(3)))
    }

    @Test func tripletCorrection() throws {
        let editor = songEditor()
        try editor.perform(ScaleTempo(factor: .threeQuarters), undoManager: nil)
        let beats = editor.project.analysis!.beats
        #expect(editor.project.analysis!.tempo == 90)
        #expect(abs((beats[1].time - beats[0].time) - 2.0 / 3) < 1e-9)
    }

    @Test func downbeatAndMeter() throws {
        let editor = songEditor()
        try editor.perform(SetDownbeat(beatIndex: 2), undoManager: nil)
        #expect(
            editor.project.analysis!.beats.indices.filter { editor.project.analysis!.beats[$0].isDownbeat }.prefix(3)
                == [2, 6, 10])
        try editor.perform(SetMeter(meter: 3), undoManager: nil)
        #expect(
            editor.project.analysis!.beats.indices.filter { editor.project.analysis!.beats[$0].isDownbeat }.prefix(3)
                == [2, 5, 8])
    }

    @Test func deleteAndInsertBeatReanchorCuts() throws {
        let editor = songEditor()
        try editor.perform(DeleteBeat(beatIndex: 1), undoManager: nil)
        #expect(editor.project.cut!.shots[1].start == CutPoint(time: 2, anchor: .beat(2)))
        try editor.perform(InsertBeat(time: 0.75), undoManager: nil)
        #expect(editor.project.cut!.shots[1].start == CutPoint(time: 2, anchor: .beat(3)))
        #expect(throws: EditError.self) { try editor.perform(InsertBeat(time: 0.76), undoManager: nil) }
    }

    @Test func sectionEditing() throws {
        let editor = songEditor()
        try editor.perform(SetSectionRepeat(sectionID: "c", repeatOf: "a"), undoManager: nil)
        #expect(editor.project.analysis!.sections[2].repeatOf == "a")
        #expect(throws: EditError.self) {
            try editor.perform(SetSectionRepeat(sectionID: "a", repeatOf: "c"), undoManager: nil)
        }
        try editor.perform(MoveSectionBoundary(sectionID: "b", time: 9), undoManager: nil)
        #expect(editor.project.analysis!.sections[0].end == 9 && editor.project.analysis!.sections[1].start == 9)
        try editor.perform(SplitSection(time: 11), undoManager: nil)
        #expect(editor.project.analysis!.sections.count == 4)
        #expect(throws: EditError.self) {
            try editor.perform(MergeSectionWithPrevious(sectionID: "a"), undoManager: nil)
        }
    }

    @Test func mergeRemovesDanglingRepeats() throws {
        let editor = songEditor()
        try editor.perform(SetSectionRepeat(sectionID: "c", repeatOf: "b"), undoManager: nil)
        try editor.perform(MergeSectionWithPrevious(sectionID: "b"), undoManager: nil)
        let sections = editor.project.analysis!.sections
        #expect(sections.map(\.id) == ["a", "c"])
        #expect(sections[0].end == 14 && sections[1].repeatOf == nil)
    }

    @Test func wordCorrectionUpdatesLine() throws {
        let editor = songEditor()
        try editor.perform(EditWord(wordID: "w1", text: "Meer"), undoManager: nil)
        let analysis = editor.project.analysis!
        #expect(analysis.words[0].text == "Meer" && !analysis.words[0].isUncertain)
        #expect(analysis.lines[0].text == "Meer" && !analysis.lines[0].needsReview)
    }
}
