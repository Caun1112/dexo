//
//  AppDelegate.swift
//  dexo
//
//  Created by Eilgnaw on 3/21/26.
//

import Lightbox
import SDWebImage
import SDWebImageSVGCoder
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if !EncryptedDNSManager.shared.applyCurrentSettings() {
            AppSettings.shared.dohEnabled = false
        }

        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)

        // One-time: clear legacy shared cache (all images now use per-type caches)
        if !UserDefaults.standard.bool(forKey: "legacyCacheCleared") {
            SDImageCache.shared.clearDisk {
                UserDefaults.standard.set(true, forKey: "legacyCacheCleared")
            }
        }

        LightboxConfig.loadImage = { imageView, url, completion in
            // Browser URLs point at the Discourse lightbox href (original
            // asset), not the inline thumbnail src. Refreshing the cache here
            // prevents an earlier low-resolution response for an equivalent
            // key from remaining on screen when the user zooms in.
            imageView.sd_setImage(
                with: url,
                placeholderImage: nil,
                options: [.retryFailed, .highPriority, .refreshCached],
                context: ImageCacheManager.shared.contentContext,
                progress: nil
            ) { image, _, _, _ in
                completion?(image)
            }
        }
        LightboxConfig.preload = 2
        LightboxConfig.makeLoadingIndicator = {
            let indicator = UIActivityIndicatorView(style: .large)
            indicator.color = .white
            indicator.startAnimating()
            return indicator
        }
        // ImageBrowserController draws its own dot-style page indicator.
        LightboxConfig.PageIndicator.enabled = false

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}
