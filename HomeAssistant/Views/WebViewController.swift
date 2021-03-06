//
//  WebViewController.swift
//  HomeAssistant
//
//  Created by Robert Trencheny on 4/10/17.
//  Copyright © 2017 Robbie Trencheny. All rights reserved.
//

import UIKit
import Alamofire
import WebKit
import KeychainAccess
import PromiseKit
import MaterialComponents.MaterialButtons
import Iconic
import SwiftMessages
import Shared
import AVFoundation
import AVKit
import WhatsNewKit
import CoreLocation

// swiftlint:disable:next type_body_length
class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIViewControllerRestoration {

    var webView: WKWebView!

    var urlObserver: NSKeyValueObservation?

    let refreshControl = UIRefreshControl()

    // var remotePlayer = RemoteMediaPlayer()

    var keepAliveTimer: Timer?
    private var initialURL: URL?

    static func viewController(
        withRestorationIdentifierPath identifierComponents: [String],
        coder: NSCoder
    ) -> UIViewController? {
        let webViewController = WebViewController()
        // although the system is also going to call through this restoration method, it's going to do it _too late_
        webViewController.decodeRestorableState(with: coder)
        return webViewController
    }

    let settingsButton: MDCFloatingButton! = {
        let button = MDCFloatingButton()
        button.setImage(MaterialDesignIcons.settingsIcon.image(ofSize: CGSize(width: 36, height: 36), color: .white),
                        for: .normal)
        button.accessibilityLabel = L10n.Settings.NavigationBar.title
        button.minimumSize = CGSize(width: 64, height: 48)
        button.frame = CGRect(x: 0, y: 0, width: 64, height: 48)
        // #ff9800 orange
        button.backgroundColor = UIColor(red: 1.00, green: 0.60, blue: 0.00, alpha: 1.0)
        button.translatesAutoresizingMaskIntoConstraints = false
        if Current.appConfiguration == .FastlaneSnapshot {
            button.alpha = 0
        }
        return button
    }()

    enum RestorableStateKey: String {
        case lastURL
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(webView.url as NSURL?, forKey: RestorableStateKey.lastURL.rawValue)
    }

    override func decodeRestorableState(with coder: NSCoder) {
        guard !isViewLoaded else {
            // this is state decoding late in the cycle, not our initial one; ignore.
            return
        }

        initialURL = coder.decodeObject(of: NSURL.self, forKey: RestorableStateKey.lastURL.rawValue) as URL?
        super.decodeRestorableState(with: coder)
    }

    // swiftlint:disable:next function_body_length
    override func viewDidLoad() {
        super.viewDidLoad()

        restorationClass = Self.self
        restorationIdentifier = String(describing: Self.self)

        self.becomeFirstResponder()
        // self.showWhatsNew()
        // self.remotePlayer.delegate = self
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(WebViewController.loadActiveURLIfNeeded),
                                               name: HomeAssistantAPI.didConnectNotification,
                                               object: nil)

        let statusBarView: UIView = UIView(frame: UIApplication.shared.statusBarFrame)
        statusBarView.tag = 111

        view.addSubview(statusBarView)

        statusBarView.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        statusBarView.leftAnchor.constraint(equalTo: self.view.leftAnchor).isActive = true
        statusBarView.rightAnchor.constraint(equalTo: self.view.rightAnchor).isActive = true
        statusBarView.bottomAnchor.constraint(equalTo: self.topLayoutGuide.bottomAnchor).isActive = true

