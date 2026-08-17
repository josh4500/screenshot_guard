import Flutter
import UIKit
import Photos

public class ScreenshotShieldPlugin: NSObject, FlutterPlugin, ScreenshotShieldHostApi, PHPhotoLibraryChangeObserver {
    private static let screenshotCreationWindow: TimeInterval = 5
    private static let sizeTolerance: CGFloat = 8

    private let streamHandler = ScreenshotShieldStreamHandler()
    private var assetFetchResult: PHFetchResult<PHAsset>?
    private var isObserving = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let instance = ScreenshotShieldPlugin()
        ScreenshotShieldHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
        OnScreenshotDetectedStreamHandler.register(with: messenger, streamHandler: instance.streamHandler)
    }

    // MARK: - ScreenshotShieldHostApi

    public func startListening() throws {
        guard !isObserving else { return }
        requestPhotoLibraryAccess { [weak self] granted in
            guard let self, granted else { return }
            self.beginObserving()
        }
    }

    public func stopListening() throws {
        stopObserving()
    }

    public func setProtected(protected: Bool) throws {
        // iOS has no public API to prevent screenshots, so this is a no-op.
    }

    // MARK: - Private

    private func requestPhotoLibraryAccess(completion: @escaping (Bool) -> Void) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                completion(status == .authorized || status == .limited)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                completion(status == .authorized)
            }
        }
    }

    private func beginObserving() {
        guard !isObserving else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assetFetchResult = PHAsset.fetchAssets(with: .image, options: options)
        isObserving = true
        PHPhotoLibrary.shared().register(self)
    }

    private func stopObserving() {
        guard isObserving else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        assetFetchResult = nil
        isObserving = false
    }

    private func isScreenshot(_ asset: PHAsset) -> Bool {
        guard
            asset.mediaType == .image,
            let creationDate = asset.creationDate,
            Date().timeIntervalSince(creationDate) < Self.screenshotCreationWindow
        else {
            return false
        }
        let screenSize = UIScreen.main.nativeBounds.size
        let assetSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        let matchesPortrait = abs(assetSize.width - screenSize.width) < Self.sizeTolerance
            && abs(assetSize.height - screenSize.height) < Self.sizeTolerance
        let matchesLandscape = abs(assetSize.width - screenSize.height) < Self.sizeTolerance
            && abs(assetSize.height - screenSize.width) < Self.sizeTolerance
        return matchesPortrait || matchesLandscape
    }

    // MARK: - PHPhotoLibraryChangeObserver

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard
            let assetFetchResult,
            let changes = changeInstance.changeDetails(for: assetFetchResult),
            !changes.insertedObjects.isEmpty
        else {
            return
        }
        for asset in changes.insertedObjects where isScreenshot(asset) {
            streamHandler.emitScreenshotDetected()
            return
        }
    }
}

class ScreenshotShieldStreamHandler: OnScreenshotDetectedStreamHandler {
    private var eventSink: PigeonEventSink<Int64>?

    override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<Int64>) {
        eventSink = sink
    }

    override func onCancel(withArguments arguments: Any?) {
        eventSink = nil
    }

    func emitScreenshotDetected() {
        eventSink?.success(0)
    }
}
