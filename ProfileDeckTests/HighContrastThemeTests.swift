import XCTest
import SwiftUI
import AppKit
@testable import ProfileDeck

final class HighContrastThemeTests: XCTestCase {
    func testOlderSettingsRemainOptedOutAndKeepAppearanceChoice() throws {
        var settings=DeckSettings(); settings.appearance="Light"
        let data=try JSONEncoder().encode(settings)
        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        legacy.removeValue(forKey:"highContrastDark")
        let decoded=try JSONDecoder().decode(DeckSettings.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertNil(decoded.highContrastDark)
        XCTAssertFalse(decoded.usesHighContrastTabs)
        XCTAssertFalse(decoded.usesHighContrastDark)
        XCTAssertEqual(decoded.appearance,"Light")
    }
    func testOptInAndOptOutRoundTripWithoutChangingExistingAppearance() throws {
        for appearance in ["System","Light","Dark"] {
            for enabled in [true,false] {
                var deck=PersistedDeck()
                deck.settings.appearance=appearance
                deck.settings.highContrastDark=enabled
                let restored=try JSONDecoder().decode(PersistedDeck.self,from:JSONEncoder().encode(deck))
                XCTAssertEqual(restored.settings.highContrastDark,enabled)
                XCTAssertEqual(restored.settings.usesHighContrastTabs,enabled)
                XCTAssertFalse(restored.settings.usesHighContrastDark)
                XCTAssertEqual(restored.settings.appearance,appearance)
            }
        }
    }
    @MainActor func testThemeIsScopedAndDefaultsToOff() throws {
        XCTAssertFalse(EnvironmentValues().deckHighContrastDark)
        let originalAppearance=NSApp.appearance
        let host=NSHostingView(rootView:Color.clear.frame(width:40,height:40).deckHighContrastSurface(enabled:true))
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:40,height:40),styleMask:[.borderless],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false; panel.contentView=host
        host.layoutSubtreeIfNeeded()
        defer { panel.close() }
        XCTAssertTrue(NSApp.appearance === originalAppearance, "The opt-in must not override application/menu appearance")
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let color=try XCTUnwrap(bitmap.colorAt(x:20,y:20)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(color.redComponent,0.02)
        XCTAssertLessThan(color.greenComponent,0.02)
        XCTAssertLessThan(color.blueComponent,0.02)
    }
    @MainActor func testVercelReferenceTokensAndSurfaceHierarchy() throws {
        func rgb(_ color: Color) throws -> [Int] {
            let c=try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            return [c.redComponent,c.greenComponent,c.blueComponent].map { Int(($0*255).rounded()) }
        }
        XCTAssertEqual(try rgb(DeckVercelPalette.surface),[0,0,0])
        XCTAssertEqual(try rgb(DeckVercelPalette.panel),[10,10,10])
        XCTAssertEqual(try rgb(DeckVercelPalette.control),[19,19,19])
        XCTAssertEqual(try rgb(DeckVercelPalette.elevated),[26,26,26])
        XCTAssertEqual(try rgb(DeckVercelPalette.ink),[237,237,237])
        XCTAssertEqual(try rgb(DeckVercelPalette.accent),[0,110,254])
        XCTAssertEqual(try rgb(DeckVercelPalette.selection),[0,25,59])
    }
    func testProviderPlanNameIsHumanizedWithoutMarketingSubstitution() {
        let raw="Self_Serve_Business_Prolite"
        XCTAssertEqual(PlanDisplayName.format(raw),"Self Serve Business Prolite")
        XCTAssertEqual(raw,"Self_Serve_Business_Prolite")
        XCTAssertEqual(PlanDisplayName.format("plus"),"Plus")
    }

}
