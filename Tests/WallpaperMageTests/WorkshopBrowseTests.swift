import XCTest
import CoreGraphics
@testable import WallpaperMage

// What the Workshop browser asks Steam for: its sorts and filters (WorkshopBrowse.swift) as the QueryFiles request
// they make (WorkshopKit.API.QueryInput, queryURL).
final class WorkshopBrowseTests: XCTestCase {
    private typealias TagGroup = WorkshopKit.API.QueryInput.TagGroup

    private func input(_ sort: WorkshopSort = .standard, text: String = "",
                       filters: WorkshopFilters = .standard) -> WorkshopKit.API.QueryInput {
        WorkshopKit.API.QueryInput(WorkshopKit.API.Browse(key: "KEY", sort: sort, text: text, filters: filters,
                                                          cursor: "*"))
    }

    // MARK: Sorts

    func testEverySortIsOneOfSteamsQueriesAndOnlyTrendsCountDays() {
        let trends: [WorkshopSort: Int] = [.popularYear: 365, .popularMonth: 30, .popularWeek: 7, .popularToday: 1]
        for sort in WorkshopSort.allCases {
            XCTAssertEqual(sort.trendDays, trends[sort], "\(sort)")
            XCTAssertEqual(sort.queryType == 3, trends[sort] != nil, "\(sort)")   // RankedByTrend
        }
        let others = WorkshopSort.allCases.filter { $0.trendDays == nil }
        XCTAssertEqual(Set(others.map(\.queryType)).count, others.count)
        XCTAssertEqual(Set(WorkshopSort.sections.joined()), Set(WorkshopSort.allCases))
        XCTAssertEqual(WorkshopSort.sections.joined().count, WorkshopSort.allCases.count)
    }

    func testASearchKeepsTheChosenSort() {
        let search = input(.mostRecent, text: "  onimai ")
        XCTAssertEqual(search.queryType, WorkshopSort.mostRecent.queryType)
        XCTAssertEqual(search.searchText, "onimai")
        XCTAssertNil(input(.mostRecent, text: " ").searchText)

        let trend = input(.popularMonth, text: "onimai")
        XCTAssertEqual(trend.days, 30)
        XCTAssertEqual(trend.searchText, "onimai")
    }

    // MARK: Filters

    func testStandardFiltersLetEverythingButQuestionableAndMatureItemsThrough() {
        let standard = input()
        XCTAssertEqual(standard.taggroups, [TagGroup(tags: ["Everyone"])])
        XCTAssertEqual(standard.requiredtags, [])
        XCTAssertEqual(standard.excludedtags, ["Asset"])
        XCTAssertFalse(WorkshopFilters.standard.matchesNothing)

        var everything = WorkshopFilters.standard
        everything.set(WorkshopFilterGroup.rating.tags, in: .rating, on: true)
        XCTAssertEqual(input(filters: everything).taggroups, [])
        XCTAssertEqual(everything, WorkshopFilters())
    }

    func testEveryNarrowedGroupIsATagGroupOfTheTagsLeftOn() {
        var filters = WorkshopFilters()
        filters.set(["Web"], in: .type, on: false)
        filters.set(WorkshopFilterGroup.genre.tags, in: .genre, on: false)
        filters.set(["Nature", "Anime"], in: .genre, on: true)
        filters.set(["Mature"], in: .rating, on: false)

        XCTAssertEqual(input(filters: filters).taggroups, [
            TagGroup(tags: ["Scene", "Video"]),
            TagGroup(tags: ["Everyone", "Questionable"]),
            TagGroup(tags: ["Anime", "Nature"]),   // in the group's order
        ])
        XCTAssertNil(filters.allowed(in: .resolution))
        XCTAssertTrue(filters.differsFromStandard(.type))
        XCTAssertFalse(filters.differsFromStandard(.resolution))
    }

    func testShowOnlyTagsAreAllRequired() {
        var filters = WorkshopFilters.standard
        filters.setRequired("Customizable", true)
        filters.setRequired("Approved", true)
        XCTAssertEqual(input(filters: filters).requiredtags, ["Approved", "Customizable"])
        filters.setRequired("Approved", false)
        XCTAssertEqual(input(filters: filters).requiredtags, ["Customizable"])
    }

    func testAGroupWithEveryTagOffMatchesNothing() {
        var filters = WorkshopFilters.standard
        filters.set(WorkshopFilterGroup.category.tags, in: .category, on: false)
        XCTAssertTrue(filters.matchesNothing)
        filters.set(["Preset"], in: .category, on: true)
        XCTAssertFalse(filters.matchesNothing)
    }

