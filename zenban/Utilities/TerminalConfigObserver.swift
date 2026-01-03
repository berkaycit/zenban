//
//  TerminalConfigObserver.swift
//  zenban
//
//  Observes terminal settings changes for config reload triggering
//

import Foundation
import Combine

/// Observes terminal-related UserDefaults keys and increments version on change
@Observable
final class TerminalConfigObserver {
    private(set) var version: Int = 0
    private var cancellable: AnyCancellable?

    init() {
        cancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.version += 1
            }
    }
}
