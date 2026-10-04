// Sends one test-mode command to a satz started with --dev-control.
// Build: swiftc -O satzdev.swift -o satzdev
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("plus.dpa.satz.dev"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
