import AppKit
import SwiftUI
import Carbon

extension Notification.Name {
    static let deckShowManager = Notification.Name("ProfileDeck.ShowManager")
    static let deckShowSwitcher = Notification.Name("ProfileDeck.ShowSwitcher")
    static let deckSwitcherPresented = Notification.Name("ProfileDeck.SwitcherPresented")
    static let deckToggleTabs = Notification.Name("ProfileDeck.ToggleTabs")
    static let deckHideTabs = Notification.Name("ProfileDeck.HideTabs")
    static let deckTabsPointerRefresh = Notification.Name("ProfileDeck.TabsPointerRefresh")
    static let deckResetTabs = Notification.Name("ProfileDeck.ResetTabs")
    static let deckSettingsChanged = Notification.Name("ProfileDeck.SettingsChanged")
    static let deckNotificationAction = Notification.Name("ProfileDeck.NotificationAction")
}
final class DeckPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
/// Defers click delivery until movement is known, preventing activation during a drag.
struct FloatingTabsPointerGesture {
    static let threshold: CGFloat = 5
    private(set) var origin: CGPoint?
    private(set) var dragging = false
    mutating func begin(at point: CGPoint) { origin=point; dragging=false }
    mutating func move(to point: CGPoint) -> Bool {
        guard let origin else { return false }
        if hypot(point.x-origin.x, point.y-origin.y) >= Self.threshold { dragging=true }
        return dragging
    }
    mutating func end() -> Bool {
        let isClick=origin != nil && !dragging
        cancel(); return isClick
    }
    mutating func cancel() { origin=nil; dragging=false }
}

/// Intercepts only this panel's pointer stream; menus, other windows and keyboard
/// accessibility activation retain their native event paths.
final class FloatingTabsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onDragFinished: (() -> Void)?
    private(set) var isDraggingStrip=false
    private var dragCompletion: Task<Void,Never>?
    private var pointer=FloatingTabsPointerGesture()
    private var heldMouseDown: NSEvent?
    private var replayedMouseUp: NSEvent?
    private var passThroughClick=false

    override func sendEvent(_ event: NSEvent) {
        if let replay=replayedMouseUp, event.type == .leftMouseUp,
           event.timestamp == replay.timestamp, event.eventNumber == replay.eventNumber {
            replayedMouseUp=nil; super.sendEvent(event); return
        }
        switch event.type {
        case .leftMouseDown:
            replayedMouseUp=nil; passThroughClick=false
            // Control-click must open the native context menu immediately.
            guard !event.modifierFlags.contains(.control) else {
                heldMouseDown=nil; pointer.cancel(); passThroughClick=true; super.sendEvent(event); return
            }
            heldMouseDown=event; pointer.begin(at:event.locationInWindow)
        case .leftMouseDragged:
            guard let down=heldMouseDown else { super.sendEvent(event); return }
            if pointer.move(to:event.locationInWindow) {
                heldMouseDown=nil; isDraggingStrip=true
                performDrag(with:down)
                pointer.cancel()
                // AppKit returns immediately and may consume mouseUp. Wait for
                // physical release rather than clamping during native dragging.
                dragCompletion?.cancel()
                dragCompletion=Task { @MainActor [weak self] in
                    while NSEvent.pressedMouseButtons & 1 != 0 {
                        do { try await Task.sleep(for:.milliseconds(75)) } catch { return }
                        guard self?.isVisible == true else { return }
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.isDraggingStrip=false
                    self.onDragFinished?()
                    self.dragCompletion=nil
                }
            }
        case .leftMouseUp:
            if passThroughClick { passThroughClick=false; super.sendEvent(event); return }
            guard let down=heldMouseDown else { return }
            heldMouseDown=nil
            guard pointer.end() else { return }
            // Native menu/button mouseDown handlers can synchronously track until
            // mouseUp. Queue it first, then dispatch the saved down. SwiftUI's
            // asynchronous path receives the same queued up on its next turn.
            replayedMouseUp=event
            NSApp.postEvent(event,atStart:true)
            super.sendEvent(down)
        case .keyDown where event.keyCode == 53 && heldMouseDown != nil:
            heldMouseDown=nil; pointer.cancel()
        default:
            super.sendEvent(event)
        }
    }
    override func orderOut(_ sender: Any?) {
        heldMouseDown=nil; replayedMouseUp=nil; pointer.cancel(); passThroughClick=false
        dragCompletion?.cancel(); dragCompletion=nil; isDraggingStrip=false
        super.orderOut(sender)
        NotificationCenter.default.post(name:.deckTabsPointerRefresh,object:self,userInfo:["hovered":false])
    }
    override func close() {
        heldMouseDown=nil; replayedMouseUp=nil; pointer.cancel(); passThroughClick=false
        dragCompletion?.cancel(); dragCompletion=nil; isDraggingStrip=false
        super.close()
    }
}

