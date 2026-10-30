import Testing

@testable import SyllaBeatAI
@testable import SyllaBeatCore

@Suite struct ShotListTests {
    @Test func fileNameFollowsConvention() {
        #expect(
            ShotList.fileName(for: "Marc füttert gleich ein Huhn", group: "farm") == "farm_marc_fuettert_gleich_huhn")
        #expect(ShotList.fileName(for: "Marc füttert gleich ein Huhn", group: nil) == "marc_fuettert_gleich_huhn")
    }

    @Test func promptCombinesStyleAndContent() {
        #expect(
            ShotList.prompt(style: "Strickpuppen aus Wolle", content: "Die Ziegen kauen")
                == "Strickpuppen aus Wolle. Die Ziegen kauen")
        #expect(ShotList.prompt(style: " ", content: "Die Ziegen kauen") == "Die Ziegen kauen")
    }

    @Test func entriesCoverLinesChaptersAndWatermarks() {
        var project = Project()
        project.story.promptStyle = "Strickpuppen"
        project.story.chapters = [Chapter(id: "k", name: "Abschied", color: 0)]
        let report = CoverageReport(
            lines: [LineGap(text: "Gucken, Streicheln, Füttern", confidence: 0.42, marked: false)],
            chapters: [ChapterNeed(chapterID: "k", needed: 15, available: 15, status: .short, suggestedClips: 1)],
            watermarkOnly: ["general sun in the sky"])
        let entries = ShotList.entries(report, project: project)
        #expect(entries.map(\.kind) == [.line, .chapter, .watermark])
        #expect(entries[0].prompt == "Strickpuppen. Gucken, Streicheln, Füttern")
        #expect(entries[2].fileName == "general_sun_in_the_sky_no_watermark")
        #expect(ShotList.text(entries).contains("Abschied"))
    }
}
