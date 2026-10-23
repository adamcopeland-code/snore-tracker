import UIKit
import Capacitor

/// The web view controller of the app. It registers the local SnoreMic plugin, which is not an npm package.
class SnoreBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(SnoreMicPlugin())
    }
}
