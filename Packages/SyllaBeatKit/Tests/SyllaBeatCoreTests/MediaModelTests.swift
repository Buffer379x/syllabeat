import Foundation
import Testing

@testable import SyllaBeatCore

@MainActor
private final class Editor: ProjectEditing {
    var project: Project
    init(_ project: Project) { self.project = project }
}

private func clip(_ id: String, scenes: [ClipScene] = [], description: String = "") -> Clip {
    Clip(
        id: id, media: MediaRef(path: "/tmp/\(id).mov", fingerprint: "1:\(id)"),
        meta: ClipMetadata(duration: 10, fps: Rational(25), width: 1920, height: 1080), scenes: scenes,
        description: description)
}

@MainActor
@Suite struct MediaCommandTests {
    @Test func addClipsSkipsDuplicatesAndUndoes() throws {
        let editor = Editor(Project(clips: [clip("a")]))
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        try editor.perform(AddClips(clips: [clip("a"), clip("b"), clip("b")]), undoManager: manager)
        manager.endUndoGrouping()
        #expect(editor.project.clips.map(\.id) == ["a", "b"])
        #expect(manager.undoActionName == "3 Clips hinzufügen")
        manager.undo()
        #expect(editor.project.clips.map(\.id) == ["a"])
    }

    @Test func clipsInTheCutCannotBeRemoved() throws {
        var project = Project(clips: [clip("a"), clip("b")])
        project.cut = Cut(
            id: "x", name: "x", seed: 1, origin: .manual,
            shots: [
                Shot(
                    id: "s1", start: CutPoint(time: 0, anchor: .songStart), end: CutPoint(time: 1, anchor: .songEnd),
                    clipID: "a", sourceIn: .zero)
            ])
        let editor = Editor(project)
        #expect(throws: EditError.self) { try editor.perform(RemoveClips(clipIDs: ["a"]), undoManager: nil) }
        try editor.perform(RemoveClips(clipIDs: ["b"]), undoManager: nil)
        #expect(editor.project.clips.map(\.id) == ["a"])
        #expect(editor.project.usageCount(of: "a") == 1)
    }

    @Test func newSongDropsAnalysisAndCut() throws {
        var project = Project(song: MediaRef(path: "/alt.wav", fingerprint: "1:alt"))
        project.analysis = SongAnalysis(duration: 3)
        let editor = Editor(project)
        try editor.perform(SetSong(song: MediaRef(path: "/alt.wav", fingerprint: "1:alt")), undoManager: nil)
        #expect(editor.project.analysis != nil)
        try editor.perform(SetSong(song: MediaRef(path: "/neu.wav", fingerprint: "1:neu")), undoManager: nil)
        #expect(editor.project.analysis == nil && editor.project.song?.path == "/neu.wav")
    }

    @Test func clipDetails() throws {
        let editor = Editor(Project(clips: [clip("a")]))
        try editor.perform(SetClipDescription(clipID: "a", description: "  Wellen am Strand \n"), undoManager: nil)
        try editor.perform(SetClipTags(clipID: "a", tags: [" Meer", "meer", "", "Strand "]), undoManager: nil)
        try editor.perform(SetClipRating(clipID: "a", rating: 4), undoManager: nil)
        let result = try #require(editor.project.clip(withID: "a"))
        #expect(result.description == "Wellen am Strand")
        #expect(result.tags == ["Meer", "Strand"])
        #expect(result.rating == 4)
        #expect(throws: EditError.self) { try editor.perform(SetClipRating(clipID: "a", rating: 6), undoManager: nil) }
    }
}