        statusBarView.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "getExternalAuth")
        userContentController.add(self, name: "revokeExternalAuth")
        userContentController.add(self, name: "externalBus")
        userContentController.add(self, name: "updateThemeColors")
        userContentController.add(self, name: "currentUser")
        userContentController.add(self, name: "mediaPlayerCommand")

        if let webhookID = Current.settingsStore.connectionInfo?.webhookID {
            let webhookGlobal = "window.webhookID = '\(webhookID)';"
            userContentController.addUserScript(WKUserScript(source: webhookGlobal, injectionTime: .atDocumentStart,
                                                             forMainFrameOnly: false))
        }

        guard let wsBridgeJSPath = Bundle.main.path(forResource: "WebSocketBridge", ofType: "js"),
            let wsBridgeJS = try? String(contentsOfFile: wsBridgeJSPath) else {
                fatalError("Couldn't load WebSocketBridge.js for injection to WKWebView!")
        }

        userContentController.addUserScript(WKUserScript(source: wsBridgeJS, injectionTime: .atDocumentEnd,
                                                         forMainFrameOnly: false))

        if Current.appConfiguration == .FastlaneSnapshot {
            let hideDemoCardScript = WKUserScript(source: "localStorage.setItem('hide_demo_card', '1');",
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false)
            userContentController.addUserScript(hideDemoCardScript)

            if let langCode = Locale.current.languageCode {
                // swiftlint:disable:next line_length
                let setLanguageScript = WKUserScript(source: "localStorage.setItem('selectedLanguage', '\"\(langCode)\"');",
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: false)
                userContentController.addUserScript(setLanguageScript)
            }

            SettingsViewController.showMapContentExtension()
        }

        config.userContentController = userContentController
        config.applicationNameForUserAgent = SessionManager.defaultHTTPHeaders["User-Agent"]

        self.webView = WKWebView(frame: self.view!.frame, configuration: config)
        self.webView.isOpaque = false
        self.view!.addSubview(webView)

        urlObserver = self.webView.observe(\.url) { (webView, _) in
            if let currentURL = webView.url?.absoluteString.replacingOccurrences(of: "?external_auth=1", with: ""),
                let cleanURL = URL(string: currentURL), let scheme = cleanURL.scheme {
                if !scheme.hasPrefix("http") {
                    Current.Log.warning("Was going to provide invalid URL to NSUserActivity! \(currentURL)")
                    return
                }
                self.userActivity = NSUserActivity(activityType: "\(Constants.BundleID).frontend")
                self.userActivity?.isEligibleForHandoff = true
                self.userActivity?.webpageURL = cleanURL
                self.userActivity?.becomeCurrent()
            }
        }

        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self

        self.webView.translatesAutoresizingMaskIntoConstraints = false

        self.webView.leftAnchor.constraint(equalTo: self.view.leftAnchor).isActive = true
        self.webView.rightAnchor.constraint(equalTo: self.view.rightAnchor).isActive = true
        self.webView.topAnchor.constraint(equalTo: statusBarView.bottomAnchor).isActive = true
        self.webView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true

        self.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        refreshControl.addTarget(self, action: #selector(self.pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.addSubview(refreshControl)
        webView.scrollView.bounces = true

        self.settingsButton.addTarget(self, action: #selector(self.openSettingsView(_:)), for: .touchDown)

        self.view.addSubview(self.settingsButton)

        self.view.bottomAnchor.constraint(equalTo: self.settingsButton.bottomAnchor, constant: 16.0).isActive = true
        self.view.rightAnchor.constraint(equalTo: self.settingsButton.rightAnchor, constant: 16.0).isActive = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateWebViewSettings),
            name: SettingsStore.webViewRelatedSettingDidChange,
            object: nil
        )
        updateWebViewSettings()

        styleUI()
    }

    public func showSettingsViewController() {
        let settingsView = SettingsViewController()
        // settingsView.doneButton = true
        // settingsView.delegate = self
        settingsView.hidesBottomBarWhenPushed = true
        let navController = UINavigationController(rootViewController: settingsView)
        self.navigationController?.present(navController, animated: true, completion: nil)
    }

    // Workaround for webview rotation issues: https://github.com/Telerik-Verified-Plugins/WKWebView/pull/263
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.webView?.setNeedsLayout()
            self.webView?.layoutIfNeeded()
        }, completion: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.navigationController?.setNavigationBarHidden(true, animated: false)

        // if we aren't showing a url or it's an incorrect url, update it -- otherwise, leave it alone
        if let connectionInfo = Current.settingsStore.connectionInfo,
            let webviewURL = connectionInfo.webviewURL(),
            webView.url == nil || webView.url?.baseIsEqual(to: webviewURL) == false {
            let myRequest: URLRequest

            if Current.settingsStore.restoreLastURL,
                let initialURL = initialURL, initialURL.baseIsEqual(to: webviewURL) {
                Current.Log.info("restoring initial url")
                myRequest = URLRequest(url: initialURL)
            } else {
                Current.Log.info("loading default url")
                myRequest = URLRequest(url: webviewURL)
            }

            self.webView.load(myRequest)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.navigationController?.setNavigationBarHidden(false, animated: false)
        self.userActivity?.resignCurrent()
    }

    deinit {
        self.urlObserver = nil
    }

    func styleUI() {
        precondition(isViewLoaded && webView != nil)

        let cachedColors = ThemeColors.cachedThemeColors

        self.webView?.backgroundColor = cachedColors[.primaryBackgroundColor]
        self.webView?.scrollView.backgroundColor = cachedColors[.primaryBackgroundColor]

        if let statusBarView = self.view.viewWithTag(111) {
            statusBarView.backgroundColor = cachedColors[.appHeaderBackgroundColor]
        }

        self.refreshControl.tintColor = cachedColors[.primaryColor]

        let headerBackgroundIsLight = cachedColors[.appHeaderBackgroundColor].isLight
        if #available(iOS 13, *) {
            self.underlyingPreferredStatusBarStyle = headerBackgroundIsLight ? .darkContent : .lightContent
        } else {
            self.underlyingPreferredStatusBarStyle = headerBackgroundIsLight ? .default : .lightContent
        }

        setNeedsStatusBarAppearanceUpdate()
    }

    public func open(inline url: URL) {
        loadViewIfNeeded()
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            openURLInBrowser(navigationAction.request.url!, self)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.refreshControl.endRefreshing()
        if let err = error as? URLError {
            if err.code != .cancelled {
                Current.Log.error("Failure during nav: \(err)")
            }

            if !error.isCancelled {
                openSettingsWithError(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.refreshControl.endRefreshing()
        if let err = error as? URLError {
            if err.code != .cancelled {
                Current.Log.error("Failure during content load: \(error)")
            }

            if !error.isCancelled {
                openSettingsWithError(error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.refreshControl.endRefreshing()

        // in case the view appears again, don't reload
        initialURL = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame else {
            // we don't need to modify the response if it's for a sub-frame
            decisionHandler(.allow)
            return
        }

        guard let httpResponse = navigationResponse.response as? HTTPURLResponse, httpResponse.statusCode >= 400 else {
            // not an error response, we don't need to inspect at all
            decisionHandler(.allow)
            return
        }

        // error response, let's inspect if it's restoring a page or normal navigation
        if navigationResponse.response.url != initialURL {
            // just a normal loading error
            decisionHandler(.allow)
        } else {
            // first: clear that saved url, it's bad
            initialURL = nil

            // it's for the restored page, let's load the default url

            if let connectionInfo = Current.settingsStore.connectionInfo,
                let webviewURL = connectionInfo.webviewURL() {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: webviewURL))
            } else {
                // we don't have anything we can do about this
                decisionHandler(.allow)
            }
        }
    }

    // WKUIDelegate
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let style: UIAlertController.Style = {
            switch webView.traitCollection.userInterfaceIdiom {
            case .carPlay, .phone, .tv:
                return .actionSheet
            case .pad, .unspecified:
                // without a touch to tell us where, an action sheet in the middle of the screen isn't great
                return .alert
            @unknown default:
                return .alert
            }
        }()

        let alertController = UIAlertController(title: nil, message: message, preferredStyle: style)

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Confirm.ok, style: .default, handler: { _ in
            completionHandler(true)
        }))

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Confirm.cancel, style: .cancel, handler: { _ in
            completionHandler(false)
        }))

        present(alertController, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alertController = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)

        alertController.addTextField { (textField) in
            textField.text = defaultText
        }

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Prompt.ok, style: .default, handler: { _ in
            if let text = alertController.textFields?.first?.text {
                completionHandler(text)
            } else {
                completionHandler(defaultText)
            }
        }))

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Prompt.cancel, style: .cancel, handler: { _ in
            completionHandler(nil)
        }))

        present(alertController, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)

        alertController.addAction(UIAlertAction(title: L10n.Alerts.Alert.ok, style: .default, handler: { _ in
            completionHandler()
        }))

        alertController.popoverPresentationController?.sourceView = self.webView
        present(alertController, animated: true, completion: nil)
    }

    @objc private func loadActiveURLIfNeeded() {
        guard let desiredURL = Current.settingsStore.connectionInfo?.webviewURL() else {
            return
        }

        guard webView.url == nil || webView.url?.baseIsEqual(to: desiredURL) == false else {
            Current.Log.info("not changing webview url - we're okay with what we have")
            // we also tell the webview -- maybe it failed to connect itself? -- to refresh if needed
            webView.evaluateJavaScript("checkForMissingHassConnectionAndReload()", completionHandler: nil)
            return
        }

        Current.Log.verbose("Changing webview to current active URL!")
        webView.load(URLRequest(url: desiredURL))
    }

    @objc func pullToRefresh(_ sender: UIRefreshControl) {
        if let webviewURL = Current.settingsStore.connectionInfo?.webviewURL() {
            self.webView.load(URLRequest(url: webviewURL))
        }
        firstly {
            HomeAssistantAPI.authenticatedAPIPromise
        }.then { api -> Promise<Void> in
            func updateWithoutLocation() -> Promise<Void> {
                return when(fulfilled: [
                    api.UpdateSensors(trigger: .Manual).asVoid(),
                    api.updateComplications().asVoid()
                ])
            }

            if Current.settingsStore.isLocationEnabled(for: UIApplication.shared.applicationState) {
                return UIApplication.shared.backgroundTask(withName: "manual-location-update") { remaining in
                    return api.GetAndSendLocation(trigger: .Manual, maximumBackgroundTime: remaining)
                        .recover { error -> Promise<Void> in
                            if error is CLError {
                                Current.Log.info("couldn't get location, sending remaining sensor data")
                                return updateWithoutLocation()
                            } else {
                                throw error
                            }
                    }
                }
            } else {
                return updateWithoutLocation()
            }
        }.catch {error in
            self.showSwiftMessageError((error as NSError).localizedDescription)
//            let message = L10n.ManualLocationUpdateFailedNotification.message(nserror.localizedDescription)
//            let alert = UIAlertController(title: L10n.ManualLocationUpdateFailedNotification.title,
//                                          message: message, preferredStyle: .alert)
//            alert.addAction(UIAlertAction(title: L10n.okLabel, style: .default, handler: nil))
//            self.navigationController?.present(alert, animated: true, completion: nil)
//            alert.popoverPresentationController?.sourceView = self.webView
        }
    }

    func showSwiftMessageError(_ body: String, duration: SwiftMessages.Duration = .automatic) {
        var config = SwiftMessages.Config()

        config.presentationContext = .window(windowLevel: .statusBar)
        config.duration = duration

        let view = MessageView.viewFromNib(layout: .statusLine)
        view.configureTheme(.error)
        view.configureContent(body: body)

        SwiftMessages.show(config: config, view: view)

    }

    func openSettingsWithError(error: Error) {
        self.showSwiftMessageError(error.localizedDescription, duration: SwiftMessages.Duration.seconds(seconds: 10))
        self.showSwiftMessageError(error.localizedDescription)

//        let alert = UIAlertController(title: L10n.errorLabel, message: error.localizedDescription,
//                                      preferredStyle: .alert)
//        alert.addAction(UIAlertAction(title: L10n.okLabel, style: UIAlertAction.Style.default, handler: nil))
//        self.navigationController?.present(alert, animated: true, completion: nil)
//        alert.popoverPresentationController?.sourceView = self.webView

        /* let settingsView = SettingsViewController()
        settingsView.showErrorConnectingMessage = true
        settingsView.showErrorConnectingMessageError = error
        settingsView.doneButton = true
        settingsView.delegate = self
        let navController = UINavigationController(rootViewController: settingsView)
        self.navigationController?.present(navController, animated: true, completion: nil) */
    }

    @objc func openSettingsView(_ sender: UIButton) {
        self.showSettingsViewController()
    }

    private var underlyingPreferredStatusBarStyle: UIStatusBarStyle = .lightContent
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return underlyingPreferredStatusBarStyle
    }

    func parseThemeStyle(_ styleKey: String, _ allStyles: [String: String]) -> UIColor? {
        guard let requestedStyle = allStyles[styleKey] else { return nil }

        if !requestedStyle.hasPrefix("var") {
            return UIColor(hex: requestedStyle)
        }

        // CSS variable like `var(--primary-text-color)` or `var(--primary-text-color, var(--secondary-text-color))`

        let pattern = "var\\(--([a-zA-Z-]+)\\)*"

        let styleKeys: [String] = requestedStyle.matchingStrings(regex: pattern).map { $0[1] }

        for key in styleKeys {
            if let color = self.parseThemeStyle(key, allStyles) {
                return color
            }
        }

        return nil
    }

    @objc private func updateWebViewSettings() {
        if #available(iOS 12, *) {
            // This is quasi-private API that has existed since pre-iOS 10, but the implementation
            // changed in iOS 12 to be like the +/- zoom buttons in Safari, which scale content without
            // resizing the scrolling viewport.
            let viewScale  = Current.settingsStore.pageZoom.viewScale
            Current.Log.info("setting view scale to \(viewScale)")
            webView.setValue(viewScale, forKey: "viewScale")
        }
    }

    // swiftlint:disable:next function_body_length
    func showWhatsNew() {
        if Current.appConfiguration == .FastlaneSnapshot { return }
        let iconSize = CGSize(width: 100, height: 100)
        let iconColor = Constants.blue
        let major = WhatsNew.Version.current().major
        let minor = WhatsNew.Version.current().minor
        let whatsNew = WhatsNew(
            title: L10n.WhatsNew.title("\(major).\(minor)"),
            items: [
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.Donations.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.Donations.subtitle,
                    image: MaterialDesignIcons.currencyUsdIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.HomeAssistantCloudSupport.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.HomeAssistantCloudSupport.subtitle,
                    image: MaterialDesignIcons.cloudIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.ImprovedIntegration.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.ImprovedIntegration.subtitle,
                    image: MaterialDesignIcons.linkVariantIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.CriticalAlerts.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.CriticalAlerts.subtitle,
                    image: MaterialDesignIcons.alertIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.InAppNotificationCategoryEditor.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.InAppNotificationCategoryEditor.subtitle,
                    image: MaterialDesignIcons.bellRingIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.NotificationSounds.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.NotificationSounds.subtitle,
                    image: MaterialDesignIcons.volumeHighIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.WebViewCleanup.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.WebViewCleanup.subtitle,
                    image: MaterialDesignIcons.sprayIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.TodayWidget.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.TodayWidget.subtitle,
                    image: MaterialDesignIcons.widgetsIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.MoreData.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.MoreData.subtitle,
                    image: MaterialDesignIcons.databaseIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.Themes.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.Themes.subtitle,
                    image: MaterialDesignIcons.formatPaintIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.AppIcons.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.AppIcons.subtitle,
                    image: MaterialDesignIcons.imageFilterFramesIcon.image(ofSize: iconSize, color: iconColor)
                ),
                WhatsNew.Item(
                    title: L10n.WhatsNew.TwoDotZero.Items.AndSoMuchMore.title,
                    subtitle: L10n.WhatsNew.TwoDotZero.Items.AndSoMuchMore.subtitle,
                    image: MaterialDesignIcons.starCircleIcon.image(ofSize: iconSize, color: iconColor)
                )
            ]
        )

        var config = WhatsNewViewController.Configuration()
        config.apply(animation: .fade)

        config.titleView.secondaryColor = .init(
            startIndex: 13,
            length: 29,
            color: Constants.blue
        )

        var detailButton = WhatsNewViewController.DetailButton(
            title: L10n.WhatsNew.Buttons.ReadMore.title,
            action: .website(url: "https://companion.home-assistant.io/app/ios/whats-new")
        )

        detailButton.titleColor = Constants.blue
        detailButton.hapticFeedback = .impact(.medium)

        config.detailButton = detailButton

        let completionButton = WhatsNewViewController.CompletionButton(
            title: L10n.WhatsNew.Buttons.Completion.title,
            action: .custom(action: { [weak self] whatsNewVC in
                let alert = UIAlertController(title: L10n.WhatsNew.TwoDotZero.ThankYou.title,
                                              message: L10n.WhatsNew.TwoDotZero.ThankYou.message,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.WhatsNew.TwoDotZero.ThankYou.okButton, style: .default,
                                              handler: { _ in
                                                self?.dismiss(animated: true, completion: nil)
                }))
                whatsNewVC.present(alert, animated: true, completion: nil)
                alert.popoverPresentationController?.sourceView = whatsNewVC.view
            })
        )

        config.completionButton = completionButton

        config.completionButton.backgroundColor = Constants.blue
        config.completionButton.hapticFeedback = .impact(.medium)

        let versionStore = KeyValueWhatsNewVersionStore(keyValueable: prefs)

        guard let whatsNewViewController = WhatsNewViewController(whatsNew: whatsNew,
                                                                  configuration: config,
                                                                  versionStore: versionStore) else { return }

        self.present(whatsNewViewController, animated: true)
    }
}

