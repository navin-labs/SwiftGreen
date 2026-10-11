//
//  mDNSServicePublisher.swift
//  SwiftGreen
//
//  Created by Navin Rana on 27/05/26.
//

import Foundation
import Combine

class mDNSServicePublisher: NSObject, ObservableObject {
    @Published var isAdvertising = false
    @Published var statusMessage = "Stopped"
    @Published var publishedName: String?
    
    private var netService: NetService?
    
    func startAdvertising(serviceType: String = "_swiftgreen._tcp.", port: Int32) {
        guard port > 0 else {
            print("Publisher: ERROR - Cannot start advertising with an unknown or invalid port (port: \(port)). Never start advertising before the listener port is known.")
            return
        }
        
        guard !isAdvertising && netService == nil else {
            print("Publisher: Already advertising or active. Ignoring request to start.")
            return
        }
        
        // domain: "local." makes it advertise specifically on the local network via multicast DNS.
        // type: the service type, e.g. "_swiftgreen._tcp."
        // name: an empty string instructs the system to automatically use the computer's name.
        // port: port on which our sync server listens
        let service = NetService(domain: "local.", type: serviceType, name: "", port: port)
        service.delegate = self
        
        // Publish the service without listenForConnections options to prevent port binding conflict
        service.publish()
        
        self.netService = service
        self.isAdvertising = true
        self.statusMessage = "Publishing service on port \(port)..."
    }
    
    func stopAdvertising() {
        if let service = netService {
            service.stop()
            netService = nil
        }
        isAdvertising = false
        statusMessage = "Stopped"
        publishedName = nil
    }
}

// MARK: - NetServiceDelegate
extension mDNSServicePublisher: NetServiceDelegate {
    
    func netServiceWillPublish(_ sender: NetService) {
        DispatchQueue.main.async {
            self.statusMessage = "Publishing..."
        }
    }
    
    func netServiceDidPublish(_ sender: NetService) {
        DispatchQueue.main.async {
            self.isAdvertising = true
            self.publishedName = sender.name
            self.statusMessage = "Successfully advertising '\(sender.name)' on port \(sender.port)"
        }
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        DispatchQueue.main.async {
            self.isAdvertising = false
            let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue ?? -1
            self.statusMessage = "Failed to publish. Error code: \(errorCode)"
            self.netService = nil
        }
    }
    
    func netServiceDidStop(_ sender: NetService) {
        DispatchQueue.main.async {
            self.isAdvertising = false
            self.statusMessage = "Stopped"
            self.publishedName = nil
            self.netService = nil
        }
    }
}