@Suite struct AnalysisMergeTests {
    @Test func keepsUserInputAndMatchingSceneDescriptions() {
        var old = clip(
            "a", scenes: [ClipScene(id: "a-s1", start: 0, end: 4, description: "Welle")], description: "eigene")
        old.tags = ["Meer"]
        old.rating = 5
        old.excluded = true
        let fresh = clip(
            "a",
            scenes: [
                ClipScene(id: "a-s1", start: 0.04, end: 4.04, features: SceneFeatures(faceCount: 1)),
                ClipScene(id: "a-s2", start: 4.04, end: 10),
            ])
        let merged = old.mergingAnalysis(fresh)
        #expect(merged.description == "eigene" && merged.tags == ["Meer"] && merged.rating == 5 && merged.excluded)
        #expect(merged.scenes.count == 2)
        #expect(merged.scenes[0].description == "Welle" && merged.scenes[0].features?.faceCount == 1)
        #expect(merged.scenes[1].description.isEmpty)
    }

    @Test func shotSizeFromFaceArea() {
        #expect(ShotSize(largestFaceArea: 0.2) == .closeUp)
        #expect(ShotSize(largestFaceArea: 0.03) == .medium)
        #expect(ShotSize(largestFaceArea: 0) == .wide)
    }
}

@Suite struct SceneIndexTests {
    @Test func ranksClipsByBestScene() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)")
        let cache = MediaCache(root: root)
        let project = Project(clips: [
            clip("a", scenes: [ClipScene(id: "a1", start: 0, end: 5), ClipScene(id: "a2", start: 5, end: 10)]),
            clip("b", scenes: [ClipScene(id: "b1", start: 0, end: 10)]),
            clip("c", scenes: [ClipScene(id: "c1", start: 0, end: 10)]),
        ])
        for (id, vectors) in [("a", ["0": [Float(1), 0], "5000": [0, 1]]), ("b", ["0": [0.7, 0.7]])] {
            _ = try cache.prepare(fingerprint: "1:\(id)")
            try EmbeddingFile(model: "m", dimension: 2, vectors: vectors)
                .write(to: cache.embeddings(fingerprint: "1:\(id)", model: "m"))
        }
        let index = SceneIndex(project: project, model: "m", cache: cache)
        #expect(index.count == 3)
        let hits = index.rank(query: [0, 1])
        #expect(hits.map(\.clipID) == ["a", "b"])
        #expect(hits[0].sceneStart == 5)
        #expect(SceneIndex.missing(in: project, model: "m", cache: cache) == ["c"])
    }
}

@Suite struct InstallTests {
    private func zip(_ folder: URL, name: String, content: String) throws -> URL {
        let source = folder.appendingPathComponent("quelle-\(name)")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent(name), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: source.appendingPathComponent("\(name)/inhalt.txt"))
        let archive = folder.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.appendingPathComponent(name).path, archive.path]
        try process.run()
        process.waitUntilExit()
        return archive
    }

    @Test func installsFromLocalSourceAndRejectsWrongChecksum() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)")
        setenv("SYLLABEAT_HOME", home.path, 1)
        defer { unsetenv("SYLLABEAT_HOME") }
        let source = home.appendingPathComponent("quelle")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let archive = try zip(source, name: "Encoder", content: "gewichte")
        let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as! Int64
        var package = ModelPackage(
            id: "test", task: .embedding, title: "Test", license: "MIT", revision: "abcdef1234567890",
            archives: [
                DownloadItem(
                    url: URL(string: "https://example.invalid/Encoder.zip")!,
                    sha256: try Downloader.sha256(of: archive), bytes: size)
            ],
            dimension: 2)
        #expect(!package.isInstalled)
        try await package.install(from: source)
        #expect(package.isInstalled)
        #expect(
            FileManager.default.fileExists(atPath: package.folder.appendingPathComponent("Encoder/inhalt.txt").path))
        try package.uninstall()
        #expect(!package.isInstalled)

        package.archives[0].sha256 = String(repeating: "0", count: 64)
        await #expect(throws: DownloadError.checksumMismatch("Encoder.zip")) { try await package.install(from: source) }
        #expect(!package.isInstalled)
    }
}
