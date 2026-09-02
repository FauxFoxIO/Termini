//
//  TerminiTerminalFindTests.swift
//  TerminiTests
//
//  Created by Ethan Lipnik on 9/1/26.
//

import Testing
@testable import Termini

@Suite("TerminiTerminalFindTests")
@MainActor
struct TerminiTerminalFindTests {
    @Test
    func queryQueuedBeforeBindReplaysOnce() {
        let controller = TerminiTerminalController()
        controller.setFindQuery("needle")

        var dispatchedQueries: [String] = []
        bind(controller) { query in
            dispatchedQueries.append(query)
        }

        #expect(dispatchedQueries == ["needle"])
        #expect(controller.findState.query == "needle")
        #expect(controller.findState.isActive)
        #expect(controller.findState.isReady)
    }

    @Test
    func queryUpdatesStateAndNotifies() {
        let controller = TerminiTerminalController()
        var states: [TerminiTerminalFindState] = []
        controller.onFindStateChange = { states.append($0) }
        bind(controller)
        states.removeAll()

        controller.setFindQuery("needle")

        #expect(states.count == 1)
        #expect(states.first?.query == "needle")
        #expect(states.first?.isActive == true)
        #expect(states.first?.totalMatches == nil)
    }

    @Test
    func nextAndPreviousDispatchToBoundSurface() {
        let controller = TerminiTerminalController()
        var actions: [String] = []
        bind(
            controller,
            findNext: { actions.append("next") },
            findPrevious: { actions.append("previous") }
        )

        controller.findNext()
        controller.findPrevious()

        #expect(actions == ["next", "previous"])
    }

    @Test
    func clearAndEndResetFindState() {
        let controller = TerminiTerminalController()
        var clearCount = 0
        bind(controller, clearFind: { clearCount += 1 })

        controller.setFindQuery("needle")
        controller.clearFind()

        #expect(clearCount == 1)
        #expect(controller.findState == TerminiTerminalFindState(isReady: true))

        controller.reportFindStarted("needle")
        controller.reportFindEnded()

        #expect(controller.findState == TerminiTerminalFindState(isReady: true))
    }

    @Test
    func totalZeroAndSelectedIndexArePreserved() {
        let controller = TerminiTerminalController()
        bind(controller)

        controller.reportFindStarted("needle")
        controller.reportFindTotal(0)
        controller.reportFindSelected(3)

        #expect(controller.findState.totalMatches == 0)
        #expect(controller.findState.selectedMatchIndex == 3)
        #expect(controller.findState.isActive)
    }

    @Test
    func unchangedFindStateDoesNotNotifyRepeatedly() {
        let controller = TerminiTerminalController()
        var notificationCount = 0
        controller.onFindStateChange = { _ in notificationCount += 1 }
        bind(controller)
        notificationCount = 0

        controller.reportFindStarted("needle")
        controller.reportFindStarted("needle")
        controller.reportFindTotal(nil)
        controller.reportFindSelected(0)

        #expect(notificationCount == 1)
    }

    private func bind(
        _ controller: TerminiTerminalController,
        setFindQuery: @escaping (String) -> Void = { _ in },
        findNext: @escaping () -> Void = {},
        findPrevious: @escaping () -> Void = {},
        clearFind: @escaping () -> Void = {}
    ) {
        controller.bind(
            processRemoteOutput: { _ in },
            focus: {},
            blur: {},
            currentSize: { nil },
            visibleText: { nil },
            diagnostics: { nil },
            setFindQuery: setFindQuery,
            findNext: findNext,
            findPrevious: findPrevious,
            clearFind: clearFind
        )
    }
}