@MainActor final class PanelController {
    private var switcher: NSPanel?
    private var tabs: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private let model: AppModel
    init(model:AppModel) {
        self.model=model
        observe(.deckShowSwitcher) { [weak self] in self?.showSwitcher() }
        observe(.deckToggleTabs) { [weak self] in guard let self else { return }; var s=self.model.deck.settings; s.showFloatingTabs.toggle(); self.model.updateSettings(s) }
        observe(.deckHideTabs) { [weak self] in self?.hideTabs() }
        observe(.deckResetTabs) { [weak self] in self?.tabs?.center() }
        observe(.deckSettingsChanged) { [weak self] in self?.applySettings() }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.keepTabsReachable() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName:.NSSystemClockDidChange,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in await self?.model.refresh() }
        })
    }
    private func observe(_ name:Notification.Name,action:@escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { _ in MainActor.assumeIsolated { action() } })
    }
    func applySettings() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey=nil }
        if handler == nil {
            var specification=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
            let status=InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in
                Task { @MainActor in NotificationCenter.default.post(name:.deckShowSwitcher,object:nil) }; return noErr
            },1,&specification,nil,&handler)
            if status != noErr { model.shortcutError="Quick-switch registration is unavailable. Use the menu bar." }
        }
        let key=EventHotKeyID(signature:0x50444543,id:1)
        let status=RegisterEventHotKey(model.deck.settings.shortcutKeyCode,model.deck.settings.shortcutModifiers,key,GetApplicationEventTarget(),0,&hotKey)
        model.shortcutError=status == noErr ? nil : "That shortcut is already in use. Choose another shortcut in Settings."
        NSApp.setActivationPolicy(.accessory)
        applyFloatingTabsVisibility()
        switch model.deck.settings.appearance { case "Dark":NSApp.appearance=NSAppearance(named:.darkAqua); case "Light":NSApp.appearance=NSAppearance(named:.aqua); default:NSApp.appearance=nil }
    }
    func showSwitcher() {
        if switcher == nil {
            let panel=DeckPanel(contentRect:NSRect(x:0,y:0,width:540,height:400),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="Quick switch"; panel.isReleasedWhenClosed=false; panel.level = .floating; panel.hidesOnDeactivate=true
            panel.contentView=NSHostingView(rootView:QuickSwitcherView(model:model,onDismiss:{ [weak panel] in panel?.orderOut(nil) }))
            switcher=panel
        }
        switcher?.center(); switcher?.makeKeyAndOrderFront(nil); NSApp.activate()
        NotificationCenter.default.post(name:.deckSwitcherPresented,object:nil)
    }
    @discardableResult func applyFloatingTabsVisibility() -> NSPanel? {
        if model.deck.settings.showFloatingTabs { showTabs() } else { tabs?.orderOut(nil) }
        return tabs
    }
    private func hideTabs() {
        tabs?.orderOut(nil)
        guard model.deck.settings.showFloatingTabs else { return }
        var settings=model.deck.settings; settings.showFloatingTabs=false
        model.updateSettings(settings)
    }
    private func showTabs() {
        if tabs == nil {
            let panel=FloatingTabsPanel(contentRect:NSRect(x:0,y:0,width:660,height:46),styleMask:[.borderless,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="Profile Deck Tabs"; panel.isReleasedWhenClosed=false; panel.level = .floating; panel.hidesOnDeactivate=false
            panel.collectionBehavior=[.canJoinAllApplications,.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
            panel.isMovableByWindowBackground=false
            panel.onDragFinished={ [weak self, weak panel] in
                self?.keepTabsReachable(); panel?.saveFrame(usingName:"ProfileDeckTabs")
                if let panel { NotificationCenter.default.post(name:.deckTabsPointerRefresh,object:panel,userInfo:["hovered":panel.frame.contains(NSEvent.mouseLocation)]) }
            }
            panel.minSize=NSSize(width:300,height:46); panel.maxSize=NSSize(width:max(300, (NSScreen.main?.visibleFrame.width ?? 1200)-16),height:46)
            panel.setFrameAutosaveName("ProfileDeckTabs")
            if !panel.setFrameUsingName("ProfileDeckTabs") { panel.center() }
            tabs=panel
            panel.contentView=NSHostingView(rootView:tabsContent(for: panel))
            observers.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:panel,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideTabs() }
            })
            observers.append(NotificationCenter.default.addObserver(forName:NSWindow.didChangeScreenNotification,object:panel,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepTabsReachable() }
            })
        }
        keepTabsReachable(); tabs?.orderFrontRegardless()
        if let tabs { NotificationCenter.default.post(name:.deckTabsPointerRefresh,object:tabs,userInfo:["hovered":tabs.frame.contains(NSEvent.mouseLocation)]) }
    }
    private func tabsContent(for panel: NSPanel) -> FloatingTabsView {
        // Per-panel override leaves the menu-bar popover and other apps untouched.
        panel.appearance=model.deck.settings.usesHighContrastTabs ? NSAppearance(named:.darkAqua) : nil
        let maximumWidth = max(300, ((panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1200)-16)
        return FloatingTabsView(model:model, maximumWidth:maximumWidth, onPreferredSizeChange:{ [weak panel] size in
            guard let panel, abs(panel.frame.height-size.height) > 0.5 || abs(panel.frame.width-size.width) > 0.5 else { return }
            var frame=panel.frame; frame.origin.y += frame.height-size.height; frame.size=size
            if let screen=panel.screen ?? NSScreen.main {
                frame.origin.x=max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX-size.width))
                frame.origin.y=max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY-size.height))
            }
            panel.setFrame(frame,display:true)
        })
    }
    private func keepTabsReachable() {
        guard let panel=tabs, let screen=panel.screen ?? NSScreen.main else { return }
        guard (panel as? FloatingTabsPanel)?.isDraggingStrip != true else { return }
        let visible=screen.visibleFrame
        panel.maxSize=NSSize(width:max(300, visible.width-16), height:FloatingTabsLayout.panelHeight)
        var frame=panel.frame
        frame.size.width=min(frame.width, max(300, visible.width-16))
        frame.size.height=min(frame.height, visible.height)
        frame.origin.x=max(visible.minX, min(frame.origin.x, visible.maxX-frame.width))
        frame.origin.y=max(visible.minY, min(frame.origin.y, visible.maxY-frame.height))
        if frame != panel.frame { panel.setFrame(frame,display:true) }
        if let host=panel.contentView as? NSHostingView<FloatingTabsView> { host.rootView=tabsContent(for:panel) }
    }
}
