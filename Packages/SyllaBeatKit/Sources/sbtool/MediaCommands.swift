import Foundation
import SyllaBeatCore
import SyllaBeatMedia
import SyllaBeatModels

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func probe(_ paths: [String]) async throws {
    for path in paths {
        let meta = try await MediaProbe.read(URL(fileURLWithPath: path))
        print(
            "\((path as NSString).lastPathComponent): \(String(format: "%.3f", meta.duration)) s, \(meta.fps) fps, "
                + "\(meta.width)×\(meta.height), \(meta.rotation)°, \(meta.codec ?? "?"), TC \(meta.startTimecode ?? "–"), "
                + "VFR \(meta.isVFR.map { "\($0)" } ?? "?"), Ton \(meta.hasAudio == true ? "ja" : "nein")")
    }
}

/// Vergleicht Metadaten und Schnitte mit `clips.truth.json` aus dem Testmaterial-Generator.
func checkTruth(_ folder: String) async throws {
    let base = URL(fileURLWithPath: folder)
    let truth = try JSONSerialization.jsonObject(
        with: Data(contentsOf: base.appendingPathComponent("clips.truth.json")))
    let clips = (truth as? [String: Any])?["clips"] as? [[String: Any]] ?? []
    var failures = 0
    for entry in clips {
        let name = entry["name"] as! String
        let url = base.appendingPathComponent(name)
        let meta = try await MediaProbe.read(url)
        let start = now()
        let scan = try await SceneDetector.scan(url)
        let seconds = now() - start
        let expected = entry["cuts"] as! [Double]
        let frame = 1 / meta.fps.doubleValue
        let cutsOK =
            scan.cuts.count == expected.count
            && zip(scan.cuts, expected).allSatisfy { abs($0 - $1) <= frame * 1.01 }
        let vfr = entry["vfr"] as! Bool
        let rate = Rational(Int64(entry["fps_num"] as! Int), Int64(entry["fps_den"] as! Int))
        let metaOK =
            (vfr || meta.fps == rate) && meta.rotation == entry["rotation"] as! Int && (meta.isVFR ?? false) == vfr
            && (entry["start_tc_frames"] is NSNull || meta.startTimecode != nil)
        if !(cutsOK && metaOK) { failures += 1 }
        print(
            "\(cutsOK && metaOK ? "✅" : "❌") \(name): Schnitte \(scan.cuts.map { String(format: "%.3f", $0) }) "
                + "erwartet \(expected.map { String(format: "%.3f", $0) }) · \(meta.fps) fps · \(meta.rotation)° · "
                + "TC \(meta.startTimecode ?? "–") · \(String(format: "%.2f s, %.0f× Echtzeit", seconds, meta.duration / seconds))"
        )
    }
    if failures > 0 { throw ToolError(description: "\(failures) Clips weichen ab.") }
    print("Alle \(clips.count) Clips stimmen.")
}

/// Importiert einen Ordner vollständig (wie die App) und misst die Zeit.
func importFolder(_ folder: String, output: String?, parallel: Int) async throws {
    let files = FileScanner.videos(in: [URL(fileURLWithPath: folder)])
    let analyzer = ClipAnalyzer()
    let start = now()
    var clips: [Clip] = []
    var material = 0.0
    try await withThrowingTaskGroup(of: Clip.self) { group in
        var iterator = files.makeIterator()
        func next() {
            guard let url = iterator.next() else { return }
            group.addTask {
                let probed = try await analyzer.probe(url)
                return try await analyzer.analyze(probed)
            }
        }
        for _ in 0..<parallel { next() }
        while let clip = try await group.next() {
            clips.append(clip)
            material += clip.meta.duration
            next()
        }
    }
    clips.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let seconds = now() - start
    let scenes = clips.reduce(0) { $0 + $1.scenes.count }
    print(
        String(
            format: "%d Clips, %d Szenen, %.0f s Material in %.1f s (%.1f× Echtzeit, %d parallel)", clips.count, scenes,
            material, seconds, material / seconds, parallel))
    if let output {
        var project = Project(name: URL(fileURLWithPath: folder).lastPathComponent, clips: clips)
        project.legacy = nil
        try ProjectFile.encode(project).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Projekt gesichert: \(output)")
    }
}

func installModel(source: String?) async throws {
    let package = ModelCatalog.siglip2
    try await package.install(from: source.map { URL(fileURLWithPath: $0) }) { fraction in
        FileHandle.standardError.write(Data(String(format: "\r%3.0f %%", fraction * 100).utf8))
    }
    print("\n\(package.title) installiert: \(package.folder.path)")
}

/// Berechnet fehlende Embeddings aller Szenen eines Projekts (aus den Vorschaubildern im Zwischenspeicher).
func embedProject(_ path: String) async throws {
    let project = try load(path).project
    let embedder = try await SiglipEmbedder()
    let cache = MediaCache()
    let start = now()
    var count = 0
    for clip in project.clips {
        guard let fingerprint = clip.media.fingerprint else { continue }
        let url = cache.embeddings(fingerprint: fingerprint, model: embedder.package.id)
        var file =
            EmbeddingFile.read(url) ?? EmbeddingFile(model: embedder.package.id, dimension: embedder.package.dimension)
        for scene in clip.scenes where file.vectors[MediaCache.key(forSceneStart: scene.start)] == nil {
            let thumbnail = cache.thumbnail(fingerprint: fingerprint, sceneStart: scene.start)
            guard FileManager.default.fileExists(atPath: thumbnail.path) else { continue }
            file.vectors[MediaCache.key(forSceneStart: scene.start)] = try embedder.embed(imageAt: thumbnail)
            count += 1
        }
        try file.write(to: url)
    }
    let seconds = now() - start
    print(
        String(
            format: "%d Szenen eingebettet in %.1f s (%.0f ms je Szene)", count, seconds,
            seconds / Double(max(count, 1)) * 1000))
}

func search(_ path: String, query: String) async throws {
    let project = try load(path).project
    let embedder = try await SiglipEmbedder()
    let index = SceneIndex(project: project, model: embedder.package.id)
    let results = index.rank(query: try embedder.embed(text: query))
    print("„\(query)“:")
    for (rank, hit) in results.prefix(5).enumerated() {
        let clip = project.clip(withID: hit.clipID)!
        print(String(format: "  %d. %@  %.3f  (Szene ab %.1f s)", rank + 1, clip.name, hit.score, hit.sceneStart))
    }
}