    func testFiltersSurviveTheirJSON() {
        var filters = WorkshopFilters.standard
        filters.set(["Dual 3840 x 1080", "Other resolution"], in: .resolution, on: false)
        filters.setRequired("Audio responsive", true)
        XCTAssertEqual(WorkshopFilters(json: filters.json), filters)
        XCTAssertNil(WorkshopFilters(json: ""))
        XCTAssertNil(WorkshopFilters(json: "{\"off\":[1]}"))
    }

    // MARK: Request

    func testTheRequestSendsTheKeyAndTheParametersAsInputJSON() throws {
        var filters = WorkshopFilters.standard
        filters.setRequired("Approved", true)
        let browse = WorkshopKit.API.Browse(key: "KEY", sort: .popularToday, text: "sky", filters: filters,
                                            cursor: "AoJ+abc/=")
        let url = WorkshopKit.API.queryURL(browse)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["key", "input_json"])
        XCTAssertEqual(items[0].value, "KEY")

        let json = try XCTUnwrap(items[1].value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["query_type"] as? Int, 3)
        XCTAssertEqual(object["days"] as? Int, 1)
        XCTAssertEqual(object["search_text"] as? String, "sky")
        XCTAssertEqual(object["cursor"] as? String, "AoJ+abc/=")
        XCTAssertEqual(object["appid"] as? Int, 431960)
        XCTAssertEqual(object["creator_appid"] as? Int, 431960)
        XCTAssertEqual(object["numperpage"] as? Int, WorkshopKit.API.pageSize)
        XCTAssertEqual(object["requiredtags"] as? [String], ["Approved"])
        XCTAssertEqual(object["excludedtags"] as? [String], ["Asset"])
        XCTAssertEqual((object["taggroups"] as? [[String: [String]]])?.map { $0["tags"] }, [["Everyone"]])
        XCTAssertEqual(object["return_tags"] as? Bool, true)
        XCTAssertEqual(object["return_short_description"] as? Bool, true)

        let ranking = WorkshopKit.API.queryURL(WorkshopKit.API.Browse(key: "KEY", sort: .topRated, text: "",
                                                                      filters: .standard, cursor: "*"))
        let rankingJSON = try XCTUnwrap(URLComponents(url: ranking, resolvingAgainstBaseURL: false)?
            .queryItems?.last?.value)
        let rankingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rankingJSON.utf8)) as? [String: Any])
        XCTAssertNil(rankingObject["days"])
        XCTAssertNil(rankingObject["search_text"])
    }

    // MARK: Resolutions

    func testResolutionTagsHaveTheirPixelSize() {
        XCTAssertEqual(WorkshopTags.pixelSize(of: "1920 x 1080"), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(WorkshopTags.pixelSize(of: "Dual 3840 x 1080"), CGSize(width: 3840, height: 1080))
        XCTAssertEqual(WorkshopTags.pixelSize(of: "Portrait 1080 x 1920"), CGSize(width: 1080, height: 1920))
        XCTAssertNil(WorkshopTags.pixelSize(of: "Dual Standard Definition"))
        XCTAssertNil(WorkshopTags.pixelSize(of: "Other resolution"))
        for tag in WorkshopFilterGroup.resolution.tags where !tag.contains("Standard") && !tag.contains("resolution") {
            XCTAssertNotNil(WorkshopTags.pixelSize(of: tag), tag)
        }
    }

    func testDisplaysGetTheResolutionsOfTheirShapeAtLeastAsLargeAsThem() {
        let dynamic = "Dynamic resolution"
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 3840, height: 2160)]), ["3840 x 2160", dynamic])
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 2560, height: 1440),
                                                         CGSize(width: 1920, height: 1080)]),
                       ["1920 x 1080", "2560 x 1440", "3840 x 2160", dynamic])
        // 16:10 is widescreen too.
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 3024, height: 1964)]), ["3840 x 2160", dynamic])
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 3440, height: 1440)]),
                       ["Ultrawide 3440 x 1440", dynamic])
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 5120, height: 1440)]),
                       ["Dual 5120 x 1440", "Dual 7680 x 2160", dynamic])
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 1440, height: 2560)]),
                       ["Portrait 1440 x 2560", "Portrait 2160 x 3840", dynamic])
        // Larger than every tag of its shape: the largest of them.
        XCTAssertEqual(WorkshopTags.resolutions(fitting: [CGSize(width: 6016, height: 3384)]), ["3840 x 2160", dynamic])
        XCTAssertEqual(WorkshopTags.resolutions(fitting: []), [dynamic])
    }
}
