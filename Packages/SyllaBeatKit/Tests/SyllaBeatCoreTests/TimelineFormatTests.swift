import Foundation
import Testing

@testable import SyllaBeatCore

@MainActor
final class EditingOwner: ProjectEditing {
    var project: Project
    init(_ project: Project) { self.project = project }
}

@Suite struct TimelineFormatTests {
    @Test func suggestionFollowsMajorityRate() {
        let clips =
            (0..<28).map { StoryFixtures.clip("a\($0).mp4", seconds: 15, fps: Rational(30)) }
            + (0..<12).map { StoryFixtures.clip("b\($0).mp4", seconds: 8, fps: Rational(24)) }
        let suggested = TimelineSettings.suggested(for: clips, current: TimelineSettings())
        #expect(suggested.fps == Rational(30))
        #expect(suggested.width == 1920 && suggested.height == 1080)
    }

    @Test func portraitMaterialSuggestsPortrait() {
        var clips = (0..<5).map { StoryFixtures.clip("h\($0).mp4") }
        for index in clips.indices { clips[index].meta.rotation = 90 }
        clips += (0..<2).map { StoryFixtures.clip("q\($0).mp4") }
        let suggested = TimelineSettings.suggested(for: clips, current: TimelineSettings())
        #expect(suggested.width == 1080 && suggested.height == 1920)
    }

    @Test func hintExplainsDroppedFrames() {
        let clips =
            (0..<28).map { StoryFixtures.clip("a\($0).mp4", fps: Rational(30)) }
            + (0..<12).map { StoryFixtures.clip("b\($0).mp4", seconds: 8, fps: Rational(24)) }
        let current = TimelineSettings()
        let hint = TimelineSettings.hint(for: clips, current: current)
        #expect(
            hint == "28 von 40 Clips haben 30 fps, die Timeline 25 fps. Bei 25 fps fällt jedes sechste Bild weg.")
        var thirty = current
        thirty.fps = Rational(30)
        #expect(TimelineSettings.hint(for: clips, current: thirty) == nil)
    }

    @Test func presetsCoverFormatsFrom01() {
        let titles = TimelineSettings.presets.map(\.title)
        #expect(titles.contains("Full HD") && titles.contains("Hochformat 9:16") && titles.contains("4K"))
    }

    @MainActor
    @Test func changingRateKeepsCutValid() throws {
        var checked = 0
        var seed: UInt64 = 0
        while checked < 100 {
            var project = SyntheticProject.make(seed: seed, clips: 8...20, duration: 40...120)
            seed += 1
            project.style.refrainMode = .identical
            guard (try? GenerateCut().apply(to: &project)) != nil, var cut = project.cut, cut.shots.count > 4 else {
                continue
            }
            cut.shots[1].locked = true
            cut.shots[cut.shots.count - 2].locked = true
            project.cut = cut
            let locked = cut.shots.filter(\.locked)
            let owner = EditingOwner(project)
            let undo = UndoManager()
            for rate in [Rational(30), Rational(24000, 1001)] {
                var settings = owner.project.timeline
                settings.fps = rate
                try owner.perform(SetTimelineSettings(settings: settings), undoManager: undo)
                let issues = CutValidator.validate(owner.project, cut: owner.project.cut!)
                #expect(issues.isEmpty, "Seed \(seed - 1), \(rate): \(issues.prefix(3))")
                for shot in locked {
                    #expect(
                        owner.project.cut!.shots.contains {
                            $0.locked && $0.clipID == shot.clipID && $0.start.time == shot.start.time
                                && $0.end.time == shot.end.time
                        })
                }
            }
            undo.undo()
            undo.undo()
            #expect(owner.project == project)
            checked += 1
        }
    }
}
