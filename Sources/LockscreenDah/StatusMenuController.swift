import AppKit

/// Owns the menu-bar presence: the status item, its icon, its menu, and the
/// actions those items invoke. Split out of `AppDelegate`, which now does only
/// app lifecycle — menu construction is presentation and has no business sitting
/// next to launch sequencing.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let coordinator: MonitorCoordinator
    private let statusItem: NSStatusItem
    private lazy var activeHoursPanel: ActiveHoursPanel = {
        let panel = ActiveHoursPanel()
        panel.onSettingsChanged = { [weak self] in self?.coordinator.scheduleSettingsChanged() }
        return panel
    }()

    init(coordinator: MonitorCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()

        coordinator.onStateChange = { [weak self] in self?.refreshStatusIcon() }
    }

    // MARK: - Status icon

    private func statusImage(named symbol: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Lockscreen Dah?"
        )
        image?.isTemplate = true
        return image
    }

    private func refreshStatusIcon() {
        let symbol: String
        switch coordinator.state {
        case .paused: symbol = "pause.circle"
        // Not the pause icon: nothing is being watched and the user didn't
        // choose that, so it has to look like a problem rather than a setting.
        case .cameraUnavailable: symbol = "video.slash.fill"
        // Alerting/locked keep the watching icon — the blackout overlay or
        // lock screen hides the menu bar anyway.
        case .watching, .alerting, .locked:
            if coordinator.recognizer.isPresenceOnly {
                // No enrolled face (or no model) — flag it at a glance.
                symbol = "exclamationmark.triangle.fill"
            } else {
                symbol = "faceid"
            }
        case .enrolling: symbol = "person.crop.circle.badge.plus"
        // The overlay covers the menu bar anyway; the icon only matters in the
        // instant before it is drawn.
        case .dimmed: symbol = "moon.fill"
        }
        statusItem.button?.image = statusImage(named: symbol)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: coordinator.statusDescription, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let isPaused = coordinator.state == .paused || coordinator.state == .cameraUnavailable
        // While a re-enrollment is owed there is exactly one useful action, and
        // the enrollment row below already is it. Offering a second row that
        // runs the same code — under a third line of text that also says
        // "re-enrollment" — reads as three separate choices when there is one.
        let needsReenrollment = isPaused && Settings.reenrollmentRequired
        if !needsReenrollment {
            let toggle = NSMenuItem(
                title: isPaused ? "开始监测" : "暂停监测",
                action: #selector(toggleMonitoring),
                keyEquivalent: ""
            )
            toggle.target = self
            toggle.image = NSImage(
                systemSymbolName: isPaused ? "play.fill" : "pause.fill",
                accessibilityDescription: nil
            )
            menu.addItem(toggle)
        }

        let enroll = NSMenuItem(title: "", action: #selector(enrollFace), keyEquivalent: "")
        enroll.target = self
        if !coordinator.recognizer.hasModel {
            enroll.action = nil
            enroll.title = "缺少人脸模型（请先运行 scripts/fetch-model.sh）"
        } else if coordinator.recognizer.hasProfile {
            // Names the outcome when it's the only way back, so the single row
            // carries the meaning the removed toggle used to.
            enroll.title = needsReenrollment ? "重新录入人脸以恢复" : "重新录入人脸"
            enroll.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: nil
            )
        } else {
            enroll.attributedTitle = NSAttributedString(
                string: "未录入人脸",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.menuFont(ofSize: 0),
                ]
            )
            // Palette layers: [mark, triangle] — one color would swallow the
            // exclamation mark into the triangle fill.
            enroll.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        }
        menu.addItem(enroll)
        menu.addItem(.separator())

        menu.addItem(settingsSubmenu())
        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "关于 Lockscreen Dah",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 Lockscreen Dah", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Settings submenu (stay-open option rows)

    private func settingsSubmenu() -> NSMenuItem {
        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "设置")
        // View-backed items have no action, so auto-enablement would mark
        // them disabled and AppKit would render their views dimmed.
        settingsMenu.autoenablesItems = false

        settingsMenu.addItem(durationSubmenu(
            title: "无人判定延迟",
            options: Settings.gracePeriodOptions,
            get: { Settings.gracePeriod },
            set: { [weak self] in
                Settings.gracePeriod = $0
                // The scheduled deadline (if already watching) was computed from
                // the old value — recompute it now rather than waiting for the
                // next real presence observation.
                self?.coordinator.gracePeriodSettingChanged()
            }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "倒计时时长",
            options: Settings.countdownOptions,
            get: { Settings.countdownDuration },
            set: { Settings.countdownDuration = $0 },
            rowLabel: { $0 == 0 ? "永不倒计时" : "\(Int($0)) 秒" },
            valueLabel: { $0 == 0 ? "永不" : "\(Int($0))秒" }
        ))
        settingsMenu.addItem(.separator())

        // Camera timing. Every one of these is read on the next tick, so
        // changing one takes effect immediately — the point is to trade
        // responsiveness against how much the IR emitters and camera LED are
        // allowed to be lit.
        settingsMenu.addItem(durationSubmenu(
            title: "键鼠输入视为在场",
            options: Settings.inputPresenceOptions,
            get: { Settings.inputPresenceWindow },
            set: { [weak self] in
                Settings.inputPresenceWindow = $0
                self?.coordinator.timingSettingsChanged()
            },
            rowLabel: { $0 == 0 ? "关闭（相机常开）" : "\(Int($0)) 秒" },
            valueLabel: { $0 == 0 ? "关闭" : "\(Int($0))秒" }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "快速检查间隔",
            options: Settings.quickCheckIntervalOptions,
            get: { Settings.quickCheckInterval },
            set: { [weak self] in
                Settings.quickCheckInterval = $0
                self?.coordinator.timingSettingsChanged()
            }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "快速检查时长",
            options: Settings.quickCheckDurationOptions,
            get: { Settings.quickCheckDuration },
            set: { [weak self] in
                Settings.quickCheckDuration = $0
                self?.coordinator.timingSettingsChanged()
            },
            rowLabel: {
                $0 == 1 ? "1 秒" : ($0 == 1.5 ? "1.5 秒" : "\(Int($0)) 秒")
            },
            valueLabel: { $0 == 1.5 ? "1.5s" : "\(Int($0))秒" }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "灭屏检查间隔",
            options: Settings.dimmedCheckOptions,
            get: { Settings.dimmedCheckInterval },
            set: { [weak self] in
                Settings.dimmedCheckInterval = $0
                self?.coordinator.timingSettingsChanged()
            }
        ))
        settingsMenu.addItem(durationSubmenu(
            title: "灭屏检查时长",
            options: Settings.dimmedCheckDurationOptions,
            get: { Settings.dimmedCheckDuration },
            set: { [weak self] in
                Settings.dimmedCheckDuration = $0
                self?.coordinator.timingSettingsChanged()
            },
            rowLabel: { $0 < 1 ? String(format: "%.1f 秒", $0) : "\(Int($0)) 秒" },
            valueLabel: { $0 < 1 ? String(format: "%.1fs", $0) : "\(Int($0))秒" }
        ))
        settingsMenu.addItem(.separator())
        let hoursTitle: String
        if Settings.scheduleEnabled {
            let span = "\(Settings.formatMinutes(Settings.scheduleStartMinutes))–\(Settings.formatMinutes(Settings.scheduleEndMinutes))"
            hoursTitle = "监测时段（\(span)，\(Weekday.describe(Settings.activeDays))）…"
        } else {
            hoursTitle = "监测时段（始终开启）…"
        }
        let hours = NSMenuItem(title: hoursTitle, action: #selector(showActiveHours), keyEquivalent: "")
        hours.target = self
        settingsMenu.addItem(hours)
        settingsMenu.addItem(.separator())

        // Tight layout: aligns with the native submenu rows above it, which
        // have no checkmark gutter.
        let dimItem = NSMenuItem(
            title: "只灭屏不锁屏",
            action: #selector(toggleDimInsteadOfLock),
            keyEquivalent: ""
        )
        dimItem.target = self
        dimItem.state = Settings.dimInsteadOfLock ? .on : .off
        settingsMenu.addItem(dimItem)
        settingsMenu.addItem(.separator())

        let loginView = StayOpenOptionView(title: "登录时启动", layout: .tight)
        loginView.isChecked = LoginItem.isRegistered
        loginView.onClick = { [weak self, weak loginView] in
            self?.toggleLaunchAtLogin()
            loginView?.isChecked = LoginItem.isRegistered
        }
        let loginItem = NSMenuItem()
        loginItem.view = loginView
        settingsMenu.addItem(loginItem)

        settings.submenu = settingsMenu
        return settings
    }

    @objc private func toggleDimInsteadOfLock() {
        Settings.dimInsteadOfLock.toggle()
        coordinator.dimModeSettingChanged()
    }

    /// A submenu of stay-open duration options; the parent title shows the
    /// chosen value and refreshes live when an option is clicked. Optional
    /// label closures cover non-duration options (e.g. 0 = "从不空闲").
    private func durationSubmenu(
        title: String,
        options: [TimeInterval],
        get: @escaping () -> TimeInterval,
        set: @escaping (TimeInterval) -> Void,
        rowLabel: ((TimeInterval) -> String)? = nil,
        valueLabel: ((TimeInterval) -> String)? = nil
    ) -> NSMenuItem {
        let row = rowLabel ?? { $0 == 1 ? "1 秒" : "\(Int($0)) 秒" }
        let value = valueLabel ?? { "\(Int($0))秒" }
        let parent = NSMenuItem(title: "\(title) \(value(get()))", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false

        // A value chosen from an earlier build's list (say a 15 s idle delay that
        // is no longer offered) is still in effect, so it gets its own row rather
        // than leaving every row unticked — which reads as "nothing is set".
        // Settings are never rewritten behind the user's back to force a match.
        var options = options
        if !options.contains(get()) {
            let never = options.filter { $0 == 0 } // 0 renders as "永不", stays last
            options = (options.filter { $0 != 0 } + [get()]).sorted() + never
        }

        var views: [(StayOpenOptionView, TimeInterval)] = []
        for option in options {
            let view = StayOpenOptionView(title: row(option))
            view.isChecked = option == get()
            view.onClick = { [weak parent] in
                set(option)
                for (optionView, optionValue) in views {
                    optionView.isChecked = optionValue == get()
                }
                parent?.title = "\(title) \(value(get()))"
            }
            views.append((view, option))
            let item = NSMenuItem()
            item.view = view
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func showActiveHours() {
        activeHoursPanel.show()
    }

    @objc private func toggleMonitoring() {
        let isOff = coordinator.state == .paused || coordinator.state == .cameraUnavailable
        guard isOff else {
            coordinator.pause()
            return
        }
        // The only route past an outstanding re-enrollment requirement. The
        // existing profile stays in use until the new one is saved, so a
        // cancelled enrollment leaves you no worse off.
        if Settings.reenrollmentRequired {
            coordinator.enrollFace()
        } else {
            coordinator.startMonitoring()
        }
    }

    @objc private func enrollFace() {
        coordinator.enrollFace()
    }

    @objc private func showAbout() {
        AboutPanel.shared.show()
    }

    private func toggleLaunchAtLogin() {
        guard let error = LoginItem.toggle() else { return }
        let alert = NSAlert()
        alert.messageText = "无法更新登录项"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
