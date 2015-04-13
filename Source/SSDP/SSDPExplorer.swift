//
//  SSDPExplorer.swift
//
//  Copyright (c) 2015 David Robles
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
import CocoaAsyncSocket
import AFNetworking

protocol SSDPExplorerDelegate: class {
    func ssdpExplorer(explorer: SSDPExplorer, didMakeDiscovery discovery: SSDPDiscovery)
    // Removed discoveries will have an invalid desciption URL
    func ssdpExplorer(explorer: SSDPExplorer, didRemoveDiscovery discovery: SSDPDiscovery)    
    /// Assume explorer has stopped after a failure.
    func ssdpExplorer(explorer: SSDPExplorer, didFailWithError error: NSError)
}

class SSDPExplorer {
    enum SSDPMessageType {
        case SearchResponse
        case AvailableNotification
        case UpdateNotification
        case UnavailableNotification
    }
    
    weak var delegate: SSDPExplorerDelegate?
    
    // private
    private static let _multicastGroupAddress = "239.255.255.250"
    private static let _multicastUDPPort: UInt16 = 1900
    private var _socket: GCDAsyncUdpSocket? // TODO: Should ideally be a constant, see Github issue #10
    
    func startExploring(forTypes types: Set<SSDPType>) -> EmptyResult {
        assert(_socket == nil, "Socket is already open, stop it first!")
        
        let socket: GCDAsyncUdpSocket! = GCDAsyncUdpSocket(delegate: self, delegateQueue: dispatch_get_main_queue())
        if socket == nil {
            return .Failure(createError("Socket could not be created"))
        }
        else {
            _socket = socket
        }
        socket.setIPv6Enabled(false)
        
        var error: NSError?
        if !socket.bindToPort(SSDPExplorer._multicastUDPPort, error: &error) {
            stopExploring()
            return .Failure(error ?? createError("Could not bind socket to port"))
        }
        
        if !socket.joinMulticastGroup(SSDPExplorer._multicastGroupAddress, error: &error) {
            stopExploring()
            return .Failure(error ?? createError("Could not join multicast group"))
        }
        
        if !socket.beginReceiving(&error) {
            stopExploring()
            return .Failure(error ?? createError("Could not begin receiving error"))
        }
        
        for type in types {
            if let data = searchRequestData(forType: type) {
                socket.sendData(data, toHost: SSDPExplorer._multicastGroupAddress, port: SSDPExplorer._multicastUDPPort, withTimeout: -1, tag: CLong(type.hashValue))
            }
        }
        
        return .Success
    }
    
    func stopExploring() {
        _socket?.close()
        _socket = nil
    }
    
    private func searchRequestData(forType type: SSDPType) -> NSData? {
        var requestBody = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(SSDPExplorer._multicastGroupAddress):\(SSDPExplorer._multicastUDPPort)",
            "MAN: \"ssdp:discover\"",
            "ST: \(type.rawValue)",
            "MX: 3"]
        
        if let userAgent = AFHTTPRequestSerializer().valueForHTTPHeaderField("User-Agent") {
            requestBody += ["USER-AGENT: \(userAgent)"]
        }
        
        let requestBodyString = join("\r\n", requestBody)
        return requestBodyString.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)
    }
    
    private func notifyDelegate(ofFailure error: NSError) {
        dispatch_async(dispatch_get_main_queue(), { [unowned self] () -> Void in
            self.delegate?.ssdpExplorer(self, didFailWithError: error)
        })
    }
    
    private func notifyDelegate(discovery: SSDPDiscovery, added: Bool) {
        dispatch_async(dispatch_get_main_queue(), { [unowned self] () -> Void in
            added ? self.delegate?.ssdpExplorer(self, didMakeDiscovery: discovery) : self.delegate?.ssdpExplorer(self, didRemoveDiscovery: discovery)
            })
    }
    
    private func handleSSDPMessage(messageType: SSDPMessageType, headers: [String: String]) {
        if let usnRawValue = headers["usn"],
            usn = UniqueServiceName(rawValue: usnRawValue),
            locationString = headers["location"],
            locationURL = NSURL(string: locationString),
            ssdpTypeRawValue = (headers["st"] != nil ? headers["st"] : headers["nt"]),
            ssdpType = SSDPType(rawValue: ssdpTypeRawValue) {
                let discovery = SSDPDiscovery(usn: usn, descriptionURL: locationURL, type: ssdpType)
                switch messageType {
                case .SearchResponse, .AvailableNotification, .UpdateNotification:
                    notifyDelegate(discovery, added: true)
                case .UnavailableNotification:
                    notifyDelegate(discovery, added: false)
                }
        }
    }
}

extension SSDPExplorer: GCDAsyncUdpSocketDelegate {
    @objc func udpSocket(sock: GCDAsyncUdpSocket!, didNotSendDataWithTag tag: Int, dueToError error: NSError!) {
        stopExploring()
        
        // this case should always have an error
        notifyDelegate(ofFailure: error ?? createError("Did not send SSDP message."))
    }
    
    @objc func udpSocketDidClose(sock: GCDAsyncUdpSocket!, withError error: NSError!) {
        stopExploring()
        if let error = error {
            notifyDelegate(ofFailure: error)
        }
    }
    
    @objc func udpSocket(sock: GCDAsyncUdpSocket!, didReceiveData data: NSData!, fromAddress address: NSData!, withFilterContext filterContext: AnyObject!) {
        if let message = NSString(data: data, encoding: NSUTF8StringEncoding) as? String {
            var httpMethodLine: String?
            var headers = [String: String]()
            var regularExpressionError: NSError?
            let headersRegularExpression = NSRegularExpression(pattern: "^([a-z0-9-]+): *(.+)$", options: .CaseInsensitive | .AnchorsMatchLines, error: &regularExpressionError)
            message.enumerateLines({ (line, stop) -> () in
                if httpMethodLine == nil {
                    httpMethodLine = line
                }
                else {
                    headersRegularExpression?.enumerateMatchesInString(line, options: nil, range: NSRange(location: 0, length: count(line)), usingBlock: { (result: NSTextCheckingResult!, flags: NSMatchingFlags, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
                        if result.numberOfRanges == 3 {
                            let key = (line as NSString).substringWithRange(result.rangeAtIndex(1)).lowercaseString
                            let value = (line as NSString).substringWithRange(result.rangeAtIndex(2))
                            headers[key] = value
                        }
                    })
                }
            })
            
            if let httpMethodLine = httpMethodLine {
                let nts = headers["nts"]
                switch (httpMethodLine, nts) {
                case ("HTTP/1.1 200 OK", _):
                    handleSSDPMessage(.SearchResponse, headers: headers)
                case ("NOTIFY * HTTP/1.1", .Some(let notificationType)) where notificationType == "ssdp:alive":
                    handleSSDPMessage(.AvailableNotification, headers: headers)
                case ("NOTIFY * HTTP/1.1", .Some(let notificationType)) where notificationType == "ssdp:update":
                    handleSSDPMessage(.UpdateNotification, headers: headers)
                case ("NOTIFY * HTTP/1.1", .Some(let notificationType)) where notificationType == "ssdp:byebye":
                    headers["location"] = headers["host"] // byebye messages don't have a location
                    handleSSDPMessage(.UnavailableNotification, headers: headers)
                default:
                    return
                }
            }
        }
    }
}