extension String {
    func matchingStrings(regex: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: regex, options: []) else { return [] }
        let nsString = self as NSString
        let results = regex.matches(in: self, options: [], range: NSRange(location: 0, length: nsString.length))
        return results.map { result in
            (0..<result.numberOfRanges).map {
                result.range(at: $0).location != NSNotFound
                    ? nsString.substring(with: result.range(at: $0))
                    : ""
            }
        }
    }
}

extension WebViewController: WKScriptMessageHandler {
    // swiftlint:disable:next function_body_length
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let messageBody = message.body as? [String: Any] else { return }

        // Current.Log.verbose("Received script message \(message.name) \(message.body)")

        /* if message.name == "mediaPlayerCommand" {
            guard let cmdStr = messageBody["type"] as? String, let cmd = RemotePlayerCommands(rawValue: cmdStr) else {
                Current.Log.error("No command type in payload! \(messageBody)")
                return
            }
            self.remotePlayer.handleCommand(cmd, messageBody["data"])
        } else */ if message.name == "externalBus" {
            self.handleExternalMessage(messageBody)
        } else if message.name == "currentUser", let user = AuthenticatedUser(messageBody) {
            Current.settingsStore.authenticatedUser = user
        } else if message.name == "updateThemeColors" {
            self.handleThemeUpdate(messageBody)
        } else if message.name == "getExternalAuth", let callbackName = messageBody["callback"] {
            let force = messageBody["force"] as? Bool ?? false
            if let tokenManager = Current.tokenManager {
                Current.Log.verbose("getExternalAuth called, forced: \(force)")
                tokenManager.authDictionaryForWebView(forceRefresh: force).done { dictionary in
                    let jsonData = try? JSONSerialization.data(withJSONObject: dictionary, options: [])
                    if let jsonString = String(data: jsonData!, encoding: .utf8) {
                        // swiftlint:disable:next line_length
                        // Current.Log.verbose("Responding to getExternalAuth with: \(callbackName)(true, \(jsonString))")
                        let script = "\(callbackName)(true, \(jsonString))"
                        self.webView.evaluateJavaScript(script, completionHandler: { (result, error) in
                            if let error = error {
                                Current.Log.error("Failed to trigger getExternalAuth callback: \(error)")
                            }

                            Current.Log.verbose("Success on getExternalAuth callback: \(String(describing: result))")
                        })
                    }
                }.catch { error in
                    self.webView.evaluateJavaScript("\(callbackName)(false, 'Token unavailable')")
                    Current.Log.error("Failed to authenticate webview: \(error)")
                }
            } else {
                self.webView.evaluateJavaScript("\(callbackName)(false, 'Token unavailable')")
                Current.Log.error("Failed to authenticate webview. Token Unavailable")
            }
        } else if message.name == "revokeExternalAuth", let callbackName = messageBody["callback"],
            let tokenManager = Current.tokenManager {

            Current.Log.warning("Revoking access token")

            tokenManager.revokeToken().done { _ in
                Current.tokenManager = nil
                Current.settingsStore.connectionInfo = nil
                Current.settingsStore.tokenInfo = nil
                let script = "\(callbackName)(true)"

                Current.Log.verbose("Running revoke external auth callback \(script)")

                self.webView.evaluateJavaScript(script, completionHandler: { (_, error) in
                    Current.signInRequiredCallback?(.logout)

                    if let error = error {
                        Current.Log.error("Failed calling sign out callback: \(error)")
                    }

                    Current.Log.verbose("Successfully informed web client of log out.")
                })
            }.catch { error in
                Current.Log.error("Failed to revoke token: \(error)")
            }
        }
    }

    func handleThemeUpdate(_ messageBody: [String: Any]) {
        ThemeColors.updateCache(with: messageBody)
        styleUI()
    }

    func handleHaptic(_ hapticType: String) {
        Current.Log.verbose("Handle haptic type \(hapticType)")
        switch hapticType {
        case "success":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "error", "failure":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "warning":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy":
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        default:
            Current.Log.verbose("Unknown haptic type \(hapticType)")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handleExternalMessage(_ dictionary: [String: Any]) {
        guard let incomingMessage = WebSocketMessage(dictionary) else {
            Current.Log.error("Received invalid external message \(dictionary)")
            return
        }

        // Current.Log.verbose("Received external bus message \(incomingMessage)")

        var response: WebSocketMessage?

        switch incomingMessage.MessageType {
        case "config/get":
            response = WebSocketMessage(id: incomingMessage.ID!, type: "result", result: ["hasSettingsScreen": true])
        case "config_screen/show":
            self.showSettingsViewController()
        case "haptic":
            guard let hapticType = incomingMessage.Payload?["hapticType"] as? String else {
                Current.Log.error("Received haptic via bus but hapticType was not string! \(incomingMessage)")
                return
            }
            self.handleHaptic(hapticType)
        case "connection-status":
            guard let connEvt = incomingMessage.Payload?["event"] as? String else {
                Current.Log.error("Received connection-status via bus but event was not string! \(incomingMessage)")
                return
            }
            // Possible values: connected, disconnected, auth-invalid
            UIView.animate(withDuration: 1.0, delay: 0, options: .curveEaseInOut, animations: {
                self.settingsButton.alpha = connEvt == "connected" ? 0.0 : 1.0
            }, completion: nil)
        default:
            Current.Log.error("Received unknown external message \(incomingMessage)")
            return
        }

        if let outgoing = response {
            // Current.Log.verbose("Sending response to \(outgoing)")

            var encodedMsg: Data?

            do {
                encodedMsg = try JSONEncoder().encode(outgoing)
            } catch let error as NSError {
                Current.Log.error("Unable to encode outgoing message! \(error)")
                return
            }

            guard let jsonString = String(data: encodedMsg!, encoding: .utf8) else {
                Current.Log.error("Could not convert JSON Data to JSON String")
                return
            }

            let script = "window.externalBus(\(jsonString))"
            // Current.Log.verbose("Sending message to externalBus \(script)")
            self.webView.evaluateJavaScript(script, completionHandler: { (_, error) in
                if let error = error {
                    Current.Log.error("Failed to fire message to externalBus: \(error)")
                }

                /* if let result = result {
                    Current.Log.verbose("Success on firing message to externalBus: \(String(describing: result))")
                } else {
                    Current.Log.verbose("Sent message to externalBus")
                } */
            })
        }

    }
}

extension WebViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset.y > scrollView.contentSize.height - scrollView.bounds.height {
            scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
        }
    }
}

