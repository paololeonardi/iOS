//
//  Environment.swift
//  HomeAssistant
//
//  Created by Stephan Vanterpool on 6/15/18.
//  Copyright © 2018 Robbie Trencheny. All rights reserved.
//

import Foundation
import PromiseKit
import RealmSwift
import XCGLogger
import CoreMotion
import DeviceKit
import CoreLocation
import Version
#if os(iOS)
import CoreTelephony
import Reachability
#endif

public enum AppConfiguration: Int, CaseIterable {
    case FastlaneSnapshot
    case Debug
    case Beta
    case Release

    var description: String {
        switch self {
        case .FastlaneSnapshot:
            return "fastlane"
        case .Debug:
            return "debug"
        case .Beta:
            return "beta"
        case .Release:
            return "release"
        }
    }
}

public var Current = Environment()
/// The current "operating envrionment" the app. Implementations can be swapped out to facilitate better
/// unit tests.
public class Environment {
    /// Provides URLs usable for storing data.
    public var date: () -> Date = Date.init
    public var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }

    /// Provides the Client Event store used for local logging.
    public var clientEventStore = ClientEventStore()

    /// Provides the Realm used for many data storage tasks.
    public var realm: () -> Realm = Realm.live

    public var api: () -> HomeAssistantAPI? = { HomeAssistantAPI.authenticatedAPI() }
    public var tokenManager: TokenManager?

    public var settingsStore = SettingsStore()

    public lazy var serverVersion: () -> Version = { [settingsStore] in settingsStore.serverVersion }

    #if os(iOS)
    public var authenticationControllerPresenter: ((UIViewController) -> Void)?
    #endif

    public enum SignInRequiredType {
        case logout
        case error

        public var shouldShowError: Bool {
            switch self {
            case .logout: return false
            case .error:  return true
            }
        }
    }

    public var signInRequiredCallback: ((SignInRequiredType) -> Void)?

    public var onboardingComplete: (() -> Void)?

    public var isPerformingSingleShotLocationQuery = false

    public var syncMonitoredRegions: (() -> Void)?

    public var logEvent: ((String, [String: Any]?) -> Void)?

    public var setUserProperty: ((String?, String) -> Void)?

    public func updateWith(authenticatedAPI: HomeAssistantAPI) {
        self.tokenManager = authenticatedAPI.tokenManager
        self.settingsStore.connectionInfo = authenticatedAPI.connectionInfo
    }

    // Use of 'appConfiguration' is preferred, but sometimes Beta builds are done as releases.
    public let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

    private let isFastlaneSnapshot = UserDefaults(suiteName: Constants.AppGroupID)!.bool(forKey: "FASTLANE_SNAPSHOT")

    // This can be used to add debug statements.
    public var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public var appConfiguration: AppConfiguration {
        if isFastlaneSnapshot {
            return .FastlaneSnapshot
        } else if isDebug {
            return .Debug
        } else if (Bundle.main.bundleIdentifier ?? "").lowercased().contains("beta") && isTestFlight {
            return .Beta
        } else {
            return .Release
        }
    }

    public var Log: XCGLogger = {
        if NSClassFromString("XCTest") != nil {
            return XCGLogger()
        }

        // Create a logger object with no destinations
        let log = XCGLogger(identifier: "advancedLogger", includeDefaultDestinations: false)

        // Create a destination for the system console log (via NSLog)
        let systemDestination = AppleSystemLogDestination(identifier: "advancedLogger.systemDestination")

        // Optionally set some configuration options
        systemDestination.outputLevel = .verbose
        systemDestination.showLogIdentifier = false
        systemDestination.showFunctionName = true
        systemDestination.showThreadName = true
        systemDestination.showLevel = true
        systemDestination.showFileName = true
        systemDestination.showLineNumber = true
        systemDestination.showDate = true

        // Add the destination to the logger
        log.add(destination: systemDestination)

        let logPath = Constants.LogsDirectory.appendingPathComponent("log.txt", isDirectory: false)

        // Create a file log destination
        let fileDestination = AutoRotatingFileDestination(writeToFile: logPath,
                                                          identifier: "advancedLogger.fileDestination",
                                                          shouldAppend: true)

        // Optionally set some configuration options
        fileDestination.outputLevel = .verbose
        fileDestination.showLogIdentifier = false
        fileDestination.showFunctionName = true
        fileDestination.showThreadName = true
        fileDestination.showLevel = true
        fileDestination.showFileName = true
        fileDestination.showLineNumber = true
        fileDestination.showDate = true

        // Process this destination in the background
        fileDestination.logQueue = XCGLogger.logQueue

        // Add the destination to the logger
        log.add(destination: fileDestination)

        #if os(iOS) && !DEBUG
        log.add(destination: CrashlyticsLogDestination())
        #endif

        // Add basic app info, version info etc, to the start of the logs
        log.logAppDetails()

        return log
    }()

    /// Wrapper around CMMotionActivityManager
    public struct Motion {
        private let underlyingManager = CMMotionActivityManager()
        public var isAuthorized: () -> Bool = {
            if #available(iOS 11, *) {
                return CMMotionActivityManager.authorizationStatus() == .authorized
            } else {
                return true
            }
        }
        public var isActivityAvailable: () -> Bool = CMMotionActivityManager.isActivityAvailable
        public lazy var queryStartEndOnQueueHandler: (
            Date, Date, OperationQueue, @escaping CMMotionActivityQueryHandler
        ) -> Void = { [underlyingManager] start, end, queue, handler in
            underlyingManager.queryActivityStarting(from: start, to: end, to: queue, withHandler: handler)
        }
    }
    public var motion = Motion()

    /// Wrapper around CMPedometeer
    public struct Pedometer {
        private let underlyingPedometer = CMPedometer()
        public var isAuthorized: () -> Bool = {
            if #available(iOS 11, *) {
                return CMPedometer.authorizationStatus() == .authorized
            } else {
                return true
            }
        }

        public var isStepCountingAvailable: () -> Bool = CMPedometer.isStepCountingAvailable
        public lazy var queryStartEndHandler: (
            Date, Date, @escaping CMPedometerHandler
        ) -> Void = { [underlyingPedometer] start, end, handler in
            underlyingPedometer.queryPedometerData(from: start, to: end, withHandler: handler)
        }
    }
    public var pedometer = Pedometer()

    /// Wrapper around DeviceKit
    public struct DeviceWrapper {
        public lazy var batteryLevel: () -> Int = { Device.current.batteryLevel ?? 0 }
        public lazy var batteryState: () -> Device.BatteryState = { Device.current.batteryState ?? .full }
        public lazy var isLowPowerMode: () -> Bool = { Device.current.batteryState?.lowPowerMode ?? false }
        public lazy var volumes: () -> [URLResourceKey: Int64]? = {
            #if os(iOS)
            if #available(iOS 11, *) {
                return Device.volumes
            } else {
                return nil
            }
            #else
                return nil
            #endif
        }
    }
    public var device = DeviceWrapper()

    /// Wrapper around CLGeocoder
    public struct Geocoder {
        public var geocode: (CLLocation) -> Promise<[CLPlacemark]> = CLGeocoder.geocode(location:)
    }
    public var geocoder = Geocoder()

    /// Wrapper around CoreTelephony, Reachability
    public struct Connectivity {
        public var currentWiFiSSID: () -> String? = { ConnectionInfo.CurrentWiFiSSID }
        public var currentWiFiBSSID: () -> String? = { ConnectionInfo.CurrentWiFiBSSID }
        #if os(iOS)
        public var simpleNetworkType: () -> NetworkType = Reachability.getSimpleNetworkType
        public var cellularNetworkType: () -> NetworkType = Reachability.getNetworkType

        public var telephonyCarriers: () -> [String: CTCarrier]? = {
            let info = CTTelephonyNetworkInfo()

            if #available(iOS 12, *) {
                return info.serviceSubscriberCellularProviders
            } else {
                return info.subscriberCellularProvider.flatMap { ["1": $0] }
            }
        }
        public var telephonyRadioAccessTechnology: () -> [String: String]? = {
            let info = CTTelephonyNetworkInfo()
            if #available(iOS 12, *) {
                return info.serviceCurrentRadioAccessTechnology
            } else {
                return info.currentRadioAccessTechnology.flatMap { ["1": $0] }
            }
        }
        #endif
    }
    public var connectivity = Connectivity()
}
