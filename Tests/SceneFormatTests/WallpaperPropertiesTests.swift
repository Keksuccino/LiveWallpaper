import XCTest
@testable import SceneFormat

final class WallpaperPropertiesTests: XCTestCase {
    private func condition(_ source: String, _ values: [String: PropertyValue],
                           functions: [String: () -> PropertyValue] = [:]) throws -> Bool {
        try XCTUnwrap(PropertyCondition(source), source).evaluate(values, functions: functions)
    }

    func testConditionsFromRealWallpapers() throws {
        let values: [String: PropertyValue] = [
            "rainbowscheme": .bool(true), "showbottom": .number(0), "style": .number(1), "scene": .string("ram"),
            "effect": .string("bigpulse"), "pulseanimation": .string("static"),
        ]
        XCTAssertTrue(try condition("rainbowscheme.value", values))
        XCTAssertFalse(try condition("showbottom.value > 0", values))
        XCTAssertTrue(try condition("style.value=='1'", values), "== compares a number and a string as numbers")
        XCTAssertFalse(try condition("style.value==='1'", values), "=== does not")
        XCTAssertFalse(try condition("scene.value !== 'cartoon' && scene.value !== 'ram'", values))
        XCTAssertTrue(try condition("effect.value.endsWith('pulse') === true && pulseanimation.value === 'static'", values))
        XCTAssertFalse(try condition("effect.value === 'visor'", values))
        XCTAssertTrue(try condition("!(showbottom.value) || missing.value", values), "a missing name is undefined")
        XCTAssertTrue(try condition("style.value * 2 + 1 == 3 ? true : false", values))
    }

    func testBuiltInConditionsUseTheCallersFunctions() throws {
        let source = "alignment.value<2&&\(WallpaperProperty.positionVisibility)()"
        let differs = [WallpaperProperty.positionVisibility: { PropertyValue.bool(true) }]
        XCTAssertTrue(try condition(source, ["alignment": .number(0)], functions: differs))
        XCTAssertFalse(try condition(source, ["alignment": .number(3)], functions: differs))
        XCTAssertFalse(try condition(source, ["alignment": .number(1)]), "an unknown function is undefined")
    }

    func testBrokenConditionsAreNoConditions() {
        XCTAssertNil(PropertyCondition(""))
        XCTAssertNil(PropertyCondition("a.value =="))
        XCTAssertNil(PropertyCondition("'open"))
    }

    func testProjectPropertiesOfEveryKind() throws {
        let json = """
        {"general": {"properties": {
            "schemecolor": {"order": 0, "text": "ui_browse_properties_scheme_color", "type": "color", "value": "1 0 0"},
            "clock": {"order": 102, "text": "<b>Clock</b>", "type": "bool", "value": true},
            "size": {"order": 103, "text": "Size", "type": "slider", "min": 0, "max": 2, "fraction": true,
                     "precision": 1, "value": 0.5, "condition": "clock.value"},
            "count": {"order": 104, "text": "Count", "type": "slider", "min": 1, "max": 10, "value": 3},
            "style": {"order": 101, "text": "Style", "type": "combo", "value": 1,
                      "options": [{"label": "A", "value": 1}, {"label": "B", "value": "b"}]},
            "heading": {"order": 100, "text": "ui_custom_heading", "type": "text"},
            "name": {"order": 105, "text": "Name", "type": "textinput", "value": "x"},
            "unknown": {"order": 106, "type": "something"}
        },
        "localization": {"en-us": {"ui_custom_heading": "Heading"}, "de-de": {"ui_custom_heading": "Überschrift"}}}}
        """
        let project = ProjectProperties(projectJSON: Data(json.utf8))
        XCTAssertEqual(project.properties.map(\.key), ["schemecolor", "heading", "style", "clock", "size", "count", "name"])
        let byKey = Dictionary(uniqueKeysWithValues: project.properties.map { ($0.key, $0) })
        XCTAssertEqual(byKey["heading"]?.kind, .label)
        XCTAssertEqual(byKey["name"]?.kind, .textInput)
        XCTAssertEqual(byKey["size"]?.kind, .slider(min: 0, max: 2, step: 0, digits: 1))
        XCTAssertEqual(byKey["count"]?.kind, .slider(min: 1, max: 10, step: 1, digits: 0))
        XCTAssertEqual(byKey["size"]?.condition, PropertyCondition("clock.value"))
        XCTAssertEqual(byKey["clock"]?.defaultValue, .bool(true))
        XCTAssertEqual(byKey["style"]?.kind, .combo([.init(label: "A", value: .number(1)), .init(label: "B", value: .string("b"))]))
        XCTAssertEqual(project.localized("ui_custom_heading", language: "de-de"), "Überschrift")
        XCTAssertEqual(project.localized("ui_custom_heading", language: "de"), "Überschrift")
        XCTAssertEqual(project.localized("ui_custom_heading", language: "fr-fr"), "Heading", "English is the fallback")
        XCTAssertNil(project.localized("other", language: "en-us"))
    }

    func testBuiltInOptionsFollowTheScenesFeatures() {
        let video = WallpaperProperty.builtIn(for: .video).map(\.key)
        XCTAssertEqual(video, ["volume", "rate", "alignment", "alignmentposition", "alignmentx", "alignmenty",
                               "alignmentz", "alignmentfliph", "wcc_v", "wcc_amt", "wec_e", "wec_brs", "wec_con",
                               "wec_sa", "wec_hue"])
        let silent2D = WallpaperProperty.builtIn(for: .scene(SceneFeatures(orthographic: true))).map(\.key)
        XCTAssertFalse(silent2D.contains("volume"))
        XCTAssertTrue(silent2D.contains("alignment"))
        XCTAssertFalse(silent2D.contains("cameraparallax"))
        let threeD = WallpaperProperty.builtIn(for: .scene(SceneFeatures(orthographic: false, sound: true, parallax: true)))
            .map(\.key)
        XCTAssertTrue(threeD.contains("volume") && threeD.contains("cameraparallax"))
        XCTAssertFalse(threeD.contains("alignment") || threeD.contains("alignmentposition"))
        // Sorted, the options sit between the scheme colour (0) and the wallpaper's own properties (100 and up).
        let orders = WallpaperProperty.builtIn(for: .video).map(\.order)
        XCTAssertEqual(orders, orders.sorted())
        XCTAssertTrue(orders.allSatisfy { (1...99).contains($0) })
    }
}