/* extension WebViewController: RemoteMediaPlayerDelegate {
    func sendStatus(_ state: RemotePlayerState) {
        guard let webhookID = Current.settingsStore.connectionInfo?.webhookID else {
            Current.Log.error("Unable to get webhookID!")
            return
        }
        var jsonStr: String = "{}"
        do {
            let data = try JSONEncoder().encode(state)
            jsonStr = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Current.Log.error("Error while encoding RemotePlayerState: \(error)")
            return
        }
        // swiftlint:disable:next line_length
        let script = "window.activeHassConnection.sendMessage({type: 'mobile_app/update_media_player_state', webhook_id: '\(webhookID)', player_state: \(jsonStr)});"
        Current.Log.verbose("Sending message \(script)")
        self.webView.evaluateJavaScript(script, completionHandler: { (result, error) in
            if let error = error {
                Current.Log.error("Failed to update player state: \(error)")
                return
            }

            Current.Log.verbose("Success when updating player state: \(String(describing: result))")
        })
    }

    func showPlayer(_ playerViewController: AVPlayerViewController) {
        // https://stackoverflow.com/a/40739474/486182
        self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { (_) in
            self.webView.evaluateJavaScript("1+1", completionHandler: nil)
        }
        self.present(playerViewController, animated: true) {
            Current.Log.verbose("Playing!")
            playerViewController.player?.play()
        }
    }

    func donePlaying() {
        self.keepAliveTimer?.invalidate()
    }

} */

extension ConnectionInfo {
    func webviewURL() -> URL? {
        if Current.appConfiguration == .FastlaneSnapshot, prefs.object(forKey: "useDemo") != nil {
            return URL(string: "https://companion.home-assistant.io/app/ios/demo")!
        }
        guard var components = URLComponents(url: self.activeURL, resolvingAgainstBaseURL: true) else {
            return nil
        }

        if Current.settingsStore.tokenInfo != nil {
            let queryItem = URLQueryItem(name: "external_auth", value: "1")
            components.queryItems = [queryItem]
        }

        return try? components.asURL()
    }

    func webviewURL(from raw: String) -> URL? {
        guard let baseURL = webviewURL() else {
            return nil
        }

        if raw.starts(with: "/") {
            return baseURL.appendingPathComponent(raw)
        } else if let url = URL(string: raw), url.baseIsEqual(to: baseURL) {
            return url
        } else {
            return nil
        }
    }
// swiftlint:disable:next file_length
}
