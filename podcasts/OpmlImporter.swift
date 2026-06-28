import Foundation
import PocketCastsDataModel
import PocketCastsServer

class OpmlImporter: Operation, XMLParserDelegate, @unchecked Sendable {
    private let opmlFileUrl: URL
    private let progressWindow: ShiftyLoadingAlert?

    private var initialPodcastCount = 0
    private var importedCount = 0

    lazy var importQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 5

        return queue
    }()

    private var parsedUrls = [String]()

    init(opmlFile: URL, progressWindow: ShiftyLoadingAlert? = nil) {
        opmlFileUrl = opmlFile
        self.progressWindow = progressWindow

        super.init()
    }

    override func main() {
        autoreleasepool {
            Analytics.track(.opmlImportStarted)
            // parse OPML file
            let parser = XMLParser(contentsOf: opmlFileUrl)
            parser?.delegate = self
            guard let parsed = parser?.parse(), parsed, !parsedUrls.isEmpty else {
                DispatchQueue.main.sync {
                    if let progressWindow = self.progressWindow {
                        progressWindow.hideAlert(false)
                        let controller = SceneHelper.rootViewController()

                        SJUIUtils.showAlert(title: L10n.opmlImportFailedTitle, message: L10n.opmlImportFailedMessage, from: controller)
                    } else {
                        NotificationCenter.postOnMainThread(notification: Constants.Notifications.opmlImportFailed)
                    }

                    Analytics.track(.opmlImportFailed)
                }

                return
            }

            // PodHopper: subscribe to each feed url directly through the client feed engine, on
            // device, with no Pocket Casts server resolving urls to uuids. Mirrors the Android
            // OPML import, which calls subscribeToFeedUrlBlocking per url.
            initialPodcastCount = parsedUrls.count
            importAllFeeds(urls: parsedUrls)

            DispatchQueue.main.async {
                if let progressWindow = self.progressWindow {
                    NavigationManager.sharedManager.navigateTo(NavigationManager.podcastListPageKey, data: nil)
                    progressWindow.hideAlert(true)
                }

                NotificationCenter.postOnMainThread(notification: Constants.Notifications.opmlImportCompleted)

                Analytics.track(.opmlImportFinished, properties: ["count": self.initialPodcastCount, "number_parsed": self.initialPodcastCount])
            }
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "outline", let url = attributeDict["xmlUrl"] else { return }

        let trimmedURL = url.trim()
        guard !trimmedURL.isEmpty else { return }

        parsedUrls.append(trimmedURL)
    }

    // MARK: - Add Podcasts

    private func importAllFeeds(urls: [String]) {
        for feedUrl in urls {
            importQueue.addOperation {
                PodHopperFeedManager.shared.subscribeToFeedUrl(feedUrl)
                self.importedCount += 1

                DispatchQueue.main.async {
                    guard let progressWindow = self.progressWindow else { return }
                    progressWindow.title = self.progress(imported: self.importedCount, total: self.initialPodcastCount)
                }
            }
        }

        importQueue.waitUntilAllOperationsAreFinished()
    }

    func progress(imported: Int, total: Int) -> String {
        L10n.opmlImportProgressFormat(imported.localized(), total.localized())
    }
}
