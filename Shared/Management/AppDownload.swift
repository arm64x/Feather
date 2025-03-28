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

class AppDownload: NSObject {
    private let fileQueue = DispatchQueue(label: "com.feather.fileProcessing", attributes: .concurrent)
    private let fileManager = FileManager.default
    private let session: URLSession
    
    weak var dldelegate: DownloadDelegate?
    
    private var activeDownloads: [URLSessionDownloadTask: (
        uuid: String, 
        appuuid: String, 
        destinationUrl: URL, 
        completion: (String?, String?, Error?) -> Void
    )] = [:]
    
    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30  // Timeout after 30 seconds
        config.timeoutIntervalForResource = 300  // Total resource timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.networkServiceType = .background
        
        session = URLSession(configuration: config)
        super.init()
    }
    
    func downloadFile(
        url: URL, 
        appuuid: String, 
        completion: @escaping (String?, String?, Error?) -> Void
    ) {
        let uuid = UUID().uuidString
        
        guard let folderUrl = createUuidDirectory(uuid: uuid) else {
            completion(nil, nil, NSError(
                domain: "AppDownload", 
                code: -1, 
                userInfo: [NSLocalizedDescriptionKey: "Failed to create directory"]
            ))
            return
        }
        
        let destinationUrl = folderUrl.appendingPathComponent(url.lastPathComponent)
        let task = session.downloadTask(with: url) { [weak self] localURL, response, error in
            guard let self = self, let localURL = localURL else {
                completion(nil, nil, error)
                return
            }
            
            do {
                try self.fileManager.moveItem(at: localURL, to: destinationUrl)
                completion(uuid, destinationUrl.path, nil)
            } catch {
                completion(nil, nil, error)
            }
        }
        
        activeDownloads[task] = (uuid: uuid, appuuid: appuuid, destinationUrl: destinationUrl, completion: completion)
        task.resume()
    }
    
    func importFile(
        url: URL, 
        uuid: String, 
        completion: @escaping (URL?, Error?) -> Void
    ) {
        fileQueue.async(flags: .barrier) {
            do {
                guard let folderUrl = self.createUuidDirectory(uuid: uuid) else {
                    throw NSError(
                        domain: "AppDownload", 
                        code: -1, 
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create directory"]
                    )
                }
                
                let fileName = url.lastPathComponent
                let destinationUrl = folderUrl.appendingPathComponent(fileName)
                
                try self.fileManager.moveItem(at: url, to: destinationUrl)
                DispatchQueue.main.async {
                    completion(destinationUrl, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
    
    func extractCompressedBundle(
        packageURL: String, 
        completion: @escaping (String?, Error?) -> Void
    ) {
        fileQueue.async {
            let fileURL = URL(fileURLWithPath: packageURL)
            let destinationURL = fileURL.deletingLastPathComponent()
            
            do {
                try self.fileManager.unzipItem(at: fileURL, to: destinationURL)
                
                let payloadURL = destinationURL.appendingPathComponent("Payload")
                let contents = try self.fileManager.contentsOfDirectory(
                    at: payloadURL, 
                    includingPropertiesForKeys: nil, 
                    options: []
                )
                
                guard let appDirectory = contents.first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(
                        domain: "AppDownload", 
                        code: -2, 
                        userInfo: [NSLocalizedDescriptionKey: "No .app directory found"]
                    )
                }
                
                let targetURL = destinationURL.appendingPathComponent(appDirectory.lastPathComponent)
                try self.fileManager.moveItem(at: appDirectory, to: targetURL)
                try self.fileManager.removeItem(at: payloadURL)
                
                let codeSignatureDirectory = targetURL.appendingPathComponent("_CodeSignature")
                if self.fileManager.fileExists(atPath: codeSignatureDirectory.path) {
                    try self.fileManager.removeItem(at: codeSignatureDirectory)
                }
                
                try self.fileManager.removeItem(at: fileURL)
                
                DispatchQueue.main.async {
                    completion(targetURL.path, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
    
    func addToApps(
        bundlePath: String, 
        uuid: String, 
        sourceLocation: String? = nil, 
        completion: @escaping (Error?) -> Void
    ) {
        guard let bundle = Bundle(path: bundlePath) else {
            let error = NSError(
                domain: "Feather", 
                code: 1, 
                userInfo: [NSLocalizedDescriptionKey: "Failed to load bundle"]
            )
            completion(error)
            return
        }
        
        guard let infoDict = bundle.infoDictionary else {
            let error = NSError(
                domain: "Feather", 
                code: 3, 
                userInfo: [NSLocalizedDescriptionKey: "Info.plist not found"]
            )
            completion(error)
            return
        }
        
        let iconURL = extractAppIcon(from: bundle, infoDict: infoDict)
        
        CoreDataManager.shared.addToDownloadedApps(
            version: infoDict["CFBundleShortVersionString"] as? String ?? "",
            name: (infoDict["CFBundleDisplayName"] as? String ?? infoDict["CFBundleName"] as? String) ?? "",
            bundleidentifier: infoDict["CFBundleIdentifier"] as? String ?? "",
            iconURL: iconURL,
            uuid: uuid,
            appPath: (URL(string: bundlePath)?.lastPathComponent) ?? "",
            sourceLocation: sourceLocation
        ) { _ in
            completion(nil)
        }
    }
    
    private func extractAppIcon(from bundle: Bundle, infoDict: [String: Any]) -> String {
        let iconFileCandidates = [
            { () -> String? in
                guard let iconsDict = infoDict["CFBundleIcons"] as? [String: Any],
                      let primaryIconsDict = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                      let iconFiles = primaryIconsDict["CFBundleIconFiles"] as? [String],
                      let iconFileName = iconFiles.first else { return nil }
                return bundle.path(forResource: iconFileName + "@2x", ofType: "png")
            },
            { () -> String? in
                guard let iconFiles = infoDict["CFBundleIconFiles"] as? [String],
                      let iconFileName = iconFiles.first else { return nil }
                return bundle.path(forResource: iconFileName + "@2x", ofType: "png") ??
                       bundle.path(forResource: iconFileName, ofType: "png")
            }
        ]
        
        for candidate in iconFileCandidates {
            if let iconPath = candidate() {
                return URL(string: iconPath)?.lastPathComponent ?? ""
            }
        }
        
        return ""
    }
    
    private func createUuidDirectory(uuid: String) -> URL? {
        let baseFolder = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderUrl = baseFolder.appendingPathComponent("Apps/Unsigned").appendingPathComponent(uuid)
        
        do {
            try fileManager.createDirectory(at: folderUrl, withIntermediateDirectories: true)
            return folderUrl
        } catch {
            return nil
        }
    }
}

// Error handling helper
enum HandleIPAFileError: Error {
    case importFailed(String)
    case extractionFailed(String)
    case additionFailed(String)
}

func handleIPAFile(
    destinationURL: URL, 
    uuid: String, 
    dl: AppDownload
) throws {
    let group = DispatchGroup()
    var functionError: Error?
    
    group.enter()
    dl.importFile(url: destinationURL, uuid: uuid) { resultUrl, error in
        defer { group.leave() }
        
        guard error == nil, let validNewUrl = resultUrl else {
            functionError = HandleIPAFileError.importFailed(
                error?.localizedDescription ?? "No URL returned from import"
            )
            return
        }
        
        group.enter()
        dl.extractCompressedBundle(packageURL: validNewUrl.path) { bundle, error in
            defer { group.leave() }
            
            guard error == nil, let validTargetBundle = bundle else {
                functionError = HandleIPAFileError.extractionFailed(
                    error?.localizedDescription ?? "No bundle returned from extraction"
                )
                return
            }
            
            group.enter()
            dl.addToApps(bundlePath: validTargetBundle, uuid: uuid, sourceLocation: "Imported") { error in
                defer { group.leave() }
                
                if let error = error {
                    functionError = HandleIPAFileError.additionFailed(error.localizedDescription)
                }
            }
        }
    }
    
    group.wait()
    
    if let error = functionError {
        Debug.shared.log(message: error.localizedDescription, type: .error)
        throw error
    } else {
        DispatchQueue.main.async {
            Debug.shared.log(message: "Done!", type: .success)
            NotificationCenter.default.post(name: Notification.Name("lfetch"), object: nil)
        }
    }
}
