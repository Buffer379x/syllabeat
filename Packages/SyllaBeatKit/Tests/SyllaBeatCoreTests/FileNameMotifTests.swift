import Testing

@testable import SyllaBeatCore

@Suite struct FileNameMotifTests {
    static let groups: Set<String> = ["farm", "general"]

    @Test func copySuffixAndGeneratorAreRemoved() {
        let motif = FileNameMotif.parse("farm_family_with_pigs_1080p_wan (2).mp4", groups: Self.groups)
        #expect(motif.group == "farm")
        #expect(motif.key == "family with pigs")
        #expect(motif.copy == 2)
        #expect(motif.generator == "wan")
        #expect(motif.watermark == nil)
        #expect(motif.timeOfDay == nil)
    }

    @Test func variantNumberIsNotPartOfTheMotif() {
        let motif = FileNameMotif.parse("farm_family_with_horses_1_1080p_wan.mp4", groups: Self.groups)
        #expect(motif.key == "family with horses")
        #expect(motif.copy == 1)
    }

    @Test func noWatermarkAndSunsetAreRecognized() {
        let motif = FileNameMotif.parse(
            "general_family_driving_in_car_on_country_road_during_sunset_1080p_wan_no_watermark.mp4",
            groups: Self.groups)
        #expect(motif.key == "family driving in car on country road during sunset")
        #expect(motif.generator == "wan")
        #expect(motif.watermark == false)
        #expect(motif.timeOfDay == "Abend")
    }

    @Test func watermarkIsRecognized() {
        let motif = FileNameMotif.parse(
            "general_family_leaving_the_house_2_1080p_veo_watermark.mp4", groups: Self.groups)
        #expect(motif.key == "family leaving the house")
        #expect(motif.generator == "veo")
        #expect(motif.watermark == true)
    }

    @Test func cameraFileStaysReadable() {
        let motif = FileNameMotif.parse("IMG_0042.MOV")
        #expect(motif.key == "img")
        #expect(motif.group == nil)
        #expect(motif.generator == nil)
    }

    @Test func wordsKeepNamesForLyrics() {
        let motif = FileNameMotif.parse("farm_marc_lio_in_mud_2_1080p_wan.mp4", groups: Self.groups)
        #expect(motif.words == ["marc", "lio", "in", "mud"])
    }

    @Test func groupsNeedThreeFilesButNotAll() {
        let names = ["farm_a.mp4", "farm_b.mp4", "farm_c.mp4", "general_d.mp4", "general_e.mp4", "x.mp4"]
        #expect(FileNameMotif.groups(in: names) == ["farm"])
        #expect(FileNameMotif.groups(in: ["farm_a.mp4", "farm_b.mp4", "farm_c.mp4"]).isEmpty)
    }
}
