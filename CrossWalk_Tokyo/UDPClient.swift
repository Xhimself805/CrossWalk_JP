import Foundation
import Network
import Combine

class UDPClient: ObservableObject {
    private var connections: [String: NWConnection] = [:]
    let deviceConnections: [String]
    
    init(deviceConnections: [String], remotePort: UInt16) {
        self.deviceConnections = deviceConnections
        for host in deviceConnections {
            setupConnection(to: host, port: remotePort)
        }
    }
    
    private func setupConnection(to host: String, port: UInt16) {
        // 使用通用的 Host 封装，同时支持 IPv4 "192.168.x.x" 或 IPv6 "fd2f:..."
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .udp)
        connections[host] = connection
        connection.start(queue: .global())
        print("✅ UDP Client started to target \(host):\(port)")
    }
    
    func sendMessage(to host: String, message: String) {
        guard let connection = connections[host] else {
            print("❌ No connection found for host: \(host)")
            return
        }
        
        let data = message.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed({ sendError in
            if let error = sendError {
                print("❌ Error sending message to \(host): \(error)")
            }
        }))
    }
    
    deinit {
        // 取消所有连接
        for (_, connection) in connections {
            connection.cancel()
        }
        print("🧹 UDPClient cleaned up")
    }
}
