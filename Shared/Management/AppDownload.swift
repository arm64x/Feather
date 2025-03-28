//
//  SourceAppDownload.swift
//  feather
//
//  Created by samara on 7/9/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import ZIPFoundation
import UIKit
import CoreData

@available(iOS 15.0, *)
class AppDownload: NSObject {
    private let downloadQueue = OperationQueue()
    private let fileManager = FileManager.default
    private var downloadTasks: [URLSessionDownloadTask: AppDownloadInfo] = [:]
    
    struct AppDownloadInfo {
        let appUUID: String
        let destinationURL: URL
        let completion: (String?, String?, Error?) -> Void
    }
    
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    func downloadFile(url: URL, appUUID: String) async throws -> (String, URL) {
        let uuid = UUID().uuidString
        let destinationFolder = try createUuidDirectory(uuid: uuid)
        let destinationURL = destinationFolder.appendingPathComponent(url.lastPathComponent)
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = downloadSession.downloadTask(with: url) { [weak self] location, response, error in
                guard let self = self, let location = location else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                    return
                }
                
                do {
                    try self.fileManager.moveItem(at: location, to: destinationURL)
                    continuation.resume(returning: (uuid, destinationURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            task.resume()
        }
    }
    
    func extractCompressedBundle(packageURL: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: packageURL)
        let destinationURL = fileURL.deletingLastPathComponent()
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "File does not exist"])
        }
        
        let progress = Progress(totalUnitCount: 100)
        let startTime = Date()
        
        try fileManager.unzipItem(at: fileURL, to: destinationURL, progress: progress)
        
        print("⏱️ Unzip duration: \(Date().timeIntervalSince(startTime))s")
        
        guard !progress.isCancelled else {
            try? fileManager.removeItem(at: destinationURL)
            throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unzip operation was cancelled"])
        }
        
        try fileManager.removeItem(at: fileURL)
        
        let payloadURL = destinationURL.appendingPathComponent("Payload")
        let contents = try fileManager.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil)
        
        guard let appDirectory = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No .app directory found in Payload"])
        }
        
        let targetURL = destinationURL.appendingPathComponent(appDirectory.lastPathComponent)
        try fileManager.moveItem(at: appDirectory, to: targetURL)
        try fileManager.removeItem(at: payloadURL)
        
        let codeSignatureDirectory = targetURL.appendingPathComponent("_CodeSignature")
        if fileManager.fileExists(atPath: codeSignatureDirectory.path) {
            try fileManager.removeItem(at: codeSignatureDirectory)
            Debug.shared.log(message: "Removed _CodeSignature directory")
        }
        
        return targetURL.path
    }
    
    func addToApps(bundlePath: String, uuid: String, sourceLocation: String? = nil) async throws {
        guard let bundle = Bundle(path: bundlePath),
              let infoDict = bundle.infoDictionary else {
            throw NSError(domain: "Feather", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bundle or Info.plist not found"])
        }
        
        let iconURL = extractIconURL(from: infoDict, in: bundle)
        
        guard let version = infoDict["CFBundleShortVersionString"] as? String,
              let name = (infoDict["CFBundleDisplayName"] as? String) ?? (infoDict["CFBundleName"] as? String),
              let bundleIdentifier = infoDict["CFBundleIdentifier"] as? String else {
            throw NSError(domain: "Feather", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing required bundle info"])
        }
        
        try await CoreDataManager.shared.addToDownloadedAppsAsync(
            version: version,
            name: name,
            bundleidentifier: bundleIdentifier,
            iconURL: iconURL,
            uuid: uuid,
            appPath: "\(URL(string: bundlePath)?.lastPathComponent ?? "")",
            sourceLocation: sourceLocation
        )
    }
    
    private func extractIconURL(from infoDict: [String: Any], in bundle: Bundle) -> String {
        if let iconsDict = infoDict["CFBundleIcons"] as? [String: Any],
           let primaryIconsDict = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIconsDict["CFBundleIconFiles"] as? [String],
           let iconFileName = iconFiles.first,
           let iconPath = bundle.path(forResource: iconFileName + "@2x", ofType: "png") {
            return "\(URL(string: iconPath)?.lastPathComponent ?? "")"
        }
        
        if let iconFiles = infoDict["CFBundleIconFiles"] as? [String],
           let iconFileName = iconFiles.first,
           let iconPath = bundle.path(forResource: iconFileName + "@2x", ofType: "png") ??
                           bundle.path(forResource: iconFileName, ofType: "png") {
            return "\(URL(string: iconPath)?.lastPathComponent ?? "")"
        }
        
        return ""
    }
    
    func createUuidDirectory(uuid: String) throws -> URL {
        let baseFolder = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderUrl = baseFolder.appendingPathComponent("Apps/Unsigned").appendingPathComponent(uuid)
        
        try fileManager.createDirectory(at: folderUrl, withIntermediateDirectories: true)
        return folderUrl
    }
}

// Async/Await version of handleIPAFile
@available(iOS 15.0, *)
func handleIPAFile(destinationURL: URL, uuid: String, dl: AppDownload) async throws {
    do {
        let importedURL = try await dl.downloadFile(url: destinationURL, appUUID: uuid)
        let extractedBundle = try await dl.extractCompressedBundle(packageURL: importedURL.1.path)
        try await dl.addToApps(bundlePath: extractedBundle, uuid: uuid, sourceLocation: "Imported")
        
        DispatchQueue.main.async {
            Debug.shared.log(message: "Done!", type: .success)
            NotificationCenter.default.post(name: Notification.Name("lfetch"), object: nil)
        }
    } catch {
        Debug.shared.log(message: error.localizedDescription, type: .error)
        throw error
    }
}
